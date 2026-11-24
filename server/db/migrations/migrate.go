package migrations

import (
	"context"
	"crypto/sha256"
	"embed"
	"fmt"
	"io/fs"
	"strconv"
	"strings"
	"sync"

	"github.com/jackc/pgx/v5"
)

//go:embed *.sql
var files embed.FS

type migration struct {
	version int
	name    string
	sql     string
	digest  string
}

func readMigrations() ([]migration, error) {
	entries, err := fs.ReadDir(files, ".")
	if err != nil {
		return nil, err
	}
	items := make([]migration, 0, len(entries))
	for _, entry := range entries {
		prefix, _, ok := strings.Cut(entry.Name(), "_")
		version, parseErr := strconv.Atoi(prefix)
		if !ok || parseErr != nil || version != len(items)+1 {
			return nil, fmt.Errorf("invalid migration order at %s", entry.Name())
		}
		raw, err := files.ReadFile(entry.Name())
		if err != nil {
			return nil, err
		}
		sql := strings.ReplaceAll(string(raw), "\r\n", "\n")
		items = append(items, migration{version, entry.Name(), sql, fmt.Sprintf("%x", sha256.Sum256([]byte(sql)))})
	}
	return items, nil
}

var compiledMigrations = sync.OnceValues(readMigrations)

func LatestVersion() (int, string) {
	items, err := compiledMigrations()
	if err != nil || len(items) == 0 {
		panic("invalid embedded migrations")
	}
	latest := items[len(items)-1]
	return latest.version, latest.digest
}

func Run(ctx context.Context, conn *pgx.Conn) error {
	items, err := compiledMigrations()
	if err != nil {
		return err
	}
	return pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
		var owner bool
		if err := tx.QueryRow(ctx, "SELECT  current_user = 'screen_track_owner'").Scan(&owner); err != nil {
			return err
		}
		if !owner {
			return fmt.Errorf("migrations require the screen_track_owner database role")
		}
		if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashextended('screen-track:migrations',0))"); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, "SET LOCAL lock_timeout = '10s'"); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, bootstrapLedger); err != nil {
			return fmt.Errorf("initialize schema and migration ledger: %w", err)
		}
		rows, err := tx.Query(ctx, "SELECT version, checksum FROM screen_track.schema_migrations ORDER BY version")
		if err != nil {
			return err
		}
		count := 0
		for rows.Next() {
			var version int
			var digest string
			if err := rows.Scan(&version, &digest); err != nil {
				rows.Close()
				return err
			}
			if version != count+1 || count >= len(items) || items[count].digest != digest {
				rows.Close()
				return fmt.Errorf("database migration history diverges at version %d", version)
			}
			count++
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
		for _, item := range items[count:] {
			if _, err := tx.Exec(ctx, item.sql, pgx.QueryExecModeSimpleProtocol); err != nil {
				return fmt.Errorf("apply %s: %w", item.name, err)
			}
			if _, err := tx.Exec(ctx, "INSERT INTO screen_track.schema_migrations (version, checksum) VALUES ($1, $2)", item.version, item.digest); err != nil {
				return err
			}
		}
		return nil
	})
}

const bootstrapLedger = `
CREATE SCHEMA IF NOT EXISTS screen_track;
REVOKE ALL ON SCHEMA screen_track FROM PUBLIC;
GRANT USAGE ON SCHEMA screen_track TO screen_track_app;
CREATE TABLE IF NOT EXISTS screen_track.schema_migrations (
	version integer PRIMARY KEY CHECK (version > 0),
	checksum text NOT NULL CHECK (length(checksum) = 64),
	applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
GRANT SELECT ON screen_track.schema_migrations TO screen_track_app;
`
