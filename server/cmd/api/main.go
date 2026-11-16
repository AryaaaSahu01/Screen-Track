package main

import (
	"encoding/json"
	"log"
	"net/http"
	"time"
)

func health(w http.ResponseWriter, req *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(map[string]string{"status": "ok"}); err != nil {
		log.Printf("write health response: %v", err)
	}
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", health)

	server := &http.Server{
		Addr:              "127.0.0.1:8080",
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	log.Printf("API listening on http://%s", server.Addr)
	log.Fatal(server.ListenAndServe())
}
