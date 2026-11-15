package syncserver

import (
	"context"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// Limits shared with the client (PasteHubCore/Sync/SyncLimits.swift).
const (
	MaxBlobBytes     = 5*1024*1024 + 4096 // 5 MiB plaintext plus AEAD and framing overhead
	MaxSealedBytes   = 512 * 1024
	MaxOpsPerRequest = 200
	MaxPullLimit     = 500
	DefaultQuota     = 500 * 1024 * 1024
)

var (
	idPattern      = regexp.MustCompile(`^[A-Za-z0-9-]{1,64}$`)
	itemKeyPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)
	validTypes     = map[string]bool{"upsert": true, "pin": true, "delete": true}
)

type Server struct {
	store   *Store
	quota   int64
	version string
	hub     *hub
	logger  *log.Logger
}

func NewServer(store *Store, version string, logger *log.Logger) *Server {
	return &Server{store: store, quota: DefaultQuota, version: version, hub: newHub(), logger: logger}
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/health", s.handleHealth)
	mux.Handle("GET /v1/space", s.auth(s.handleSpace))
	mux.Handle("POST /v1/ops", s.auth(s.handlePush))
	mux.Handle("GET /v1/ops", s.auth(s.handlePull))
	mux.Handle("GET /v1/stream", s.auth(s.handleStream))
	mux.Handle("PUT /v1/blobs/{id}", s.auth(s.handlePutBlob))
	mux.Handle("GET /v1/blobs/{id}", s.auth(s.handleGetBlob))
	return mux
}

type spaceHandler func(w http.ResponseWriter, r *http.Request, spaceID string)

func (s *Server) auth(next spaceHandler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		token, err := hex.DecodeString(strings.TrimSpace(raw))
		if !ok || err != nil || len(token) != 32 {
			writeError(w, http.StatusUnauthorized, "missing or malformed sync token")
			return
		}
		spaceID := SpaceIDForToken(token)
		if _, err := s.store.GetSpace(r.Context(), spaceID); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				writeError(w, http.StatusUnauthorized, "sync key is not registered on this server")
				return
			}
			s.internalError(w, err)
			return
		}
		next(w, r, spaceID)
	})
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "version": s.version})
}

func (s *Server) handleSpace(w http.ResponseWriter, r *http.Request, spaceID string) {
	sp, err := s.store.GetSpace(r.Context(), spaceID)
	if err != nil {
		s.internalError(w, err)
		return
	}
	latest, err := s.store.LatestSeq(r.Context(), spaceID)
	if err != nil {
		s.internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"latestSeq": latest, "horizonSeq": sp.HorizonSeq,
		"blobBytes": sp.BlobBytes, "quotaBytes": s.quota,
		"maxBlobBytes": MaxBlobBytes, "serverVersion": s.version,
	})
}

type pushRequest struct {
	Ops []Op `json:"ops"`
}

type pushResult struct {
	OpID string `json:"opId"`
	Seq  int64  `json:"seq"`
}

func (s *Server) handlePush(w http.ResponseWriter, r *http.Request, spaceID string) {
	r.Body = http.MaxBytesReader(w, r.Body, int64(MaxOpsPerRequest)*int64(MaxSealedBytes*4/3+1024))
	var req pushRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if len(req.Ops) == 0 || len(req.Ops) > MaxOpsPerRequest {
		writeError(w, http.StatusBadRequest, "ops must contain 1..200 entries")
		return
	}
	for _, op := range req.Ops {
		if msg := validateOp(op); msg != "" {
			status := http.StatusBadRequest
			if len(op.Sealed) > MaxSealedBytes {
				status = http.StatusRequestEntityTooLarge
			}
			writeError(w, status, msg)
			return
		}
	}
	seqs, err := s.store.AppendOps(r.Context(), spaceID, req.Ops)
	if err != nil {
		if errors.Is(err, ErrUnknownBlob) {
			writeError(w, http.StatusConflict, err.Error())
			return
		}
		s.internalError(w, err)
		return
	}
	results := make([]pushResult, len(seqs))
	var maxSeq int64
	for i, seq := range seqs {
		results[i] = pushResult{OpID: req.Ops[i].OpID, Seq: seq}
		maxSeq = max(maxSeq, seq)
	}
	s.hub.publish(spaceID, maxSeq)
	writeJSON(w, http.StatusOK, map[string]any{"results": results})
}

func validateOp(op Op) string {
	switch {
	case !idPattern.MatchString(op.OpID):
		return "invalid opId"
	case !idPattern.MatchString(op.DeviceID):
		return "invalid deviceId"
	case !validTypes[op.Type]:
		return "invalid op type"
	case !itemKeyPattern.MatchString(op.ItemKey):
		return "invalid itemKey"
	case len(op.Sealed) == 0:
		return "sealed payload is required"
	case len(op.Sealed) > MaxSealedBytes:
		return "sealed payload too large"
	case len(op.BlobIDs) > 16:
		return "too many blobs"
	}
	for _, id := range op.BlobIDs {
		if !idPattern.MatchString(id) {
			return "invalid blob id"
		}
	}
	return ""
}

