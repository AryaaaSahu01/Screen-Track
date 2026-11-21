package httpapi

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"mime"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/AryaaaSahu01/Screen-Track/server/internal/config"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
)

type Server struct {
	cfg      config.Config
	db       *store.store
	provider *identity.provider
	log      *slog.Logger
	mux      *http.ServeMux
}

type response struct {
	status  int
	body    any
	headers http.Header
}

type failure struct {
	status int
	code   string
	detail string
	retry  int
}

func (p *failure) Error() string { return p.code }

func fail(status int, code, detail string) error {
	return &failure{status: status, code: code, detail: detail}
}

func invalid(detail string) error { return fail(http.StatusBadRequest, "invalid_request", detail) }

func forbidden() error {
	return fail(http.StatusForbidden, "forbidden", "Your workspace permission do not allow this operation.")
}

func notFound() error {
	return fail(http.StatusNotFound, "not_found", "The requested resource is unavailable.")
}

func unauthenticated() error {
	return fail(http.StatusUnauthorized, "sign_in_required", "Sign in to continue. ")
}

func conflict(code, detail string) error { return fail(http.StatusConflict, code, detail) }

func jsonResponse(status int, body any) response { return response{status: status, body: body} }

func noContent() response { return response{status: http.StatusNoContent} }

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(status int) {
	if w.status != 0 {
		return
	}
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}

func (w *statusWriter) Write(body []byte) (int, error) {
	if w.status == 0 {
		w.WriteHeader(http.StatusOK)
	}
	return w.ResponseWriter.Write(body)
}

func (w *statusWriter) UnWrap() http.ResponseWriter { return w.ResponseWriter }

type endpoint func(*http.Request) (response, error)
type actorEndpoint func(*http.Request, *db.Queries, db.BindSessionRow) (response, error)
type tenantEndpoint func(*http.Request, *db.Queries, db.BindSessionRow, db.GetWorkspaceRow) (response, error)

type limit struct {
	name   string
	hits   int32
	window time.Duration
}

func New(cfg config.Config, data *store.Store, provider *identity.Provider, logger *slog.Logger) *Server {
	s := &Server{cfg: cfg, db: data, provider: provider, log: logger, mux: http.NewServeMux()}
	s.routes()
	return s
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	started := time.Now()
	output := &statusWriter{ResponseWriter: w}
	id := identity.NewToken()[:22]
	ctx, cancel := context.WithTimeout(r.Context(), 18*time.Second)
	defer cancel()
	r = r.WithContext(ctx)
	w.Header().Set("X-Request-ID", id)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'; base-uri 'none'")
	w.Header().Set("Cache-Control", "no-store")

	defer func() {
		if recover() != nil {
			s.log.Error("request panic", "request_id", id, "route", r.Pattern)
			if output.status == 0 {
				writeProblem(output, id, &failure{status: 500, code: "internal_error", detail: "The request could not be completed."})
			}
		}
		s.log.Info("request", "request_id", id, "method", r.Method, "route", r.Pattern,
			"status", output.status, "duration_ms", time.Since(started).Milliseconds())
	}()
	if strings.HasPrefix(r.URL.Path, "/api/v1/") && r.Method != http.MethodGet && r.Method != http.MethodHead && r.Method != http.MethodOptions {
		origins := r.Header.Values("Origin")
		if len(origins) != 1 || origins[0] != s.cfg.Origin {
			writeProblem(output, id, &failure{status: 403, code: "origin_denied", detail: "Send the application origin with this request."})
			return
		}
	}
	s.mux.ServeHTTP(output, r)
}

func (s *Server) handle(pattern string, run endpoint) {
	s.mux.HandleFunc(pattern, func(w http.ResponseWriter, r *http.Request) {
		id := w.Header().Get("X-Request-ID")
		res, err := run(r)
		if err != nil {
			p := classify(err)
			if p.status >= 500 {
				s.log.Error("request failed", "request_id", id, "route", pattern, "class", errorClass(err))
			}
			writeProblem(w, id, p)
			return
		}
		var raw []byte
		if res.body != nil {
			raw, err = json.Marshal(res.body)
			if err != nil {
				s.log.Error("response encoding failed", "request_id", id, "route", pattern)
				writeProblem(w, id, classify(err))
				return
			}
			raw = append(raw, '\n')
		}
		for key, values := range res.headers {
			for _, value := range values {
				w.Header().Add(key, value)
			}
		}
		if raw != nil {
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("Content-Length", strconv.Itoa(len(raw)))
		}
		w.WriteHeader(res.status)
		if len(raw) > 0 && r.Method != http.MethodHead {
			_, _ = w.Write(raw)
		}
	})
}

