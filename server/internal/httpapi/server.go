package httpapi

import (
	"log/slog"
	"net/http"
	"time"

	"github.com/AryaaaSahu01/Screen-Track/server/internal/config"
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
