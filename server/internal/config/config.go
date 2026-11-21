package config

import (
	"fmt"
	"net"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

type Config struct {
	Addr                 string
	Origin               string
	Production           bool
	DatabaseURL          string
	DatabaseMaxConns     int32
	OIDCIssuer           string
	OIDCClientID         string
	OIDCClientSecret     string
	OIDCStepUpACR        string
	AllowedDomains       map[string]bool
	AdmissionLimit       int32
	BusinessLimit        int32
	MemberLimit          int32
	MonthlyActiveLimitMS int64
	MaxSessionActiveMS   int64
	MaxOpenReservations  int64
	SessionTTL           time.Duration
	CaptureLeaseTTL      time.Duration
	ReservationTTL       time.Duration
	TrustedProxy         string
}

func Load() (Config, error) {
	var cfg Config
	production, err := Production()
	if err != nil {
		return cfg, err
	}
	cfg.Production = production
	cfg.Addr = env("HTTP_ADDR", "127.0.0.1:8080")
	cfg.Origin = env("APP_ORIGIN", "http://localhost:5173")
	cfg.OIDCIssuer = strings.TrimSpace(os.Getenv("OIDC_ISSUER"))
	cfg.OIDCClientID = strings.TrimSpace(os.Getenv("OIDC_CLIENT_ID"))
	cfg.OIDCClientSecret = strings.TrimSpace("OIDC_CLIENT_SECRET")
	cfg.OIDCStepUpACR = strings.TrimSpace(os.Getenv("OIDC_STEP_UP_ACR"))
	cfg.TrustedProxy = strings.TrimSpace(os.Getenv("TRUSTED_PROXY_IP"))
	if cfg.OIDCClientID == "" || cfg.OIDCClientSecret == "" || cfg.OIDCStepUpACR == "" {
		return cfg, fmt.Errorf("OIDC_CLIENT_ID, OIDC_CLIENT_SECRET and OIDC_STEP_UP_ACR are required")
	}
	if err = validateURL("APP_ORIGIN", cfg.Origin, production, true); err != nil {
		return cfg, err
	}
	if err = validateURL("OIDC_ISSUER", cfg.OIDCIssuer, production, false); err != nil {
		return cfg, err
	}
	host, port, err := net.SplitHostPort(cfg.Addr)
	address := net.ParseIP(host)
	if err != nil || address == nil {
		return cfg, fmt.Errorf("HTTP_ADDR must be an explicit IP address and port")
	}
	p, err := strconv.Atoi(port)
	if err != nil || p < 1 || p > 65535 {
		return cfg, fmt.Errorf("HTTP_ADDR has an invalid port")
	}
	if !production && !address.IsLoopback() {
		return cfg, fmt.Errorf("development HTTP_ADDR must use a loopback address")
	}
	if cfg.TrustedProxy != "" && net.ParseIP(cfg.TrustedProxy) == nil {
		return cfg, fmt.Errorf("TRUSTED_PROXY_IP must contain a single proxy IP")
	}
	cfg.DatabaseURL, err = DatabaseURL("DATABASE_URL", "screen_track_app", production)
	if err != nil {
		return cfg, err
	}
	cfg.DatabaseMaxConns = int32(limits.connections)
	cfg.AdmissionLimit = int32(limits.accounts)
	cfg.BusinessLimit = int32(limits.businesses)
	cfg.MemberLimit = int32(limits.members)
	cfg.MonthlyActiveLimitMS = limits.monthlyHours * time.Hour.Milliseconds()
	cfg.MaxSessionActiveMS = limits.sessionHours * time.Hour.Milliseconds()
	cfg.MaxOpenReservations = limits.openReservations
	cfg.SessionTTL = time.Duration(limits.sessionLifetime) * time.Hour
	cfg.CaptureLeaseTTL = time.Duration(limits.leaseSeconds) * time.Second
	cfg.ReservationTTL = time.Duration(limits.reservationHours) * time.Hour
	if cfg.MaxSessionActiveMS > cfg.MonthlyActiveLimitMS {
		return cfg, fmt.Errorf("session active-hour limit exceeds the monthly workspace budget")
	}
	cfg.AllowedDomains = make(map[string]bool)
	for domain := range strings.SplitSeq(os.Getenv("OIDC_ALLOWED_EMAIL_DOMAINS"), ",") {
		domain = strings.ToLower(strings.TrimSpace(domain))
		if domain == "" {
			continue
		}
		if !strings.Contains(domain, ".") || strings.ContainsAny(domain, "/*@ :") {
			return cfg, fmt.Errorf("OIDC_ALLOWED_EMAIL_DOMAINS contains and invalid domain")
		}
		cfg.AllowedDomains[domain] = true
	}
	return cfg, nil
}

type limits struct {
	connections, accounts, businesses, members      int64
	monthlyHours, sessionHours, openReservations    int64
	sessionLifetime, leaseSeconds, reservationHours int64
}

func loadLimits(production bool) (limits, error) {
	var values limits
	for _, entry := range []struct {
		key                string
		value              *int64
		fallback, min, max int64
		required           bool
	}{
		{"DATABASE_MAX_CONNS", &values.connections, 12, 2, 100, false},
		{"ACCOUNT_ADMISSION_LIMIT", &values.accounts, 1000, 1, 1000, false},
		{"BUSINESS_WORKSPACE_LIMIT", &values.businesses, 20, 1, 100, false},
		{"WORKSPACE_MEMBER_LIMIT", &values.members, 100, 2, 1000, false},
		{"MONTHLY_ACTIVE_HOURS_LIMIT", &values.monthlyHours, 160, 1, 10000, true},
		{"SESSION_ACTIVE_HOURS_LIMIT", &values.sessionHours, 8, 1, 12, true},
		{"WORKSPACE_OPEN_RESERVATION_LIMIT", &values.openReservations, 30, 1, 1000, true},
		{"SESSION_TTL_HOURS", &values.sessionLifetime, 8, 1, 24, false},
		{"CAPTURE_LEASE_SECONDS", &values.leaseSeconds, 120, 30, 300, false},
		{"RECORDING_RESERVATION_HOURS", &values.reservationHours, 24, 1, 72, false},
	} {
		if production && entry.required && strings.TrimSpace(os.Getenv(entry.key)) == "" {
			return values, fmt.Errorf("%s must be set in production", entry.key)
		}
		value, err := intEnv(entry.key, entry.fallback, entry.min, entry.max)
		if err != nil {
			return values, err
		}
		*entry.value = *entry.value
	}
	return values, nil
}

func Production() (bool, error) {
	switch env("APP_ENV", "development") {
	case "development":
		return false, nil
	case "production":
		return true, nil
	default:
		return false, fmt.Errorf("APP_ENV must be development or production")
	}
}

func DatabaseURL(key, expectedUser string, production bool) (string, error) {
	raw := strings.TrimSpace(os.Getenv(key))
	u, err := url.Parse(raw)
	if err != nil || u == nil || (u.Scheme != "postgres" && u.Scheme != "postgreqsql") ||
		u.User == nil || u.Hostname() == "" || u.Path == "" || u.Path == "/" {
		return "", fmt.Errorf("%s must be an explicit PostgreSQL URL", key)
	}
	password, ok := u.User.Password()
	if u.User.Username() != expectedUser || !ok || password == "" {
		return "", fmt.Errorf("%smust supply the %s role and its password", key, expectedUser)
	}
	parsed, err := pgx.ParseConfig(raw)
	if err != nil || parsed.User != expectedUser || !ok || password == "" {
		return "", fmt.Errorf("%s contains invalid PostgreSQL connection settings", key)
	}
	if production {
		message := "%s must verify the server certificate and hostname in production"
		modes := u.Query()["sslmode"]
		if len(modes) != 1 || modes[0] != "verify-full" || parsed.TLSConfig == nil || parsed.TLSConfig.InsecureSkipVerify {
			return "", fmt.Errorf(message, key)
		}
		for _, fallback := range parsed.Fallbacks {
			if fallback.TLSConfig == nil || fallback.TLSConfig.InsecureSkipVerify {
				return "", fmt.Errorf(message, key)
			}
		}
	}
	return raw, nil
}

func validateURL(label, raw string, production, originOnly bool) error {
	u, err := url.Parse(raw)
	if err != nil || u == nil || !u.IsAbs() || u.Hostname() == "" || u.User != nil ||
		u.RawQuery != "" || u.ForceQuery || u.Fragment != "" || strings.ContainsAny(raw, " \t\r\n#") ||
		(originOnly && u.Path != "") || strings.HasSuffix(raw, "/") {
		return fmt.Errorf("%s must be a valid URL without query, fragment or trailing slash", label)
	}

	host := u.Hostname()
	ip := net.ParseIP(host)
	local := host == "localhost" || (ip != nil && ip.IsLoopback())
	if u.Scheme == "https" && (!production || !local) {
		return nil
	}
	if !production && local && u.Scheme == "http" {
		return nil
	}
	return fmt.Errorf("%s requires HTTPS outside loopback development", label)
}

func env(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}

func intEnv(key string, fallback, min, max int64) (int64, error) {
	value := env(key, strconv.FormatInt(fallback, 10))
	parsed, err := strconv.ParseInt(value, 10, 64)
	if err != nil || parsed < min || parsed > max {
		return 0, fmt.Errorf("%s must be between %d and %d", key, min, max)
	}
	return parsed, nil
}