func (s *Server) handlePull(w http.ResponseWriter, r *http.Request, spaceID string) {
	after, err := strconv.ParseInt(r.URL.Query().Get("after"), 10, 64)
	if err != nil || after < 0 {
		after = 0
	}
	limit, err := strconv.Atoi(r.URL.Query().Get("limit"))
	if err != nil || limit <= 0 || limit > MaxPullLimit {
		limit = MaxPullLimit
	}
	sp, err := s.store.GetSpace(r.Context(), spaceID)
	if err != nil {
		s.internalError(w, err)
		return
	}
	if after > 0 && after < sp.HorizonSeq {
		writeJSON(w, http.StatusOK, map[string]any{"ops": []Op{}, "resetRequired": true, "hasMore": false})
		return
	}
	ops, err := s.store.OpsAfter(r.Context(), spaceID, after, limit+1)
	if err != nil {
		s.internalError(w, err)
		return
	}
	hasMore := len(ops) > limit
	if hasMore {
		ops = ops[:limit]
	}
	if ops == nil {
		ops = []Op{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"ops": ops, "resetRequired": false, "hasMore": hasMore})
}

func (s *Server) handleStream(w http.ResponseWriter, r *http.Request, spaceID string) {
	conn, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	defer conn.CloseNow()
	ctx := conn.CloseRead(r.Context())

	updates, cancel := s.hub.subscribe(spaceID)
	defer cancel()

	latest, err := s.store.LatestSeq(ctx, spaceID)
	if err != nil {
		conn.Close(websocket.StatusInternalError, "store error")
		return
	}
	send := func(seq int64) error {
		writeCtx, done := context.WithTimeout(ctx, 10*time.Second)
		defer done()
		payload, _ := json.Marshal(map[string]int64{"latestSeq": seq})
		return conn.Write(writeCtx, websocket.MessageText, payload)
	}
	if err := send(latest); err != nil {
		return
	}
	ping := time.NewTicker(30 * time.Second)
	defer ping.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case seq := <-updates:
			if err := send(seq); err != nil {
				return
			}
		case <-ping.C:
			pingCtx, done := context.WithTimeout(ctx, 10*time.Second)
			err := conn.Ping(pingCtx)
			done()
			if err != nil {
				return
			}
		}
	}
}

func (s *Server) handlePutBlob(w http.ResponseWriter, r *http.Request, spaceID string) {
	id := r.PathValue("id")
	if !idPattern.MatchString(id) {
		writeError(w, http.StatusBadRequest, "invalid blob id")
		return
	}
	data, err := io.ReadAll(http.MaxBytesReader(w, r.Body, MaxBlobBytes))
	if err != nil {
		writeError(w, http.StatusRequestEntityTooLarge, "blob exceeds 5 MiB limit")
		return
	}
	if len(data) == 0 {
		writeError(w, http.StatusBadRequest, "empty blob")
		return
	}
	if err := s.store.PutBlob(r.Context(), spaceID, id, data, s.quota); err != nil {
		if errors.Is(err, ErrQuotaReached) {
			writeError(w, http.StatusInsufficientStorage, err.Error())
			return
		}
		s.internalError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleGetBlob(w http.ResponseWriter, r *http.Request, spaceID string) {
	id := r.PathValue("id")
	if !idPattern.MatchString(id) {
		writeError(w, http.StatusBadRequest, "invalid blob id")
		return
	}
	path, err := s.store.BlobFile(r.Context(), spaceID, id)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			writeError(w, http.StatusNotFound, "blob not found")
			return
		}
		s.internalError(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	http.ServeFile(w, r, path)
}

func (s *Server) internalError(w http.ResponseWriter, err error) {
	s.logger.Printf("internal error: %v", err)
	writeError(w, http.StatusInternalServerError, "internal error")
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

// hub fans out "new ops available" notifications to WebSocket subscribers of a space.
type hub struct {
	mu   sync.Mutex
	subs map[string]map[chan int64]struct{}
}

func newHub() *hub { return &hub{subs: map[string]map[chan int64]struct{}{}} }

func (h *hub) subscribe(spaceID string) (<-chan int64, func()) {
	ch := make(chan int64, 1)
	h.mu.Lock()
	if h.subs[spaceID] == nil {
		h.subs[spaceID] = map[chan int64]struct{}{}
	}
	h.subs[spaceID][ch] = struct{}{}
	h.mu.Unlock()
	return ch, func() {
		h.mu.Lock()
		delete(h.subs[spaceID], ch)
		if len(h.subs[spaceID]) == 0 {
			delete(h.subs, spaceID)
		}
		h.mu.Unlock()
	}
}

func (h *hub) publish(spaceID string, seq int64) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for ch := range h.subs[spaceID] {
		// Keep only the newest seq per subscriber; a slow reader never blocks a push.
		select {
		case ch <- seq:
		default:
			select {
			case <-ch:
			default:
			}
			ch <- seq
		}
	}
}
