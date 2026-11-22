CREATE SCHEMA IF NOT EXISTS screen_track;

CREATE TABLE screen_track.accounts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    issuer text NOT NULL CHECK (length(issuer) BETWEEN 1 AND 512),
    subject text NOT NULL CHECK (length(subject) BETWEEN 1 AND 255),
    email text NOT NULL UNIQUE CHECK (length(email) BETWEEN 3 AND 254 AND split_part(email, '@', 2) = lower(split_part(email, '@',2))),
    display_name text NOT NULL CHECK (length(display_name) BETWEEN 1 AND 120)
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    disabled_at timestamptz,
    UNIQUE (issuer, subject)
);

CREATE TABLE screen_track.sessions (
    token_hash bytea PRIMARY KEY CHECK (octet_length(token_hash) = 32),
    account_id uuid NOT NULL REFERENCES screen_track.account(id) ON DELETE CASCADE, 
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    expires_at timestamptz NOT NULL,
    elevated_until timestamptz,
    CHECK (expires_at > created_at),
    CHECK (elevated_until <= expires_at)
);

CREATE INDEX sessions_expiry_idx ON screen_track.sessions (expires_at);

CREATE TABLE screen_track.login_flows (
    state_hash bytea PRIMARY KEY CHECK (octet_length(state_hash) = 32 ),
    browser_hash bytea NOT NULL CHECK (octet_length(browser_hash) = 32),
    prior_session_hash bytea CHECK (octet_length(prior_session_hash) = 32),
)