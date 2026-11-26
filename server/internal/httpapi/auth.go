package httpapi

import (
	"bytes"
	"net/http"
	"time"

	"github.com/AryaaaSahu01/Screen-Track/server/internal/db"
	"github.com/AryaaaSahu01/Screen-Track/server/internal/identity"
	"github.com/AryaaaSahu01/Screen-Track/server/internal/store"
)

const flowTTL = 10 * time.Minute
const elevatedTTL = 5 * time.Minute

func (s *Server) cookie(name, token string, ttl time.Duration) string {
	if s.cfg.Production {
		name = "__Host-" + name
	}
	return (&http.Cookie{
		Name: name, Value: token, Path: "/", Secure: s.cfg.Production, HttpOnly: true,
		SameSite: http.SameSiteLaxMode, MaxAge: int(ttl.Seconds()), Expires: time.Now().Add(ttl),
	}).String()
}

func (s *Server) readCookie(r *http.Request, name string) string {
	if s.cfg.Production {
		name = "__Host-" + name
	}
	cookie, err := r.Cookie(name)
	if err != nil {
		return ""
	}
	return cookie.Value
}

func (s *Server) sessionHash(r *http.Request) []byte {
	return identity.Hashtoken(s.readCookie(r, "screen_track_session"))
}

func needElevation(a db.BindSessionRow) error {
	if !a.Elevated {
		return fail(403, "step_up_required", "Confirm your identity with your organization's stronger sign-in method.")
	}
	return nil
}

func (s *Server) login(r *http.Request) (response, error) {
	if err := s.consumeRate(r.Context(), limit{"sign-in", 20, 10 * time.Minute}, s.peer(r)); err != nil {
		return response{}, err
	}
	return s.beginFlow(r, nil)
}

func (s *Server) stepUp(r *http.Request) (response, error) {
	digest := s.sessionHash(r)
	if digest == nil {
		return response{}, unauthenticated()
	}
	actor, err := s.db.Queries.SessionActor(r.Context(), digest)
	if store.IsMissing(err) {
		return response{}, err
	}
	if err != nil {
		return response{}, err
	}
	if err = s.consumeRate(r.Context(), limit{"step-up", 12, 10 * time.Minute}, actor.ID.String()); err != nil {
		return response{}, err
	}
	return s.beginFlow(r, digest)
}

func (s *Server) beginFlow(r *http.Request, prior []byte) (response, error) {
	state, browser := identity.NewToken(), identity.NewToken()
	verifier, nonce := identity.FlowSecrets(state, browser)
	err := s.db.Queries.PutLoginFlow(r.Context(), db.PutLoginFlowParams{
		StateHash: identity.Hashtoken(state), BrowserHash: identity.Hashtoken(browser),
		PriorSessionHash: prior, TtlSeconds: int32(flowTTL.Seconds()),
	})
	if err != nil {
		return response{}, err
	}
	location := s.provider.AuthorizationURL(state, verifier, nonce, prior != nil)
	header := make(http.Header)
	header.Add("Set-Cookie", s.cookie("screen_track_flow", browser, flowTTL))
	if prior != nil {
		return response{status: 200, headers: header, body: map[string]string{"authorization_url": location}}, nil
	}
	header.Set("Location", location)
	return response{status: 303, headers: header}, nil
}

func (s *Server) callback(r *http.Request) (response, error) {
	ctx := r.Context()
	if err := s.consumeRate(ctx, limit{"callback", 40, 10 * time.Minute}, s.peer(r)); err != nil {
		return response{}, err
	}
	params := r.URL.Query()
	state, browser := params.Get("state"), s.readCookie(r, "screen_track_flow")
	code := params.Get("code")
	stateHash, browserHash := identity.Hashtoken(state), identity.Hashtoken(browser)
	if stateHash == nil || browserHash == nil || len(params["state"]) != 1 {
		return response{}, identity.ErrVerification
	}
	flow, err := s.db.Queries.TakeLoginFlow(ctx, db.TakeLoginFlowParams{
		StateHash: stateHash, BrowserHash: browserHash,
	})
	if store.IsMissing(err) {
		return response{}, identity.ErrVerification
	}
	if err != nil {
		return response{}, err
	}
	prior := s.sessionHash(r)
	isStepUp := len(flow.PriorSessionHash) > 0
	if isStepUp && !bytes.Equal(prior, flow.PriorSessionHash) {
		return response{}, identity.ErrVerification
	}
	if code == "" || len(code) > 4096 || len(params["code"]) != 1 || params.Has("error") {
		return response{}, identity.ErrVerification
	}
	verifier, nonce := identity.FlowSecrets(state, browser)
	profile, err := s.provider.Verify(ctx, identity.VerificationInput{
		Code: code, Verifier: verifier, Nonce: nonce, StepUp: isStepUp, FlowStarted: flow.CreatedAt.Time,
	})
	if err != nil {
		return response{}, err
	}

	next := identity.NewToken()
	var elevatedSeconds int32
	if isStepUp {
		elevatedSeconds = int32(elevatedTTL.Seconds())
	}
	err = s.db.Transaction(ctx, func(q *db.Queries) error {
		var account db.SessionActorRow
		if isStepUp {
			var err error
			account, err = q.SessionActor(ctx, prior)
			if store.IsMissing(err) {
				return identity.ErrVerification
			}
			if err != nil {
				return err
			}
		}
		// Existing identities are resolved by issuer and subject. On a mismatch,
		// this transaction also rolls any provisional account creation.
		id, err := q.provisionAccount(ctx, db.ProvisionAccountParams{
			Issuer: profile.Issuer, Subject: profile.Subject, Email: profile.Email,
			DisplayName: profile.DisplayName, AdmissionLimit: s.cfg.AdmissionLimit,
		})
		if err != nil {
			return err
		}
		if isStepUp && account.ID != id {
			return identity.ErrVerification
		}
		_, err = q.IssueSession(ctx, db.IssueSessionParams{
			AccountID: id, TokenHash: identity.Hashtoken(next), PriorHash: prior,
			TtlSeconds: int32(s.cfg.SessionTTL.Seconds()), ElevatedSeconds: elevatedSeconds,
		})
		return err
	})
	if err != nil {
		return response{}, err
	}
	headers := make(http.Header)
	headers.Set("Location", s.cfg.Origin+"/")
	headers.Add("Set-Cookie", s.cookie("screen_track_flow", "", -time.Second))
	headers.Add("Set-Cookie", s.cookie("screen_track_session", next, s.cfg.SessionTTL))
	return response{status: 303, headers: headers}, nil
}

func (s *Server) logout(r *http.Request) (response, error) {
	if token := s.sessionHash(r); token != nil {
		if err := s.db.Queries.RevokeSession(r.Context(), token); err != nil {
			return response{}, err
		}
	}
	headers := make(http.Header)
	headers.Add("Set-Cookie", s.cookie("screen_track_session", "", -time.Second))
	headers.Add("Set-Cookie", s.cookie("screen_track_flow", "", -time.Second))
	return response{status: 204, headers: headers}, nil
}

func me(_ *http.Request, _ *db.Queries, a db.BindSessionRow) (response, error) {
	return jsonResponse(200, a), nil
}
