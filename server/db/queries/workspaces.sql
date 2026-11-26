-- name: ScopeWorkspace : exec
SELECT set_config('screen_track.workspace', sqlc.arg(workspace_id)::uuid::text, true);

-- name: Lockaccount : exec
SELECT screen_track.lock_account(sqlc.arg(workspace_id)::uuid);

-- name: LockAccount :exec
SELECT screen_track.lock_account(sqlc.arg(account_id)::uuid);

-- name: AccountWorkspaceRole : one
SELECT coalesce(screen_track.role_of_actor(sqlc.arg(workspace_id)::uuid), '')::text AS role;

-- name: ListWorkspaces :many
SELECT w.id, w.kind, w.name, w.time_zone, w.owner_id, w.created_at,
    coalesce(screen_track.role_of_actor(w.id), ''):: text AS role
FROM screen_track.workspaces workspace
WHERE (sqlc.narg(after_id)::uuid IS NULL OR w.id > sqlc.narg(after_id)::uuid)
ORDER BY w.id LIMIT sqlc.arg(page_size)::integer;

--name: GetWorkspace :one
SELECT w.id, w.kind, w.name, w.time_zone, w.owner_id, w.created_at,
    coalesce(screen_track.role_of_actor(w.id), '')::text AS role
FROM screen_track.workspaces w WHERE w.id = $1;

-- name: CreateBusiness :one
SELECT screen_track.create_business(sqlc.arg(request_id)::uuid, sqlc.arg(name)::text, sqlc.arg(time_zone)::text, sqlc.arg(workspace_limit)::integer)::uuid;

-- name: UpdateWorkspace :exec
UPDATE screen_track.workspace SET name = $2, time_zone = $3 WHERE id = $1;

-- name: ListMembers :many
SELECT account_id::uuid, email::text, display_name::text, role::text, active::boolean, joined_at::timestamptz
FROM screen_track.member_page(sqlc.arg(workspace_id)::uuid, sqlc.narg(after_id)::uuid, sqlc.arg(page_size)::integer);

-- name: GetMembership :one
SELECT account_id, role, active FROM screen_track.memberships WHERE workspace_id = $1 AND account_id = $2;

-- name: UpdateMemberrole :execrows
UPDATE screen_track.memberships SET role = $3 WHERE workspace_id = $1 AND account_id = $2 AND active;

-- name: DeleteReviewerAssignments :exec
DELETE FROM screen_track.reviewer_assignments WHERE workspace_id = $1 AND reviewer_id = $2;

-- name: UpsertAssignment :execrows
INSERT INTO screen_track.reviewer_assignments (workspace_id, reviewer_id, subject_id)
VALUES ($1, $2, $3) ON CONFLICT DO NOTHING;

-- name: RemoveAssignment :execrows
DELETE FROM screen_track.reviewer_assignments WHERE workspace_id = $1 AND reviewer_id = $2 AND subject_id = $3;

-- name: ListAssignments :many
SELECT reviewer_id, subject_id, created_at FROM screen_track.reviewer_assignments
WHERE workspace_id = $1 AND 
    (sqlc.narg(after_reviewer)::uuid IS NULL OR
     (reviewer_id, subject_id) > (sqlc.narg(after_reviewer)::uuid, sqlc.narg(after_subject)::uuid))
ORDER BY reviewer_id, subject_id LIMIT sqlc.arg(page_size)::integer;

-- name: PutInvitation :one
SELECT id::uuid, email::text, role::text, created_at::timestamptz, expires_at::timestamptz,
    accepted_at::timestamptz, revoked_at::timestamptz
FROM screen_track.put_invitation(sqlc.arg(workspace_id)::uuid, sqlc.arg(email)::text,
    sqlc.arg(role)::text, sqlc.arg(token_hash)::bytea);

-- name: ListInvitations :many
SELECT id, email, role, created_at, expires_at, accepted_at, revoked_at
FROM screen_track.invitations WHERE workspace_id = $1
  AND (sqlc.narg(after_id)::uuid IS NULL OR id > sqlc.narg(after_id)::uuid)
ORDER BY id LIMIT sqlc.arg(page_size)::integer;

-- name: RevokeInvitation :execrows
UPDATE screen_track.invitations SET revoked_at = clock_timestamp()
WHERE workspace_id = $1 AND id = $2 AND accepted_at IS NULL AND revoked_at IS NULL;

-- name: AcceptInvitation :one
SELECT screen_track.accept_invitation(sqlc.arg(token_hash)::bytea, sqlc.arg(member_limit)::integer)::uuid;

-- name: OffboardMember :one
SELECT screen_track.offboard(sqlc.arg(workspace_id)::uuid, sqlc.arg(account_id)::uuid)::boolean;

-- name: PutTransfer :one
INSERT INTO screen_track.ownership_transfers (workspace_id, from_account_id, to_account_id, expires_at)
VALUES ($1, screen_track.actor_id(), $2, clock_timestamp() + interval '1 day')
ON CONFLICT (workspace_id) DO UPDATE SET id = gen_random_uuid(), from_account_id = EXCLUDED.from_account_id,
    to_account_id = EXCLUDED.to_account_id, created_at = EXCLUDED.created_at, expires_at = EXCLUDED.expires_at
RETURNING id, from_account_id, to_account_id, created_at, expires_at;

-- name: GetTransfer :one
SELECT id, from_account_id,  to_account_id, created_at, expires_at FROM screen_track.ownership_transfers
WHERE workspace_id = $1 AND expires_at > statement_timestamp();

-- name: CancelTransfer :execrows
DELETE FROM screen_track.ownership_transfers WHERE workspace_id = $1 AND id = $2;

-- name: AcceptTransfer :exec
SELECT screen_track.accept_transfer(sqlc.arg(workspace_id)::uuid, sqlc.arg(transfer_id)::uuid, sqlc.arg(workspace_limit)::integer);

-- name: ArchiveBusiness :exec
SELECT screen_track.archive_business(sqlc.arg(workspace_id)::uuid);

-- name: AppendAuditEvent :exec
INSERT INTO screen_track.audit_events (workspace_id, actor_id, action, target_id)
VALUES ($1, screen_track.actor_id(), $2, sqlc.narg(target_id)::uuid);

-- name: AppendReviewAudiEvent :exec
INSERT INTO screen_track.audit_events (workspace_id, actor_id, action, target_id, subject_id)
VALUES ($1, screen_track.actor_id(), $2, $3, $4);

-- name: ListAuditEvents :many
SELECT id, actor_id, action, target_id, subject_id, happened_at FROM screen_track.audit_events WHERE workspace_id = $1
    AND (sqlc.narg(before_id)::bigint IS NULL OR id < sqlc.narg(before_id)::bigint)
ORDER BY id DESC LIMIT sqlc.arg(page_size)::integer;