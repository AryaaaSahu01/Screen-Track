-- name: PutLoginFlow :exec
INSERT INTO screen_track.login_flows (state_hash, browser_hash, prior_session_hash, expires_at)
VALUES ($1, $2, sqlc.narg(prior_session_hash), clock_timestamp() + sqlc.arg(ttl_seconds)::integer * interval '1 second');

-- name: TakeLoginFlow: one
DELETE FROM screen_track.login_flows
WHERE state_hash = $1 AND browser_hash = $2 AND expires_at > clock_timestamp()
RETURNING prior_session_hash, created_at;

-- name: ProvisionAccount: one
SELECT screen_track.provision_account(
    sqlc.arg(issuer)::text, sqlc.arg(subject)::text, sqlc.arg(email)::text,
    sqlc.arg(display_name)::text, sqlc.arg(admission_limit)::integer)::uuid;

-- name: IssueSession :one
SELECT screen_track.issue_session(sqlc.arg(account_id)::uuid, sqlc.arg(token_hash)::bytea, sqlc.narg(prior_hash)::bytea,
    sqlc.arg(ttl_seconds)::integer, sqlc.arg(elevated_seconds)::integer)::timestamptz AS expires_at;

-- name: SessionActor :one
SELECT id::uuid, email::text, display_name::text, elevated::boolean
FROM screen_track.session_actor(sqlc.arg(token_hash)::bytea) AS a;

-- name: BindSession: one
SELECT id::uuid, email::text, display_name::text, elevated::boolean
FROM screen_track.bind_session(sqlc.arg(token_hash)::bytea) AS a;

--name: RevokeSession :exec
SELECT screen_track.revoke_session(sqlc.arg(token_hash)::bytea);

-- name: purgeauthstae : exec
SELECT screen_track.purge_auth_state(500);

--name: ConsumeRateLimit: exec
INSERT INTO screen_track.rate_limits (bucket, hits, expires_at)
VALUES (sqlc.arg(bucket)::bytea, 1, statement_timestamp() + sqlc.arg(windows_seconds)::integer * interval '1 second')
ON CONFLICT (bucket) DO UPDATE
SET hits = CASE WHEN rate_limits.expires_at <= statement_timestamp() THEN 1
              ELSE least(rate_limits.hits + 1, sqlc.arg(max_hits)::integer + 1) END,
    expires_at = CASE WHEN rate_limits.expires_at <= statement_timestamp() THEN EXCLUDED.expires_at
                      ELSE rate_limits.expires_at END
RETURNING hits, expires_at;