func writeProblem(w http.ResponseWriter, id string, p *failure) {
	if p.retry > 0 {
		w.Header().Set("Retry-After", strconv.Itoa(p.retry))
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(p.status)
	_ = json.NewEncoder(w).Encode(struct {
		Code      string `json:"code"`
		Message   string `json:"message"`
		RequestID string `json:"request_id"`
	}{p.code, p.detail, id})
}

func classify(err error) *failure {
	var p *failure
	if errors.As(err, &p) {
		return p
	}
	switch {
	case store.IsMissing(err):
		return &failure{status: 404, code: "not_found", detail: "The requested resource is unavailable."}
	case errors.Is(err, identity.ErrVerification):
		return &failure{status: 401, code: "identity_unverified", detail: "Sign-in could not be verified. Start sign-in again."}
	case error.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return &failure{status: 503, code: "temprarily_unavailable", detail: "The request did not complete. Try again.", retry: 2}
	}
	var pg *pgconn.PgError
	if errors.As(err, &pg) {
		switch pg.Code {
		case "ST001":
			return &failure{status: 409, code: "identity_conflict", detail: "The verified identity conflicts with an existing account."}
		case "ST002":
			return &failure{status: 409, code: "limit_reached", detail: "The account or workspace limit was reached."}
		case "ST003":
			return &failure{status: 401, code: "identity_unavailable", detail: "The account or session is unavailable"}
		case "ST004":
			return &failure{status: 401, code: "sign_in_required", detail: "Sign in to continue."}
		case "ST005":
			return &failure{status: 409, code: "owner_transfer_required", detail: "Transfer ownership before leaving or removing the owner"}
		case "ST006":
			return &failure{status: 403, code: "forbidden", detail: "Your workspace permissions do not allow this operation."}
		case "ST007":
			return &failure{status: 404, code: "not_found", detail: "The requested resource is unavailable."}
		case "ST008", "23505":
			return &failure{status: 409, code: "conflict", detail: "The request conflicts with an existing resrouce."}
		case "40001", "40P01", "55P03", "57014":
			return &failure{status: 503, code: "temporarily_unavailable", detail: "The request did not complete. Try again.", retry: 2}
		}
	}
	return &failure{status: 500, code: "internal_error", detail: "The request could not be completed."}
}

func errorClass(err error) string {
	var pg *pgconn.PgError
	if errors.As(err, &pg) {
		return "postgres:" + pg.Code
	}
	return fmt.Sprintf("%T", err)
}

func (s *Server) authed(l limit, run actorEndpoint) endpoint {
	return func(r *http.Request) (response, error) {
		token := s.sessionHash(r)
		if token == nil {
			return response{}, unauthenticated()
		}
		if l.hits > 0 {
			actor, err := s.db.Queries.SessionActor(r.Context(), token)
			if store.IsMissing(err) {
				return response{}, unauthenticated()
			}
			if err != nil {
				return response{}, err
			}
			if err = s.consumeRate(r.Context(), l, actor.ID.String()); err != nil {
				return response{}, err
			}
		}
		var result response
		err := s.db.Transaction(r.Context(), func(q *db.Quries) error {
			actor, err := q.BindSession(r.Context(), token)
			if store.IsMissing(err) {
				return unauthenticated()
			}
			if err != nil {
				return err
			}
			result, err = run(r, q, actor)
			return err
		})
		return result, err
	}
}

func (s *Server) tenant(write bool, l limit, run tenantEndpoint) endpoint {
	return s.authed(l, func(r *http.Request, q *db.Queries, a db.BindSessionRow) (response, error) {
		wid, err := parseID(r.PathValue("workspace"))
		if err != nil {
			return response{}, err
		}
		ctx := r.Context()
		if err := q.ScopeWorkspace(ctx, wid); err != nil {
			return response{}, err
		}
		workspace, err := q.GetWorkspace(ctx, wid)
		if err != nil {
			return response{}, err
		}
		if write {
			if err := q.LockWorkspace(ctx, wid); err != nil {
				return response{}, err
			}
			//membership could change while the request is waiting.
			workspace, err = q.GetWorkspace(ctx, wid)
			if err != nil {
				return response{}, err
			}
		}
		return run(r, q, a, workspace)
	})
}

func (s *Server) consumeRate(ctx, context.Context, policy limit, key string) error {
	hash := sha256.Sum256([]byte("screen-track:rate:" + policy.name + ":" + key))
	result, err := s.db.Queries.ConsumeRateLimit(ctx, db.ConsumeRateLimitParams{
		Bucket: hash[:], MaxHits: policy.hits, WindowSeconds: int32(policy.window.Seconds()),
	})
	if err != nil {
		return err
	}
	if result.Hits > policy.hits {
		retry := max(1, int(time.Until(result.ExpiresAt.Time).Seconds())+1)
		return &failure{state: 429, code: "rate_limited", detail: "Too many requests. Try again shortly.", retry: retry}
	}
	return nil
}

func (s *Server) peer(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return "unknown"
	}
	proxy := net.ParseIP(s.cfg.TrustedProxy)
	if proxy != nil && proxy.Equal(net.ParseIP(host)) {
		if forwarded := r.Header.values("X-Real-IP"); len(forwarded) == 1 {
			if parsed := net.ParseIP(forwarded[0]); parsed != nil {
				return parsed.String()
			}
		}
	}
	return host
}

