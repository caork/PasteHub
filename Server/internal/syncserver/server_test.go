package syncserver

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// fixedMaster is shared with PasteHubCoreTests/SyncKeysTests.swift as a cross-language vector.
func fixedMaster() []byte {
	m := make([]byte, 32)
	for i := range m {
		m[i] = byte(i)
	}
	return m
}

func TestKeyRoundTripAndVector(t *testing.T) {
	master := fixedMaster()
	key := FormatKey(master)
	if key != "phs1_AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8" {
		t.Fatalf("unexpected key encoding %q", key)
	}
	parsed, err := ParseKey("  " + key + "\n")
	if err != nil || !bytes.Equal(parsed, master) {
		t.Fatalf("parse failed: %v", err)
	}
	token := hex.EncodeToString(DeriveAuthToken(master))
	t.Logf("auth token %s space %s", token, SpaceIDForKey(master))
	if token != expectedAuthToken {
		t.Fatalf("auth token vector changed: %s", token)
	}
	if _, err := ParseKey("phs2_abc"); err == nil {
		t.Fatal("expected prefix error")
	}
	if _, err := ParseKey(KeyPrefix + "AAEC"); err == nil {
		t.Fatal("expected length error")
	}
}

const expectedAuthToken = "e188906dd6ba8958e69a3602d9eaddb8f3b71009b0af21968888534dbdeae9ac"

type harness struct {
	t      *testing.T
	store  *Store
	srv    *httptest.Server
	token  string
	server *Server
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })
	master := fixedMaster()
	if err := store.CreateSpace(context.Background(), SpaceIDForKey(master), "test"); err != nil {
		t.Fatal(err)
	}
	server := NewServer(store, "test", log.New(io.Discard, "", 0))
	srv := httptest.NewServer(server.Handler())
	t.Cleanup(srv.Close)
	return &harness{t: t, store: store, srv: srv, server: server, token: hex.EncodeToString(DeriveAuthToken(master))}
}

