package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Store struct {
	Pool    *pgxpool.Pool
	Queries *db.Queries
}

func Open(ctx context.Context, dsn string, maxConns int32) (*Store, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("invalid runtime database configuration")
	}
	cfg.MaxConns = maxConns
	cfg.MinIdleConns = 1
	cfg.MaxConnLifetime = 30 * time.Minute
	cfg.MaxConnLifetimeJitter = 3 * time.Minute
	cfg.MaxConnIdleTime = 5 * time.Minute
	cfg.ConnConfig.ConnectTimeout = 5 * time.Second
	cfg.ConnConfig.RuntimeParams["statement_timeout"] = "4500"
	cfg.ConnConfig.RuntimeParams["lock_timeout"] = "2500"
	cfg.ConnConfig.RuntimeParams["idle_in_transaction_session_timeout"] = "8000"
	cfg.ConnConfig.RuntimeParams["search_path"] = "pg_catalog"
	if cfg.ConnConfig.RuntimeParams["application_name"] == "" {
		cfg.ConnConfig.RuntimeParams["application_name"] = "screen-track-api"
	}

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("could not initialize the runtime database pool")
	}
	s := &Store{Pool: pool, Queries: db.New(pool)}
	if err := s.Ready(ctx); err != nil {
		pool.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Ready(ctx context.Context) error {
	const query = `
	SELECT current_user = 'screen_track_app'
		AND NOT p.rolsuper AND NOT p.rolbypassrls AND NOT p.rolcreaterole AND NOT p.rolcreatedb AND NOT p.rolreplication
		AND NOT pg_has_role(current_user, 'screen_track_owner', 'MEMBER')
		AND EXISTS (SELECT 1 FROM screen_track.schema_migrations WHERE version = $1 AND checksum = $2)
	FROM pg_catalog.pg_roles p WHERE p.rolname = current_user`
	version, checksum := migrations.LatestVersion()
	var ready bool
	if err := s.Pool.QueryRow(ctx, query, version, checksum).Scan(&ready); err != nil || !ready {
		return fmt.Errorf("runtime database role or schema is not ready")
	}
	return nil
}

func (s *Store) Transaction(ctx context.Context, work func(q *db.Queries) error) error {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() {
		//a cancelled request must still release its stuck transaction and row locks.
		cleanup, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = tx.Rollback(cleanup)
	}()
	if err := work(db.New(tx)); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (s *Store) Maintain(ctx context.Context, onError func(error)) {
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			batch, cancel := context.WithTimeout(ctx, 5*time.Second)
			err := s.Queries.PurgeAuthState(batch)
			cancel()
			if err != nil && !errors.Is(err, context.Canceled) {
				onError(err)
			}
		}
	}
}

func IsMissing(err error) bool {
	return errors.Is(err, pgx.ErrNoRows)
}
