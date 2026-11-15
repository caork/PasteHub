package syncserver

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite"
)

// Op is one entry in a space's operation log. Sealed is opaque ciphertext.
type Op struct {
	Seq      int64    `json:"seq"`
	OpID     string   `json:"opId"`
	DeviceID string   `json:"deviceId"`
	Type     string   `json:"type"`
	ItemKey  string   `json:"itemKey"`
	Keep     bool     `json:"keep"`
	Sealed   []byte   `json:"sealed"`
	BlobIDs  []string `json:"blobIds,omitempty"`
}

// Space is a sync group unlocked by one sync key.
type Space struct {
	ID         string
	Label      string
	CreatedAt  time.Time
	HorizonSeq int64
	BlobBytes  int64
}

var (
	ErrUnknownBlob  = errors.New("unknown blob")
	ErrQuotaReached = errors.New("space storage quota reached")
)

type Store struct {
	db      *sql.DB
	blobDir string
}

const schema = `
CREATE TABLE IF NOT EXISTS spaces (
	id          TEXT PRIMARY KEY,
	label       TEXT NOT NULL DEFAULT '',
	created_at  INTEGER NOT NULL,
	horizon_seq INTEGER NOT NULL DEFAULT 0,
	blob_bytes  INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS ops (
	seq        INTEGER PRIMARY KEY AUTOINCREMENT,
	space_id   TEXT NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
	op_id      TEXT NOT NULL,
	device_id  TEXT NOT NULL,
	type       TEXT NOT NULL,
	item_key   TEXT NOT NULL,
	keep       INTEGER NOT NULL DEFAULT 0,
	sealed     BLOB NOT NULL,
	created_at INTEGER NOT NULL,
	UNIQUE (space_id, op_id)
);
CREATE INDEX IF NOT EXISTS ops_space_seq ON ops (space_id, seq);
CREATE INDEX IF NOT EXISTS ops_space_item ON ops (space_id, item_key, seq);
CREATE TABLE IF NOT EXISTS op_blobs (
	seq     INTEGER NOT NULL REFERENCES ops(seq) ON DELETE CASCADE,
	blob_id TEXT NOT NULL,
	PRIMARY KEY (seq, blob_id)
);
CREATE INDEX IF NOT EXISTS op_blobs_blob ON op_blobs (blob_id);
CREATE TABLE IF NOT EXISTS blobs (
	space_id   TEXT NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
	id         TEXT NOT NULL,
	size       INTEGER NOT NULL,
	created_at INTEGER NOT NULL,
	PRIMARY KEY (space_id, id)
);
`

// OpenStore opens (and creates if needed) the database and blob directory under dataDir.
func OpenStore(dataDir string) (*Store, error) {
	if err := os.MkdirAll(filepath.Join(dataDir, "blobs"), 0o700); err != nil {
		return nil, err
	}
	dsn := "file:" + filepath.Join(dataDir, "sync.db") +
		"?_pragma=journal_mode(WAL)&_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	// A single connection serialises writes and keeps per-connection pragmas consistent.
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("apply schema: %w", err)
	}
	return &Store{db: db, blobDir: filepath.Join(dataDir, "blobs")}, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) CreateSpace(ctx context.Context, id, label string) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO spaces (id, label, created_at) VALUES (?, ?, ?)`,
		id, label, time.Now().Unix())
	return err
}

func (s *Store) DeleteSpace(ctx context.Context, id string) error {
	res, err := s.db.ExecContext(ctx, `DELETE FROM spaces WHERE id = ?`, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return sql.ErrNoRows
	}
	return os.RemoveAll(filepath.Join(s.blobDir, id))
}

func (s *Store) ListSpaces(ctx context.Context) ([]Space, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, label, created_at, horizon_seq, blob_bytes FROM spaces ORDER BY created_at`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Space
	for rows.Next() {
		var sp Space
		var created int64
		if err := rows.Scan(&sp.ID, &sp.Label, &created, &sp.HorizonSeq, &sp.BlobBytes); err != nil {
			return nil, err
		}
		sp.CreatedAt = time.Unix(created, 0)
		out = append(out, sp)
	}
	return out, rows.Err()
}

func (s *Store) GetSpace(ctx context.Context, id string) (*Space, error) {
	var sp Space
	var created int64
	err := s.db.QueryRowContext(ctx,
		`SELECT id, label, created_at, horizon_seq, blob_bytes FROM spaces WHERE id = ?`, id).
		Scan(&sp.ID, &sp.Label, &created, &sp.HorizonSeq, &sp.BlobBytes)
	if err != nil {
		return nil, err
	}
	sp.CreatedAt = time.Unix(created, 0)
	return &sp, nil
}