func (h *harness) do(method, path string, body []byte, token string) (int, []byte) {
	h.t.Helper()
	req, _ := http.NewRequest(method, h.srv.URL+path, bytes.NewReader(body))
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		h.t.Fatal(err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, data
}

func itemKey(c byte) string { return strings.Repeat(string(c), 64) }

func (h *harness) push(ops ...Op) []pushResult {
	h.t.Helper()
	body, _ := json.Marshal(pushRequest{Ops: ops})
	status, data := h.do("POST", "/v1/ops", body, h.token)
	if status != http.StatusOK {
		h.t.Fatalf("push status %d: %s", status, data)
	}
	var out struct{ Results []pushResult }
	json.Unmarshal(data, &out)
	return out.Results
}

type pullResponse struct {
	Ops           []Op
	ResetRequired bool
	HasMore       bool
}

func (h *harness) pull(after int64) pullResponse {
	h.t.Helper()
	status, data := h.do("GET", "/v1/ops?after="+itoa(after), nil, h.token)
	if status != http.StatusOK {
		h.t.Fatalf("pull status %d: %s", status, data)
	}
	var out pullResponse
	json.Unmarshal(data, &out)
	return out
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

func op(id, typ string, key byte) Op {
	return Op{OpID: id, DeviceID: "dev-a", Type: typ, ItemKey: itemKey(key), Sealed: []byte("ciphertext-" + id)}
}

func TestAuthRejectsUnknownAndMalformedTokens(t *testing.T) {
	h := newHarness(t)
	if status, _ := h.do("GET", "/v1/space", nil, ""); status != http.StatusUnauthorized {
		t.Fatalf("missing token: %d", status)
	}
	if status, _ := h.do("GET", "/v1/space", nil, "zz"); status != http.StatusUnauthorized {
		t.Fatalf("malformed token: %d", status)
	}
	other := hex.EncodeToString(DeriveAuthToken(make([]byte, 32)))
	if status, _ := h.do("GET", "/v1/space", nil, other); status != http.StatusUnauthorized {
		t.Fatalf("unregistered token: %d", status)
	}
	if status, _ := h.do("GET", "/v1/space", nil, h.token); status != http.StatusOK {
		t.Fatalf("valid token: %d", status)
	}
	if status, _ := h.do("GET", "/v1/health", nil, ""); status != http.StatusOK {
		t.Fatalf("health: %d", status)
	}
}

func TestPushIsIdempotentAndPullIsOrdered(t *testing.T) {
	h := newHarness(t)
	first := h.push(op("op-1", "upsert", 'a'), op("op-2", "pin", 'a'))
	again := h.push(op("op-1", "upsert", 'a'))
	if again[0].Seq != first[0].Seq {
		t.Fatalf("duplicate opId got new seq %d vs %d", again[0].Seq, first[0].Seq)
	}
	h.push(op("op-3", "upsert", 'b'))

	all := h.pull(0)
	if len(all.Ops) != 3 || all.Ops[0].OpID != "op-1" || all.Ops[2].OpID != "op-3" {
		t.Fatalf("unexpected pull: %+v", all.Ops)
	}
	if string(all.Ops[0].Sealed) != "ciphertext-op-1" {
		t.Fatalf("sealed payload corrupted: %q", all.Ops[0].Sealed)
	}
	tail := h.pull(first[1].Seq)
	if len(tail.Ops) != 1 || tail.Ops[0].OpID != "op-3" {
		t.Fatalf("unexpected tail: %+v", tail.Ops)
	}
}

func TestPushValidation(t *testing.T) {
	h := newHarness(t)
	bad := []Op{
		{OpID: "x", DeviceID: "d", Type: "bogus", ItemKey: itemKey('a'), Sealed: []byte("s")},
		{OpID: "x", DeviceID: "d", Type: "upsert", ItemKey: "short", Sealed: []byte("s")},
		{OpID: "x y", DeviceID: "d", Type: "upsert", ItemKey: itemKey('a'), Sealed: []byte("s")},
		{OpID: "x", DeviceID: "d", Type: "upsert", ItemKey: itemKey('a')},
	}
	for i, o := range bad {
		body, _ := json.Marshal(pushRequest{Ops: []Op{o}})
		if status, _ := h.do("POST", "/v1/ops", body, h.token); status != http.StatusBadRequest {
			t.Errorf("case %d: status %d", i, status)
		}
	}
	big := op("big", "upsert", 'a')
	big.Sealed = make([]byte, MaxSealedBytes+1)
	body, _ := json.Marshal(pushRequest{Ops: []Op{big}})
	if status, _ := h.do("POST", "/v1/ops", body, h.token); status != http.StatusRequestEntityTooLarge {
		t.Errorf("oversized sealed: status %d", status)
	}
}

func TestBlobsRequireUploadAndRespectLimits(t *testing.T) {
	h := newHarness(t)
	withBlob := op("op-blob", "upsert", 'c')
	withBlob.BlobIDs = []string{"blob-1"}
	body, _ := json.Marshal(pushRequest{Ops: []Op{withBlob}})
	if status, _ := h.do("POST", "/v1/ops", body, h.token); status != http.StatusConflict {
		t.Fatalf("op referencing missing blob: %d", status)
	}
	if status, _ := h.do("PUT", "/v1/blobs/blob-1", []byte("encrypted"), h.token); status != http.StatusNoContent {
		t.Fatalf("put blob: %d", status)
	}
	h.push(withBlob)
	pulled := h.pull(0)
	if len(pulled.Ops) != 1 || len(pulled.Ops[0].BlobIDs) != 1 || pulled.Ops[0].BlobIDs[0] != "blob-1" {
		t.Fatalf("blob ids not returned: %+v", pulled.Ops)
	}
	status, data := h.do("GET", "/v1/blobs/blob-1", nil, h.token)
	if status != http.StatusOK || string(data) != "encrypted" {
		t.Fatalf("get blob: %d %q", status, data)
	}
	if status, _ := h.do("GET", "/v1/blobs/missing", nil, h.token); status != http.StatusNotFound {
		t.Fatalf("missing blob: %d", status)
	}
	if status, _ := h.do("PUT", "/v1/blobs/huge", make([]byte, MaxBlobBytes+1), h.token); status != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversized blob: %d", status)
	}
	h.server.quota = 20
	if status, _ := h.do("PUT", "/v1/blobs/blob-2", make([]byte, 30), h.token); status != http.StatusInsufficientStorage {
		t.Fatalf("quota: %d", status)
	}
}

func TestCompactionRemovesSupersededOpsAndSetsHorizon(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	h.push(op("u1", "upsert", 'a'), op("p1", "pin", 'a'), op("u2", "upsert", 'a'))
	h.push(op("u3", "upsert", 'b'), op("d1", "delete", 'b'))
	if err := h.store.Compact(ctx, DefaultRetention, time.Now()); err != nil {
		t.Fatal(err)
	}
	var ids []string
	for _, o := range h.pull(0).Ops {
		ids = append(ids, o.OpID)
	}
	if strings.Join(ids, ",") != "u2,d1" {
		t.Fatalf("after superseded compaction: %v", ids)
	}

	kept := op("u4", "upsert", 'c')
	kept.Keep = true
	h.push(kept)
	// Everything is older than MaxAge one year from now, except the pinned item.
	if err := h.store.Compact(ctx, DefaultRetention, time.Now().Add(365*24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	remaining := h.pull(0).Ops
	if len(remaining) != 1 || remaining[0].OpID != "u4" {
		t.Fatalf("expected only pinned op to survive: %+v", remaining)
	}
	if !h.pull(1).ResetRequired {
		t.Fatal("cursor behind horizon must require reset")
	}
}

func TestCompactionDeletesOrphanBlobs(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	h.do("PUT", "/v1/blobs/orphan", []byte("x"), h.token)
	h.do("PUT", "/v1/blobs/used", []byte("y"), h.token)
	used := op("u1", "upsert", 'a')
	used.BlobIDs = []string{"used"}
	h.push(used)
	if err := h.store.Compact(ctx, DefaultRetention, time.Now().Add(2*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if status, _ := h.do("GET", "/v1/blobs/orphan", nil, h.token); status != http.StatusNotFound {
		t.Fatalf("orphan blob still served: %d", status)
	}
	if status, _ := h.do("GET", "/v1/blobs/used", nil, h.token); status != http.StatusOK {
		t.Fatalf("referenced blob removed: %d", status)
	}
}

func TestStreamNotifiesNewOps(t *testing.T) {
	h := newHarness(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	wsURL := "ws" + strings.TrimPrefix(h.srv.URL, "http") + "/v1/stream"
	conn, _, err := websocket.Dial(ctx, wsURL, &websocket.DialOptions{
		HTTPHeader: http.Header{"Authorization": {"Bearer " + h.token}},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()
	read := func() int64 {
		_, data, err := conn.Read(ctx)
		if err != nil {
			t.Fatal(err)
		}
		var msg struct{ LatestSeq int64 }
		json.Unmarshal(data, &msg)
		return msg.LatestSeq
	}
	if initial := read(); initial != 0 {
		t.Fatalf("initial latestSeq %d", initial)
	}
	res := h.push(op("op-1", "upsert", 'a'))
	if got := read(); got != res[0].Seq {
		t.Fatalf("notified %d, want %d", got, res[0].Seq)
	}
}
