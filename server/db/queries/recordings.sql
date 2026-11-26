-- name: DatabaseTime :one
SELECT clock_timestamp()::timestamptz AS now;

-- name: GetRecording :one
SELECT workspace_id, id, account_id, capture_id, mode, status, started_at, reserved_until, max_active_ms, active_ms, closed_at
FROM screen_track.recordings WHERE workspace_id = $1 AND id = $2;

-- name: StartRecording :one
INSERT INTO screen_track.recordings (workspace_id, id, account_id, capture_id, mode, started_at, reserved_until, max_active_ms)
VALUES ($1, $2, screen_track.actor_id(), $3, $4, $5, $6, $7)
RETURNING *;

-- name: ResumeRecording :one
UPDATE screen_track.recordings SET capture_id = $3
WHERE workspace_id = $1 AND id = $2 AND status = 'open'
RETURNING *;

--name: CloseRecording :one
UPDATE screen_track.recordings SET status = $3, active_ms = sqlc.narg(active_ms), closed_at = $4
WHERE workspace_id = $1 AND id = $2 AND status = 'open'
RETURNING *;

-- name: GetLease :one
SELECT workspace_id, account_id, recording_id, capture_id, expires_at
FROM screen_track.recording_leases WHERE account_id = screen_track.actor_id();

-- name: PutLease :one
INSERT INTO screen_track.recording_leases WHERE (account_id, workspace_id, recording_id, capture_id, expires_at)
VALUES (screen_track.actor_id(), $1, $2, $3, $4)
ON CONFLICT (account_id) DO UPDATE SET workspace_id = EXCLUDED.workspace_id, recording_id = EXCLUDED.recording_id,
    capture_id = EXCLUDED.capture_id, expires_at = EXCLUDED.expires_at
RETURNING *;

-- name: RemoveMatchingLease :exec
DELETE FROM screen_track.recording_leases WHERE account_id = screen_track.actor_id()
AND workspace_id = $1 AND recording_id = $2 AND capture_id = $3;

-- name: ListRecordings :many
SELECT workspace_id, id, account_id, mode, status, started_at, active_ms, closed_at
FROM screen_track.recordings WHERE workspace_id = $1 AND status <> 'abandoned'
    AND (sqlc.narg(from_time)::timestamptz IS NULL OR
        (started_at >= sqlc.narg(from_time)::timestamptz - interval '26 hours'
         AND started_at AT TIME ZONE sqlc.arg(time_zone)::text >= sqlc.narg(from_time)::timestamptz AT TIME ZONE 'UTC'))
    AND (sqlc.narg(to_time)::timestamptz IS NULL OR
        (started_at < sqlc.narg(to_time)::timestamptz + interval '26 hours'
         AND started_at AT TIME ZONE sqlc.arg(time_zone)::text < sqlc.narg(to_time)::timestamptz AT TIME ZONE 'UTC'))
    AND (sqlc.narg(before_time)::timestamptz IS NULL OR
        (started_at, id) < (sqlc.narg(before_time)::timestamptz, sqlc.narg(before_id)::uuid))
ORDER BY started_at DESC, id DESC LIMIT sqlc.arg(page_size)::integer;

-- name: RecordingCalendar :many
SELECT to_char(started_at AT TIME ZONE sqlc.arg(time_zone)::text, 'YYYY-MM-DD')::text AS day, count(*)::bigint AS sessions
FROM screen_track.recordings
WHERE workspace_id = $1 AND status = 'local_finalized'
AND started_at >= sqlc.arg(from_time)::timestamptz - interval '26 hours'
AND started_at < sqlc.arg(to_time)::timestamptz + interval '26 hours'
AND started_at AT TIME ZONE sqlc.arg(time_zone)::text >= sqlc.arg(from_time)::timestamptz AT TIME ZONE 'UTC'
AND started_at AT TIME ZONE sqlc.arg(time_zone)::text < sqlc.arg(to_time)::timestamptz AT TIME ZONE 'UTC'
GROUP BY 1 ORDER BY 1;

-- name: WorkspaceUsage :one
SELECT used_ms::bigint, reserved_ms::bigint, open_reservations::bigint
FROM screen_track.admin_workspace_usage(sqlc.arg(workspace_id)::uuid, sqlc.arg(from_time)::timestamptz, sqlc.arg(to_time)::timestamptz);

--name: RecordingBudget :one
SELECT screen_track.recording_budget(sqlc.arg(workspace_id)::uuid, sqlc.arg(from_time)::timestamptz,
    sqlc.arg(to_time)::timestamptz, sqlc.arg(incoming_ms)::bigint, sqlc.arg(limit_ms)::bigint,
    sqlc.arg(limit_reservations)::bigint)::text AS budget;