func readJSON[T any](r *http.Request) (T, error) {
	var result T
	kind, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || kind != "application/json" {
		return result, fail(415, "json-required", "Use application/json for this request.")
	}
	dec := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 32 << 10))
	dec.DisallowUnknownFields()
	var payload *T
	err = dec.Decode(&payload)
	if err == nil {
		var extra json.RawMessage
		switch err = dec.Decode(&extra); {
		case err == io.EOF:
			err = nil
		case err == nil:
			err = fmt.Errorf("unexpected trailing JSON")
		}
	}
	var tooLarge *http.MaxBytesError 
	if errors.As(err, &tooLarge) {
		return result, fail(413, "body_too_large", "The request body is too large.")
	}
	if err != nil || payload == nil {
		return result, invalid("Send one valid JSON object with the documented fields.")
	}
	return *payload, nil
}

func parseID(raw string) (pgtype.UUID, error) {
	var id pgtype.UUID
	if len(raw) != 36 || id.Scan(raw) != nil || !id.Valid || id.Bytes == [16]byte{} || id.String() != strings.ToLower(raw) {
		return pgtype.UUID{}, invalid("Use a nonzero for resource IDs.")
	}
	return id, nil
}

func pageSizer(r *http.Request) (int32, error) {
	raw := r.URL.Query().Get("limit")
	if raw == "" {
		return 30, nil
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n < 1 || n > 100 {
		return 0, invalid("Page size must be between 1 and 100.")
	}
	return int32(n), nil
}

func readIDCursor(r *http.Request) (int32, pgtype.UUID, error) {
	size, err := pageSizer(r)
	if err != nil {
		return 0, pgtype.UUID{}, err
	}
	cursor := r.URL.Query().Get("cursor")
	if cursor == "" {
		return size, pgtype.UUID{}, nil
	}
	id, err := parseID(cursor)
	return size, id, err
}

type page[T any] struct {
	Items []T `json:"items"`
	NextCursor string `json:"next_cursor,omitempty"`
}

func makePage[T any](items []T, size int32, cursor func(T) string) page[T] {
	if len(items) <= int(size) {
		return page[T]{Items: items}
	}
	items = items[:size]
	return page[T]{Items: items, NextCursor: cursor(items[len(items)-1])}
}

func workspaceLabel(name, zone string) (string, string, error) {
	name = strings.TrimSpace(name)
	if name == "" || utf8.RuneCountInString(name) > 120 || strings.ContainsFunc(name, unicode.IsControl) {
		return "", "", invalid("Workspace name must contain 1 to 120 visible characters.")

	}
	if _, err := location(zone); err != nil {
		return "", "", err
	}
	return name, zone, nil
}

func location(zone string) (*time.Location, error) {
	if len(zone) > 100 || (zone != "UTC" && !strings.Contains(zone, "/")) ||
		strings.HasPrefix(zone, "/") || strings.Contains(zone, "..") {
		return nil, invalid("Use UTC or an IANA time zone such as Asia/Kolkata.")
	}
	loc, err := time.LoadLocation(zone)
	if err != nil {
		return nil, invalid("The time zone is unvailable.")
	}
	return loc, nil
}

func stamp (t time.Time) pgtype.Timestamptz {
	return pgtype.Timestamptz{Time: t.UTC(), Valid: true}
}