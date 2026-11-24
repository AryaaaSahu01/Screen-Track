package main

import (
	"context"
	"log/slog"
	"os"
	"time"

	"github.com/AryaaaSahu01/Screen-Track/server/db/migrations"
	"github.com/AryaaaSahu01/Screen-Track/server/internal/config"
	"github.com/jackc/pgx/v5"
)

func main() {
	if !run() {
		os.Exit(1)
	}
}

func run() bool {
	production, err := config.Production()
	if err != nil {
		slog.Error(err.Error())
		return false
	}
	dsn, err := config.DatabaseURL("MIGRATION_DATABASE_URL", "screen_track_owner", production)
	if err != nil {
		slog.Error(err.Error())
		return false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		slog.Error("could not connect using the migration role")
		return false
	}
	defer conn.Close(context.Background())
	if err = migrations.Run(ctx, conn); err != nil {
		slog.Error("database migration failed", "error", err)
		return false
	}
	version, _ := migrations.LatestVersion()
	slog.Info("database migrations applied", "version", version)
	return true
}
