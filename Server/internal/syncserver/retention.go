package syncserver

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"time"
)

// RetentionPolicy controls how long history stays on the relay.
type RetentionPolicy struct {
	// MaxAge removes ops older than this unless their item is currently kept (pinned).
	MaxAge time.Duration
	// BlobGrace keeps unreferenced blobs this long so an upload can be followed by its op.
	BlobGrace time.Duration
}

var DefaultRetention = RetentionPolicy{MaxAge: 30 * 24 * time.Hour, BlobGrace: time.Hour}

// Compact removes superseded ops, expired ops and unreferenced blobs for every space.
func (s *Store) Compact(ctx context.Context, policy RetentionPolicy, now time.Time) error {
	spaces, err := s.ListSpaces(ctx)
	if err != nil {
		return err
	}
	for _, sp := range spaces {
		if err := s.compactSpace(ctx, sp.ID, policy, now); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) compactSpace(ctx context.Context, spaceID string, policy RetentionPolicy, now time.Time) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	// 1. Superseded ops. A newer op for the same item always exists, so clients
	//    whose cursor sits before them still converge without a reset.
	superseded := []string{
		// Anything before a delete of the same item.
		`DELETE FROM ops WHERE space_id = ?1 AND EXISTS (
			SELECT 1 FROM ops d WHERE d.space_id = ops.space_id AND d.item_key = ops.item_key
			AND d.type = 'delete' AND d.seq > ops.seq)`,
		// Older upserts of the same item.
		`DELETE FROM ops WHERE space_id = ?1 AND type = 'upsert' AND EXISTS (
			SELECT 1 FROM ops u WHERE u.space_id = ops.space_id AND u.item_key = ops.item_key
			AND u.type = 'upsert' AND u.seq > ops.seq)`,
		// Pin changes older than the latest upsert or pin (both carry pin state).
		`DELETE FROM ops WHERE space_id = ?1 AND type = 'pin' AND EXISTS (
			SELECT 1 FROM ops u WHERE u.space_id = ops.space_id AND u.item_key = ops.item_key
			AND u.type IN ('upsert', 'pin') AND u.seq > ops.seq)`,
	}
	for _, q := range superseded {
		if _, err := tx.ExecContext(ctx, q, spaceID); err != nil {
			return err
		}
	}

	// 2. Expired ops. Items whose newest op is marked keep (pinned) survive.
	cutoff := now.Add(-policy.MaxAge).Unix()
	const expiredWhere = `space_id = ?1 AND created_at < ?2 AND item_key NOT IN (
		SELECT o.item_key FROM ops o WHERE o.space_id = ?1 AND o.keep = 1 AND o.seq = (
			SELECT MAX(o2.seq) FROM ops o2 WHERE o2.space_id = o.space_id AND o2.item_key = o.item_key))`
	var maxExpired sql.NullInt64
	if err := tx.QueryRowContext(ctx, `SELECT MAX(seq) FROM ops WHERE `+expiredWhere, spaceID, cutoff).
		Scan(&maxExpired); err != nil {
		return err
	}
	if maxExpired.Valid {
		if _, err := tx.ExecContext(ctx, `DELETE FROM ops WHERE `+expiredWhere, spaceID, cutoff); err != nil {
			return err
		}
		// Clients whose cursor is older than this may have missed deletes and must rebuild.
		if _, err := tx.ExecContext(ctx,
			`UPDATE spaces SET horizon_seq = MAX(horizon_seq, ?) WHERE id = ?`, maxExpired.Int64, spaceID); err != nil {
			return err
		}
	}

	// 3. Unreferenced blobs past their grace period.
	graceCutoff := now.Add(-policy.BlobGrace).Unix()
	rows, err := tx.QueryContext(ctx,
		`SELECT id, size FROM blobs WHERE space_id = ? AND created_at < ? AND id NOT IN (
			SELECT ob.blob_id FROM op_blobs ob JOIN ops o ON o.seq = ob.seq WHERE o.space_id = ?)`,
		spaceID, graceCutoff, spaceID)
	if err != nil {
		return err
	}
	type orphan struct {
		id   string
		size int64
	}
	var orphans []orphan
	for rows.Next() {
		var o orphan
		if err := rows.Scan(&o.id, &o.size); err != nil {
			rows.Close()
			return err
		}
		orphans = append(orphans, o)
	}
	if err := rows.Close(); err != nil {
		return err
	}
	var freed int64
	for _, o := range orphans {
		if _, err := tx.ExecContext(ctx, `DELETE FROM blobs WHERE space_id = ? AND id = ?`, spaceID, o.id); err != nil {
			return err
		}
		freed += o.size
	}
	if freed > 0 {
		if _, err := tx.ExecContext(ctx,
			`UPDATE spaces SET blob_bytes = MAX(0, blob_bytes - ?) WHERE id = ?`, freed, spaceID); err != nil {
			return err
		}
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	for _, o := range orphans {
		if err := os.Remove(s.blobPath(spaceID, o.id)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	return nil
}
