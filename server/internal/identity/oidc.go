package identity

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/mail"
	"net/url"
	"slices"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/AryaaaSahu01/Screen-Track/server/internal/config"
	"github.com/coreos/go-oidc/v3/oidc"
	"golang.org/x/oauth2"
)

const CallBackPath = "/api/v1/auth/callback"

var ErrVerification = errors.New("identity response could not be verified")

type Provider struct {
	client    *http.Client
	oauth     oauth2.Config
	verifier  *oidc.IDTokenVerifier
	issuer    string
	stepUpACR string
	domains   map[string]bool
}

type Profile struct {
	Issuer      string
	Subject     string
	Email       string
	DisplayName string
}

type VerificationInput struct {
	Code        string
	Verifier    string
	Nonce       string
	StepUp      bool
	FlowStarted time.Time
}

func Open(ctx context.Context, cfg config.Config) (*Provider, error) {
	client := &http.Client{
		Timeout: 8 * time.Second,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	ctx = oidc.ClientContext(ctx, client)
	provider, err := oidc.NewProvider(ctx, cfg.OIDCIssuer)
	if err != nil {
		return nil, fmt.Errorf("OIDC discovery failed: %w", err)
	}
	var discovery struct {
		KeysURL     string   `json:"jwks_uri"`
		PKCEMethods []string `json:"code_challenge_methods_supported"`
	}
	if err := provider.Claims(&discovery); err != nil {
		return nil, fmt.Errorf("decode OIDC discovery metadata: %w", err)
	}
	if len(discovery.PKCEMethods) > 0 && !slices.Contains(discovery.PKCEMethods, "S256") {
		return nil, fmt.Errorf("OIDC provider must support S256 PKCE")
	}
	endpoint := provider.Endpoint()
	for _, raw := range []string{endpoint.AuthURL, endpoint.TokenURL, discovery.KeysURL} {
		if !validEndpoint(raw, cfg.Production) {
			return nil, fmt.Errorf("OIDC provider advertises an invalid or insecure endpoint")
		}
	}
	endpoint.AuthStyle = oauth2.AuthStyleInHeader
	return &Provider{
		client: client,
		oauth: oauth2.Config{
			ClientID: cfg.OIDCClientID, ClientSecret: cfg.OIDCClientSecret,
			RedirectURL: cfg.Origin + CallBackPath,
			Endpoint:    endpoint, Scopes: []string{oidc.ScopeOpenID, "email", "profile"},
		},
		verifier: provider.VerifierContext(ctx, &oidc.Config{ClientID: cfg.OIDCClientID}),
		issuer:   cfg.OIDCIssuer, stepUpACR: cfg.OIDCstepUpACR, domains: cfg.AllowedDomains,
	}, nil
}
func validEndpoint(raw string, production bool) bool {
	u, err := url.Parse(raw)
	if err != nil || u == nil || u.Hostname() == "" || u.User != nil || u.Fragment != "" {
		return false
	}

	if u.Scheme == "https" {
		return true
	}
	ip := net.ParseIP(u.Hostname())
	return !production && u.Scheme == "http" &&
		(u.Hostname() == "localhost" || (ip != nil && ip.IsLoopback()))
}

func (p *Provider) AuthorizationURL(state, verifier, nonce string, elevated bool) string {
	opts := []oauth2.AuthCodeOption{
		oauth2.S256ChallengeOption(verifier),
		oidc.Nonce(nonce),
	}
	if elevated {
		claims, _ := json.Marshal(map[string]any{
			"id_token": map[string]any{
				"acr":       map[string]any{"essential": true, "values": []string{p.stepUpACR}},
				"auth_time": map[string]bool{"essential": true},
			},
		})
		opts = append(opts, oauth2.SetAuthURLParam("max_age", "0"),
			oauth2.SetAuthURLParam("prompt", "login"),
			oauth2.SetAuthURLParam("acr_values", p.stepUpACR),
			oauth2.SetAuthURLParam("claims", string(claims)))
	}
	return p.oauth.AuthCodeURL(state, opts...)
}

func (p *Provider) Verify(ctx context.Context, input VerificationInput) (Profile, error) {
	ctx := oidc.ClientContext(ctx, p.client)
	token, err := p.oauth.Exchange(ctx, input.Code, oauth2.VerifierOption(input.Verifier))
	if err != nil {
		return Profile{}, ErrVerification
	}

	raw, ok := token.Extra("id_token").(string)
	if !ok || len(raw) == 0 || len(raw) > 32<<10 {
		return Profile{}, ErrVerification
	}
	idToken, err := p.verifier.Verify(ctx, raw)
	if err != nil || idToken.Issuer != p.issuer ||
		subtle.ConstantTimeCompare([]byte(idToken.Nonce), []byte(input.Nonce)) != 1 ||
		len(idToken.Subject) == 0 || len(idToken.Subject) > 255 ||
		strings.ContainsFunc(idToken.Subject, unicode.IsControl) {
		return Profile{}, ErrVerification
	}

	var claims struct {
		Email         string `json:"email"`
		EmailVerified bool   `json:"email_verified"`
		Name          string `json:"name"`
		AuthUnix      int64  `json:"auth_time"`
		ACR           string `json:"acr"`
		AZP           string `json:"azp"`
	}
	if err = idToken.Claims(&claims); err != nil || !claims.EmailVerified {
		return Profile{}, ErrVerification
	}
	if (len(idToken.Audience) > 1 || claims.AZP != "") && claims.AZP != p.oauth.ClientID {
		return Profile{}, ErrVerification
	}
	now := time.Now()
	if idToken.IssuedAt.IsZero() || idToken.IssuedAt.After(now.Add(30*time.Second)) ||
		idToken.IssuedAt.Before(input.FlowStarted.Add(-time.Minute)) {
		return Profile{}, ErrVerification
	}
	if input.StepUp {
		authTime := time.Unix(claims.AuthUnix, 0)
		if claims.ACR != p.stepUpACR || claims.AuthUnix <= 0 ||
			authTime.Before(input.FlowStarted.Add(-30*time.Second)) ||
			authTime.Before(now.Add(-5*time.Minute)) || authTime.After(now.Add(30*time.Second)) {
			return Profile{}, ErrVerification
		}
	}
	email, ok := NormalizeEmail(claims.Email)
	if !ok {
		return Profile{}, ErrVerification
	}
	_, domain, _ := strings.Cut(email, "@")
	if len(p.domains) > 0 && !p.domains[domain] {
		return Profile{}, ErrVerification
	}
	name := strings.TrimSpace(strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return -1
		}
		return r
	}, claims.Name))
	if name == "" {
		name = strings.SplitN(email, "@", 2)[0]
	}
	for utf8.RuneCountInString(name) > 120 {
		_, size := utf8.DecodeLastRuneInString(name)
		name = name[:len(name)-size]
	}
	return Profile{Issuer: idToken.Issuer, Subject: idToken.Subject, Email: email, DisplayName: name}, nil
}

func NormalizeEmail(value string) (string, bool) {
	value = strings.TrimSpace(value)
	if len(value) < 3 || len(value) > 254 || strings.Count(value, "@") != 1 ||
		strings.ContainsAny(value, "\" \t\r\n") || strings.ContainsFunc(value, unicode.IsControl) {
		return "", false
	}
	address, err := mail.ParseAddress(value)
	if err != nil || address.Address != value || address.Name != "" {
		return "", false
	}
	local, domain, _ := strings.Cut(value, "@")
	return local + "@" + strings.ToLower(domain), true
}
