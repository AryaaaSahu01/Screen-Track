CREATE TABLE screen_track.recordings (
    workspace_id uuid NOT NULL,
    id uuid NOT NULL,
    account_id uuid NOT NULL, 
    capture_id uuid NOT NULL,
    mode text NOT NULL CHECK (mode IN ('fast', 'screenshots', 'both')),
    status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'local_finalized','abandoned')),
    started_at timestamptz NOT NULL,
    reserved_until timestamptz NOT NULL,
    max_active_ms bigint NOT NULL CHECK (max_active_ms > 0),
    active_ms bigint,
    closed_at timestamptz,
    PRIMARY KEY (workspace_id, id),
    UNIQUE (workspace_id, account_id, id),
    FOREIGN KEY (workspace_id, account_id) REFERENCES screen_track.memberships(workspace_id, account_id),
    CHECK (status <> 'local_finalized' OR active_ms > 0 AND active_ms <= max_active_ms),
    CHECK (status <> 'local_finalized' OR active_ms IS NOT NULL),
    CHECK (status = 'local_finalized' OR active_ms IS NULL),
    CHECK ((status = 'open') = (closed_at IS NULL))
);
CREATE INDEX recording_page_idx ON screen_track.recordings (workspace_id, started_at DESC, id DESC);
CREATE INDEX recording_subject_page_idx ON screen_track.recordings (workspace_id, account_id, started_at DESC, id DESC);
CREATE INDEX recording_reservations_idx ON screen_track.recordings (workspace_id, reserved_until) WHERE status = 'open';

CREATE TABLE screen_track.recording_leases (
    account_id uuid PRIMARY KEY,
    workspace_id uuid NOT NULL,
    recording_id uuid NOT NULL, 
    capture_id uuid NOT NULL, 
    expires_at timestamptz NOT NULL, 
    FOREIGN KEY (workspace_id, recording_id, account_id) REFERENCES screen_track.recordings(workspace_id, id, account_id)
);

CREATE FUNCTION screen_track.active_business(p_workspace uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog
    AS $$
        SELECT EXISTS (SELECT 1 FROM screen_track.workspaces
            WHERE id = p_workspace AND kind = 'business' AND archived_at IS NULL
                AND screen_track.role_here(p_workspace) IS NOT NULL)
    $$;

CREATE FUNCTION screen_track.workspace_usage(p_workspace uuid, p_start timestamptz, p_end timestamptz)
    RETURNS TABLE (used_ms bigint, reserved_ms bigint, open_reservations bigint)
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog
    AS $$
        SELECT coalesce(sum(r.active_ms) FILTER (WHERE r.status = 'local_finalized'), 0)::bigint,
                coalesce(sum(r.max_active_ms) FILTER (WHERE r.status = 'open' AND r.reserved_until > statement_timestamp())),
                count(*) FILTER (WHERE r.status = 'open' AND r.reserved_until > statement_timestamp())
        FROM screen_track.recordings r
        WHERE r.workspace_id = p_workspace
            AND r.started_at >= p_start AND r.started_at < p_end
    $$;

CREATE FUNCTION screen_track.admin_workspace_usage(p_workspace uuid, p_start timestamptz, p_end timestamptz)
    RETURNS TABLE (used_ms bigint, reserved_ms bigint, open_reservations bigint)
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog
    AS $$
        SELECT * FROM screen_track.workspace_usage(p_workspace, p_start, p_end)
        WHERE screen_track.role_here(p_workspace) IN ('owner', 'coordinator')
    $$;

CREATE FUNCTION screen_track.recording_budget(p_workspace uuid, p_start timestamptz, p_end timestamptz,
    p_incoming bigint, p_limit bigint, p_max_open bigint) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog
    AS $$
        SELECT CASE
            WHEN NOT screen_track.active_business(p_workspace) THEN 'forbidden'
            WHEN p_incoming > p_limit - usage.used_ms - usage.reserved_ms THEN 'monthly'
            WHEN (SELECT count(*) FROM screen_track.recordings r WHERE r.workspace_id = p_workspace
                  AND r.status = 'open' AND r.reserved_until > statement_timestamp()) >= p_max_open THEN 'reservations'
            ELSE 'available'
        END
        FROM screen_track.workspace_usage(p_workspace, p_start, p_end) usage
    $$;

CREATE FUNCTION screen_track.release_member_recordings() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
    AS $$
    BEGIN 
        UPDATE screen_track.recordings SET status = 'abandoned', closed_at = clock_timestamp()
         WHERE workspace_id = NEW.workspace_id AND account_id = NEW.account_id AND status = 'open';
        DELETE FROM screen_track.recording_leases WHERE workspace_id = NEW.workspace_id AND account_id = NEW.account_id;
        RETURN NULL;
    END
    $$;
CREATE TRIGGER release_offboarded_recordings AFTER UPDATE OF active ON screen_track.memberships
FOR EACH ROW WHEN (OLD.active AND NOT NEW.active) EXECUTE FUNCTION screen_track.release_member_recordings();

ALTER TABLE screen_track.recordings ENABLE ROW LEVEL SECURITY;
CREATE POLICY recording_read ON screen_track.recordings FOR SELECT TO screen_track_app
    USING ((screen_track.role_here(workspace_id) IS NOT NULL AND account_id = screen_track.actor_id())
        OR (status = 'local_finalized' AND (
            screen_track.role_here(workspace_id) = 'owner'
            OR (screen_track.role_here(workspace_id) = 'reviewer' AND EXISTS (
                SELECT 1 FROM screen_track.reviewer_assignments ra
                WHERE ra.workspace_id = recordings.workspace_id AND ra.subject_id = recordings.account_id
                    AND ra.reviewer_id = screen_track.actor_id()
        ))
    )));
CREATE POLICY recording_insert ON screen_track.recordings FOR INSERT TO screen_track_app
    WITH CHECK (screen_track.role_here(workspace_id) IS NOT NULL AND account_id = screen_track.actor_id()
        AND screen_track.active_business(workspace_id));
CREATE POLICY recording_edit ON screen_track.recordings FOR UPDATE TO screen_track_app
    USING (screen_track.role_here(workspace_id) IS NOT NULL AND account_id = screen_track.actor_id())
    WITH CHECK (screen_track.role_here(workspace_id) IS NOT NULL AND account_id = screen_track.actor_id());

ALTER TABLE screen_track.recording_leases ENABLE ROW LEVEL SECURITY;
CREATE POLICY own_leases ON screen_track.recording_leases FOR ALL TO screen_track_app
    USING (account_id = screen_track.actor_id()) WITH CHECK (account_id = screen_track.actor_id());

GRANT SELECT, INSERT ON screen_track.recordings TO screen_track_app;
GRANT UPDATE (capture_id, status, reserved_until, active_ms, closed_at) ON screen_track.recordings TO screen_track_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON screen_track.recording_leases TO screen_track_app;

REVOKE EXECUTE ON FUNCTION screen_track.active_business(uuid), screen_track.release_member_recordings(),
    screen_track.workspace_usage(uuid, timestamptz, timestamptz),
    screen_track.admin_workspace_usage(uuid, timestamptz, timestamptz),
    screen_track.recording_budget(uuid, timestamptz, timestamptz, bigint, bigint, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION screen_track.active_business(uuid),
    screen_track.admin_workspace_usage(uuid, timestamptz, timestamptz),
    screen_track.recording_budget(uuid, timestamptz, timestamptz, bigint, bigint, bigint) TO screen_track_app;