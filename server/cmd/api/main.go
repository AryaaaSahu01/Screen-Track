package main

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
	_ "time/tzdata"

	"github.com/AryaaaSahu01/Screen-Track/server/internal/config"
	"github.com/AryaaaSahu01/Screen-Track/server/internal/httpapi"
	"github.com/AryaaaSahu01/Screen-Track/server/internal/identity"
	"github.com/AryaaaSahu01/Screen-Track/server/internal/store"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	if err := run(log); err != nil {
		log.Error("API stopped", "error", err)
		os.Exit(1)
	}
}

func run(log *slog.Logger) error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}

	life, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	startup, cancel := context.WithTimeout(life, 12*time.Second)
	defer cancel()

	data, err := store.Open(startup, cfg.DatabaseURL, cfg.DatabaseMaxConns)
	if err != nil {
		return err
	}

	defer data.Pool.Close()
	provider, err := identity.Open(startup, cfg)
	if err != nil {
		return err
	}
	cancel()

	listener, err := net.Listen("tcp", cfg.Addr)
	if err != nil {
		return err
	}

	defer listener.Close()
	srv := &http.Server{
		Handler:           httpapi.New(cfg, data, provider, log),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      22 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    32 << 10,
		ErrorLog:          slog.NewLogLogger(log.Handler(), slog.LevelWarn),
	}
	maintenanceDone := make(chan struct{})
	go func() {
		defer close(maintenanceDone)
		data.Maintain(life, func(err error) {
			log.Error("could not clean expired authentication state", "class", "database")
		})
	}()
	defer func() {
		stop()
		<-maintenanceDone
	}()
	stopped := make(chan error, 1)
	go func() { stopped <- srv.Serve(listener) }()
	log.Info("API listening", "address", cfg.Addr)
	select {
	case err := <-stopped:
		return err
	case <-life.Done():
		shutdown, cancel := context.WithTimeout(context.Background(), 22*time.Second)
		defer cancel()
		if err := srv.Shutdown(shutdown); err != nil {
			_ = srv.Close()
			return err
		}
		if err := <-stopped; !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	}
}