// AppendOps appends ops idempotently (by opId) and returns the seq assigned to each.
func (s *Store) AppendOps(ctx context.Context, spaceID string, ops []Op) ([]int64, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	seqs := make([]int64, len(ops))
	now := time.Now().Unix()
	for i, op := range ops {
		var existing int64
		err := tx.QueryRowContext(ctx,
			`SELECT seq FROM ops WHERE space_id = ? AND op_id = ?`, spaceID, op.OpID).Scan(&existing)
		if err == nil {
			seqs[i] = existing
			continue
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return nil, err
		}
		for _, blobID := range op.BlobIDs {
			var one int
			if err := tx.QueryRowContext(ctx,
				`SELECT 1 FROM blobs WHERE space_id = ? AND id = ?`, spaceID, blobID).Scan(&one); err != nil {
				if errors.Is(err, sql.ErrNoRows) {
					return nil, fmt.Errorf("%w: %s", ErrUnknownBlob, blobID)
				}
				return nil, err
			}
		}
		res, err := tx.ExecContext(ctx,
			`INSERT INTO ops (space_id, op_id, device_id, type, item_key, keep, sealed, created_at)
			 VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
			spaceID, op.OpID, op.DeviceID, op.Type, op.ItemKey, op.Keep, op.Sealed, now)
		if err != nil {
			return nil, err
		}
		seq, err := res.LastInsertId()
		if err != nil {
			return nil, err
		}
		for _, blobID := range op.BlobIDs {
			if _, err := tx.ExecContext(ctx,
				`INSERT OR IGNORE INTO op_blobs (seq, blob_id) VALUES (?, ?)`, seq, blobID); err != nil {
				return nil, err
			}
		}
		seqs[i] = seq
	}
	return seqs, tx.Commit()
}

// OpsAfter returns up to limit ops with seq > after, oldest first.
func (s *Store) OpsAfter(ctx context.Context, spaceID string, after int64, limit int) ([]Op, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT seq, op_id, device_id, type, item_key, keep, sealed FROM ops
		 WHERE space_id = ? AND seq > ? ORDER BY seq LIMIT ?`, spaceID, after, limit)
	if err != nil {
		return nil, err
	}
	var ops []Op
	for rows.Next() {
		var op Op
		if err := rows.Scan(&op.Seq, &op.OpID, &op.DeviceID, &op.Type, &op.ItemKey, &op.Keep, &op.Sealed); err != nil {
			rows.Close()
			return nil, err
		}
		ops = append(ops, op)
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for i := range ops {
		ids, err := s.blobIDsForSeq(ctx, ops[i].Seq)
		if err != nil {
			return nil, err
		}
		ops[i].BlobIDs = ids
	}
	return ops, nil
}

func (s *Store) blobIDsForSeq(ctx context.Context, seq int64) ([]string, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT blob_id FROM op_blobs WHERE seq = ? ORDER BY blob_id`, seq)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

// LatestSeq returns the newest seq in the space, or 0.
func (s *Store) LatestSeq(ctx context.Context, spaceID string) (int64, error) {
	var seq sql.NullInt64
	err := s.db.QueryRowContext(ctx, `SELECT MAX(seq) FROM ops WHERE space_id = ?`, spaceID).Scan(&seq)
	return seq.Int64, err
}

func (s *Store) blobPath(spaceID, blobID string) string {
	return filepath.Join(s.blobDir, spaceID, blobID)
}

// PutBlob stores an encrypted blob. Re-uploading an existing id is a no-op.
func (s *Store) PutBlob(ctx context.Context, spaceID, blobID string, data []byte, quota int64) error {
	var size int64
	err := s.db.QueryRowContext(ctx,
		`SELECT size FROM blobs WHERE space_id = ? AND id = ?`, spaceID, blobID).Scan(&size)
	if err == nil {
		return nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	sp, err := s.GetSpace(ctx, spaceID)
	if err != nil {
		return err
	}
	if sp.BlobBytes+int64(len(data)) > quota {
		return ErrQuotaReached
	}
	dir := filepath.Join(s.blobDir, spaceID)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".upload-*")
	if err != nil {
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	if err := os.Rename(tmp.Name(), s.blobPath(spaceID, blobID)); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO blobs (space_id, id, size, created_at) VALUES (?, ?, ?, ?)`,
		spaceID, blobID, len(data), time.Now().Unix()); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx,
		`UPDATE spaces SET blob_bytes = blob_bytes + ? WHERE id = ?`, len(data), spaceID); err != nil {
		return err
	}
	return tx.Commit()
}

// BlobFile returns the on-disk path of a stored blob.
func (s *Store) BlobFile(ctx context.Context, spaceID, blobID string) (string, error) {
	var size int64
	err := s.db.QueryRowContext(ctx,
		`SELECT size FROM blobs WHERE space_id = ? AND id = ?`, spaceID, blobID).Scan(&size)
	if err != nil {
		return "", err
	}
	return s.blobPath(spaceID, blobID), nil
}
