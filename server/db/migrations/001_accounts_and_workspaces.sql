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
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    expires_at timestamptz NOT NULL CHECK (expires_at > created_at)
);
CREATE INDEX login_flows_expiry_idx ON screen_track.login_flows (expires_at);

CREATE TABLE screen_track.rate_limits (
    bucket bytea PRIMARY KEY CHECK (octet_length(bucket) = 32),
    hits integer NOT NULL CHECK (hits > 0),
    expires_at timestamptz NOT NULL
);
CREATE INDEX rate_limits_expiry_idx ON screen_track.rate_limits (expires_at);

CREATE TABLE screen_track.workspaces (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kind text NOT NULL CHECK (kind IN ('personal','business')),
    name text NOT NULL CHECK (length(name) BETWEEN 1 AND 120),
    time_zone text NOT NULL DEFAULT 'UTC' CHECK (length(time_zone) BETWEEN 1 AND 100),
    owner_id uuid NOT NULL REFERENCES screen_track.account(id),
    owner_active boolean GENERATED ALWAYS AS (true) STORED NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    archived_at timestamptz,
    CHECK (kind = 'business' OR archived_at IS NULL)
);
CREATE UNIQUE INDEX one_personal_workspace_idx ON screen_track.workspaces (owner_id) WHERE kind = 'personal';
CREATE INDEX active_business_owner_idx ON screen_track.workspaces (owner_id) WHERE kind = 'business' AND archived_at IS NULL;

CREATE TABLE screen_track.memberships (
    workspace_id uuid NOT NULL REFERENCES screen_track.workspace(id),
    account_id uuid NOT NULL REFERENCES screen_track.accounts(id),
    role text NOT NULL CHECK (role IN ('member','reviewer', 'coordinator')),
    active boolean NOT NULL DEFAULT true,
    joined_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    revoked_at timestamptz,
    PRIMARY KEY (workspace_id, account_id),
    UNIQUE (workspace_id, account_id, active),
    CHECK (active = (revoked_at IS NULL))
);
ALTER TABLE screen_track.workspaces ADD CONSTRAINT workspaces_active_owner_fk
    FOREIGN KEY (id, owner_id, owner_active)
    REFERENCES screen_track.memberships (workspace_id, account_id, active) DEFERRABLE INITIALLY DEFERRED;
CREATE INDEX active_memberships_by_account_idx ON screen_track.memberships (account_id, workspace_id) WHERE active;

CREATE TABLE screen_track.reviewer_assignments (
    workspace_id uuid NOT NULL,
    reviewer_id uuid NOT NULL,
    subject_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (workspace_id, reviewer_id, subject_id),
    FOREIGN KEY (workspace_id, reviewer_id) REFERENCES screen_track.memberships(workspace_id, account_id),
    FOREIGN KEY (workspace_id, subject_id) REFERENCES screen_track.memberships(workspace_id, account_id),
    CHECK (reviewer_id <> subject_id)
);

CREATE TABLE screen_track.invitations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id uuid NOT NULL, 
    inviter_id uuid NOT NULL,
    email text NOT NULL CHECK (length(email) BETWEEN 3 AND 254 AND split_part(email, '@', 2) = lower(split_part(email, '@', 2))),
    role text NOT NULL CHECK (role IN ('member', 'reviewer', 'coordinator')),
    token_hash bytea NOT NULL UNIQUE CHECK (octet_length(token_hash) = 32),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    expires_at timestamptz NOT NULL CHECK (expires_at > created_at),
    accepted_by uuid,
    accepted_at timestamptz,
    revoked_at timestamptz,
    FOREIGN KEY (workspace_id, inviter_id) REFERENCES screen_track.memberships(workspace_id, account_id),
    FOREIGN KEY (workspace_id, accepted_by) REFERENCES screen_track.memberships(workspace_id, account_id),
    CHECK ((accepted_by IS NULL) = (accepted_at IS NULL)),
    CHECK (accepted_at IS NULL OR revoked_at IS NULL)
);
CREATE UNIQUE INDEX one_pending_invitation_idx ON screen_track.invitations (workspace_id, email)
    WHERE accepted_at IS NULL AND revoked_at IS NULL;
CREATE INDEX invitations_page_idx ON screen_track.invitations (workspace_id, id);

CREATE TABLE screen_track.ownership_transfers (
    workspace_id uuid PRIMARY KEY REFERENCES screen_track.workspaces(id),
    id uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    from_account_id uuid NOT NULL,
    to_account_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    expires_at timestamptz NOT NULL CHECK (expires_at > created_at),
    FOREIGN KEY (workspace_id, from_account_id) REFERENCES screen_track.memberships(workspace_id, account_id),
    FOREIGN KEY (workspace_id, to_account_id) REFERENCES screen_track.memberships(workspace_id, account_id),
    CHECK (from_account_id <> to_account_id)
);

CREATE TABLE screen_track.audit_events (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    workspace_id uuid NOT NULL REFERENCES screen_track.workspaces(id),
    actor_id uuid NOT NULL,
    action text NOT NULL CHECK (length(action) BETWEEN 1 AND 80),
    target_id uuid, 
    subject_id uuid,
    happened_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    FOREIGN KEY (workspace_id, actor_id) REFERENCES screen_track.memberships(workspace_id, account_id)
);
CREATE INDEX audit_events_page_idx ON screen_track.audit_events (workspace_id, id DESC);

CREATE TABLE screen_track.business_creations (
    account_id uuid NOT NULL REFERENCES screen_track.accounts(id),
    request_id uuid NOT NULL,
    workspace_id uuid NOT NULL UNIQUE REFERENCES screen_track.workspaces(id),
    name text NOT NULL,
    time_zone text NOT NULL,
    PRIMARY KEY (account_id, request_id)
);

CREATE FUNCTION screen_track.actor_id() RETURNS uuid
    LANGUAGE sql STABLE SET search_path = pg_catalog
    AS $$ SELECT nullif(current_setting('screen_track.actor', true), '')::uuid $$;

CREATE FUNCTION screen_track.tenant_id() RETURNS uuid
    LANGUAGE sql STABLE SET search_path = pg_catalog
    AS $$ SELECT nullif(current_setting('screen_track.workspace', true), '')::uuid $$;

CREATE FUNCTION screen_track.role_for(p_workspace uuid, p_actor uuid) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog
    AS $$ 
        SELECT CASE WHEN w.owner_id = m.account_id THEN 'owner' ELSE m.role END
        FROM screen_track.workspaces w
        JOIN screen_track.memberships m ON m.workspace_id = w.id
        JOIN screen_track.accounts a ON a.id = m.account_id
        WHERE w.id = p_workspace AND m.account_id = p_actor AND m.active
            AND w.archived_at IS NULL AND a.disabled_at IS NULL
    $$;

CREATE FUNCTION screen_track.role_of_actor(p_workspace uuid) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog
    AS $$ SELECT screen_track.role_for(p_workspace, screen_track.actor_id()) $$;

CREATE FUNCTION screen_track.role_here(p_workspace uuid) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog
    AS $$
        SELECT screen_track.role_for(p_workspace, screen_track.actor_id())
        WHERE p_workspace = screen_track.tenant_id()
    $$;

CREATE FUNCTION screen_track.lock_workspace(p_workspace uuid) RETURNS void
    LANGUAGE sql VOLATILE SET search_path = pg_catalog
    AS $$ SELECT pg_advisory_xact_lock(hashtextextended('screen-track:workspace:' || p_workspace::text, 0 )) $$;

CREATE FUNCTION screen_track.lock_account(p_account uuid) RETURNS void
    LANGUAGE sql VOLATILE SET search_path = pg_catalog 
    AS $$ SELECT pg_advisory_xact_lock(hashtextextended('screen-track:account:' || p_account::text, 0)) $$;

CREATE FUNCTION screen_track.provision_account(p_issuer text, p_subject text, p_email text, p_name text, p_limit integer)
    RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
    AS $$ 
    DECLARE a screen_track.accounts%ROWTYPE;
    DECLARE workspace uuid;
    BEGIN 
        SELECT * INTO a FROM screen_track.accounts WHERE issuer = p_issuer AND subject = p_subject;
        IF NOT FOUND THEN
            PERFORM pg_advisory_xact_lock(hashtextextended('screen-track:admission', 0));
            SELECT * INTO a FROM screen_track.accounts WHERE issuer = p_issuer AND subject = p_subject;
            IF NOT FOUND THEN
                IF EXISTS (SELECT 1 FROM screen_track.accounts WHERE email = p_email) THEN
                    RAISE EXCEPTION USING ERRCODE = 'ST001', MESSAGE = 'account admission limit';
                END IF;
                IF (SELECT count(*) FROM screen_track.accounts) >= least(1000, greatest(0, p_limit)) THEN
                    RAISE EXCEPTION USING ERRCODE = 'ST002', MESSAGE = 'account admission limit';
                END IF;
                INSERT INTO screen_track.accounts (issuer, subject, email, display_name)
                    VALUES (p_issuer, p_subject, p_email, p_name) RETURNING * INTO a;
                INSERT INTO screen_track.workspaces (kind, name, owner_id)
                    VALUES ('personal', 'Personal', a.id) RETURNING id INTO workspace;
                INSERT INTO screen_track.memberships (workspace_id, account_id, role)
                    VALUES (workspace, a.id, 'member');
            END IF;
        END IF;
        If a.disabled_at IS NOT NULL THEN
            RAISE EXCEPTION USING ERRCODE = 'ST003', MESSAGE = 'verified identity unavailable';
        END IF;
        IF a.email <> p_email OR a.display_name <> p_name THEN
            UPDATE screen_track.accounts SET email = p_email, display_name = p_name WHERE id = a.id;
        END IF;
        RETURN a.id;
    EXCEPTION WHEN unique_violation THEN
        RAISE EXCEPTION USING ERRCODE = 'ST001', MESSAGE = 'verified identity conflict';
    END
    $$;

CREATE FUNCTION screen_track.issue_session(p_account uuid, p_token bytea, p_prior bytea, p_ttl integer, p_elevated integer)
    RETURNS timestamptz LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
    AS $$
    DECLARE started timestamptz := clock_timestamp();
    DECLARE ends timestamptz := started + p_ttl * interval '1 second';
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM screen_track.accounts WHERE id = p_account AND disabled_at IS NULL) THEN
            RAISE EXCEPTION USING ERRCODE = 'ST003', MESSAGE = 'account unavailable';
        END IF;
        IF p_elevated > 0 THEN
            DELETE FROM screen_track.sessions WHERE token_hash = p_prior AND account_id = p_account AND expires_at > started;
            IF NOT FOUND THEN
                RAISE EXCEPTION USING ERRCODE = 'ST003', MESSAGE = 'session invalid for step-up';
            END IF;
        ELSIF p_prior IS NOT NULL THEN
            DELETE FROM screen_track.sessions WHERE token_hash = p_prior;
        END IF;
        INSERT INTO screen_track.sessions (token_hash, account_id, created_at, expires_at, elevated_until)
        VALUES (p_token, p_account, started, ends,
            CASE WHEN p_elevated > 0 THEN least(ends, started + p_elevated * interval '1 second') END);
        RETURN ends;
    END
    $$;

CREATE FUNCTION screen_track.session_actor(p_token bytea)
    RETURNS TABLE (id uuid, email text, display_name text, elevated boolean)
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog
    AS $$ 
        SELECT a.id, a.email, a.display_name, coalesce (s.elevated_until > statement_timestamp(), false)
        FROM screen_track.sessions s JOIN screen_track.accounts a ON a.id = s.account_id 
        WHERE s.token_hash = p_token AND s.expires_at > statement_timestamp() AND a.disabled_at IS NULL
    $$;

CREATE FUNCTION screen_track.bind_session(p_token bytea)
    RETURNS TABLE (id uuid, email text, display_name text, elevated boolean)
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
    AS $$
    DECLARE actor uuid;
    DECLARE actor_email text;
    DECLARE actor_name text;
    DECLARE step_up boolean;
    BEGIN
        SELECT a.id, a.email, a.display_name, coalesce(s.elevated_until > clock_timestamp(), false)
        INTO actor, actor_email, actor_name, step_up
        FROM screen_track.sessions s JOIN screen_track.accounts a ON a.id = s.account_id
        WHERE s.token_hash = p_token AND s.expires_at > clock_timestamp() AND a.disabled_at IS NULL
        FOR SHARE OF s, a;
        PERFORM set_config('screen_track.actor', coalesce(actor::text, ''), true);
        PERFORM set_config('screen_track.workspace', '', true);
        IF actor IS NOT NULL THEN
            RETURN QUERY SELECT actor, actor_email, actor_name, step_up;
        END IF;
    END
    $$;

CREATE FUNCTION screen_track.revoke_session(p_token bytea) RETURNS void
    LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog
    AS $$ DELETE FROM screen_track.sessions WHERE token_hash = p_token $$;

CREATE FUNCTION screen_track.purge_auth_state(p_batch integer) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
    AS $$ 
    BEGIN
        DELETE FROM screen_track.sessions WHERE token_hash IN (
            SELECT state_hash FROM screen_track.sessions WHERE expires_at <= clock_timestamp()
            ORDER BY expires_at LIMIT p_batch FOR UPDATE SKIP LOCKED
        );
        DELETE FROM screen_track.login_flows WHERE state_hash IN (
            SELECT state_hash FROM screen_track.login_flows WHERE expires_at <= clock_timestamp()
            ORDER BY expires_at LIMIT p_batch FOR UPDATE SKIP LOCKED
        );
        DELETE FROM screen_track.rate_limits WHERE bucket IN (
            SELECT bucket FROM screen_track.rate_limits WHERE expires_at <= clock_timestamp()
            ORDER BY expires_at LIMIT p_batch FOR UPDATE SKIP LOCKED
        );
    END
    $$;

CREATE FUNCTION screen_track.create_business(p_request uuid, p_name text, p_zone text, p_limit integer) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
    AS $$
    DECLARE actor uuid := screen_track.actor_id();
    DECLARE workspace uuid;
    DECLARE creation screen_track.business_creations%ROWTYPE;
    BEGIN
        IF actor IS NULL THEN RAISE EXCEPTION USING ERRCODE = 'ST004', MESSAGE = 'account required'; END IF;
        PERFORM screen_track.lock_account(actor);
        SELECT * INTO creation FROM screen_track.business_creations
            WHERE account_id = actor AND request_id = p_request;
        IF FOUND THEN
            IF creation.name <> p_name OR creation.time_zone <> p_zone THEN
                RAISE EXCEPTION USING ERRCODE = 'ST008', MESSAGE = 'idempotency key reused';
            END IF;
            RETURN creation.workspace_id;
        END IF;
        IF (SELECT count(*) FROM screen_track.workspaces
            WHERE owner_id = actor AND kind = 'business' AND archived_at IS NULL) >= p_limit THEN
            RAISE EXCEPTION USING ERRCODE = 'ST002', MESSAGE = 'business workspace limit';
        END IF;
        INSERT INTO screen_track.workspaces (kind, name, time_zone, owner_id)
            VALUES ('business', p_name, p_zone, actor) RETURNING id INTO workspace;
        INSERT INTO screen_track.memberships (workspace_id, account_id, role) VALUES (workspace, actor, 'member');
        INSERT INTO screen_track.business_creations (account_id, request_id, workspace_id, name, time_zone) 
            VALUES (actor, p_request, workspace, p_name, p_zone);
        INSERT INTO screen_track.audit_events (workspace_id, actor_id, action, target_id)
            VALUES (workspace, actor, 'workspace.created', workspace);
        RETURN workspace;
    END
    $$;

CREATE FUNCTION screen_track.member_page(p_workspace uuid, p_after uuid, p_limit integer)
    RETURNS TABLE (account_id uuid, email text, display_name text, role text, active boolean, joined_at timestamptz)
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog
    AS $$ 
        SELECT m.account_id, a.email, a.display_name,
            CASE WHEN m.account_id = w.owner_id THEN 'owner' ELSE m.role END, m.active, m.joined_at
        FROM screen_track.memberships m JOIN screen_track.accounts a ON a.id = m.account_id
        JOIN screen_track.workspaces w ON w.id = m.workspace_id
        WHERE m.workspace_id = p workspace AND screen_track.role_here(p_workspace) IN ('owner', 'coordinator')
            AND w.kind = 'business' AND (p_after IS NULL OR m.account_id > p_after)
        ORDER BY m.account_id LIMIT greatest(0, least(p_limit, 101))
    $$;

CREATE FUNCTION screen_track.put_invitation(p_workspace uuid, p_email text, p_role text, p_hash bytea)
    RETURNS TABLE (id uuid, email text, role text, created_at timestamptz, expires_at timestamptz,
        accepted_at timestamptz, revoked_at timestamptz)
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
    AS $$ 
    DECLARE actor uuid := screen_track.actor_id();
    DECLARE invite screen_track.invitations%ROWTYPE;
    BEGIN
        PERFORM screen_track.lock_workspace(p_workspace);
        IF screen_track.role_here(p_workspace) IS DISTINCT FROM 'owner'
            OR NOT EXISTS (SELECT 1 FROM screen_track.workspaces WHERE workspace_id = p_workspace AND kind ='business') THEN
            RAISE EXCEPTION USING ERRCODE = 'ST006', MESSAGE = 'owner required';
        END IF;
        SELECT * INTO invite FROM screen_track.invitations i WHERE i.token_hash = p_hash;
        IF FOUND THEN 
            IF invite.workspace_id <> p_workspace AND i.email = p_email
                OR invite.email <> p_email OR invite.role <> p_role THEN
                RAISE EXCEPTION USING ERRCODE = 'ST008', MESSAGE = 'invitation token reused';
            END IF;
        ELSE
            UPDATE screen_track.invitations i SET revoked_at = clock_timestamp()
                WHERE i.workspace_id = p_workspace AND i.email = p_email
                    AND i.accepted_at IS NULL AND i.revoked_at IS NULL;
            INSERT INTO screen_track.invitations (workspace_id, inviter_id, email, role, token_hash, expires_at)
            VALUES (p_workspace, actor, p_email, p_role, p_hash, clock_timestamp() + interval '7 days')
            RETURNING * INTO invite;
            INSERT INTO screen_track.audit_events (workspace_id, actor_id, action, target_id)
                VALUES (p_workspace, actor, 'invitation.created', invite.id);
        END IF;
        RETURN QUERY SELECT invite.id, invite.email, invite.role, invite.created_at,
            invite.expires_at, invite.accepted_at, invite.revoked_at;
    END
    $$;

CREATE FUNCTION screen_track.accept_invitation(p_hash bytea, p_limit integer) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
    AS $$ 
    DECLARE actor uuid := screen_track.actor_id();
    DECLARE actor_email text;
    DECLARE invite screen_track.invitations%ROWTYPE;
    DECLARE workspace uuid;
    BEGIN 
        SELECT email INTO actor_email FROM screen_track.accounts WHERE id = actor AND disabled_at IS NULL;
        SELECT workspace_id INTO workspace FROM screen_track.invitations WHERE token_hash = p_hash AND email = actor_email;
        IF NOT FOUND THEN 
            RAISE EXCEPTION USING ERRCODE = 'ST007', MESSAGE = 'invitation unavailable';
        END IF;
        PERFORM screen_track.lock_workspace(workspace);
        SELECT * INTO invite FROM screen_track.invitations
            WHERE token_hash = p_hash AND workspace_id = workspace AND email = actor_email;
        IF NOT FOUND OR invite.revoked_at IS NOT NULL OR invite.expires_at <= clock_timestamp()
            OR screen_track.role_for(workspace, invite.inviter_id) IS DISTINCT FROM 'owner' THEN
            RAISE EXCEPTION USING ERRCODE = 'ST007', MESSAGE = 'invitation unavailable';
        END IF;
        IF invite.accepted_at IS NOT NULL THEN
            IF invite.accepted_by = actor AND screen_track.role_for(workspace, actor) IS NOT NULL THEN RETURN workspace; END IF;
            RAISE EXCEPTION USING ERRCODE = 'ST007', MESSAGE = 'invitation unavailable';
        END IF;
        IF screen_track.role_for(workspace, actor) IS NULL THEN
            IF (SELECT count(*) FROM screen_track.memberships WHERE workspace_id = workspace AND active) >= p_limit THEN
                RAISE EXCEPTION USING ERRCODE = 'ST002', MESSAGE = 'workspace member limit';
            END IF;
            INSERT INTO screen_track.memberships (workspace_id, account_id, role)
                VALUES (workspace, actor, invite.role)
                ON CONFLICT (workspace_id, account_id) DO UPDATE
                    SET active = true, revoked_at = NULL, role = EXCLUDED.role, joined_at = clock_timestamp()
                WHERE NOT screen_track.memberships.active;
        END IF;
        UPDATE screen_track.invitations SET accepted_by = actor, accepted_at = clock_timestamp() WHERE id = invite.id;
        INSERT INTO screen_track.audit_events (workspace_id, actor_id, action, target_id)
            VALUES (workspace, actor, 'invitation.accepeted', invite.id);
        RETURN workspace;
    END
    $$;

CREATE FUNCTION screen_track.offboard(p_workspace uuid, p_account uuid) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
    AS $$
    DECLARE actor uuid := screen_track.actor_id();
    DECLARE actor_role text;
    DECLARE target_role text;
    BEGIN 
        PERFORM screen_track.lock_workspace(p_workspace);
        actor_role := screen_track.role_here(p_workspace);
        target_role := screen_track.role_for(p_workspace, p_account);
        IF actor_role IS NULL OR p_workspace IS DISTINCT FROM screen_track.tenant_id()
            OR NOT EXISTS (SELECT 1 FROM screen_track.workspaces WHERE id = p_workspace AND kind = 'business')
                RAISE EXCEPTION USING ERR = 'ST007', MESSAGE = 'workspace unavailalbe';
        END IF;
        IF target_role = 'owner' THEN RAISE EXCEPTION USING ERRCODE = 'ST005', MESSAGE = 'transfer ownership first'; END IF;
        IF actor <> p_account AND actor_role <> 'owner'
            AND (actor_role <> 'coordinator' OR target_role IS DISTINCT FROM 'member') THEN 
                RAISE EXCEPTION USING ERRCODE = 'ST006', MESSAGE = 'membership operation forbidden';
            END IF;
        UPDATE screen_track.memberships SET active = false, revoked_at = clock_timestamp()
            WHERE workspace_id = p_workspace AND account_id = p_account AND active;
        IF NOT FOUND THEN RETURN false; END IF;
        DELETE FROM screen_track.reviewer_assignments WHERE workspace_id = p_workspace AND
            (reviewer_id = p_account OR subject_id = p_account);
        DELETE FROM screen_track.ownership_transfers WHERE workspace_id = p_workspace AND to_account_id = p_account;
        UPDATE screen_track.invitations SET revoked_at = clock_timestamp()
            WHERE workspace_id = p_workspace AND email = (SELECT email FROM screen_track.accounts WHERE id = p_account)
                AND accepted_at IS NULL AND revoked_at IS NULL;
        INSERT INTO screen_track.audit_events (workspace_id, actor_id, action, target_id)
            VALUES (p_workspace, actor, 'membership.revoked', p_account);
        RETURN true;
    END 
    $$;

CREATE FUNCTION screen_track.accept_transfer(p_workspace uuid, p_transfer uuid, p_limit integer) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
    AS $$
    DECLARE actor uuid := screen_track.actor_id();
    DECLARE transfer screen_track.ownership_transfers%ROWTYPE;
    BEGIN
        PERFORM screen_track.lock_workspace(p_workspace);
        SELECT * INTO transfer FROM screen_track.ownership_transfers
            WHERE workspace_id = p_workspace AND id = p_transfer AND to_account_id = actor AND expires_at > clock_timestamp();
        IF NOT FOUND OR screen_track.role_here(p_workspace) IS NULL
            OR screen_track.role_for(p_workspace, transfer.from_account_id) IS DISTINCT FROM 'owner' THEN
                RAISE EXCEPTION USING ERRCODE = 'ST007', MESSAGE = 'transfer unavailable';
        END IF;
        PERFORM screen_track.lock_account(actor);
        IF (SELECT count(*) FROM screen_track.workspaces
            WHERE owner_id = actor AND kind = 'business' AND archived_at IS NULL) >= p_limit THEN
            RAISE EXCEPTION USING ERRCODE = 'ST002', MESSAGE = 'business workspace limit';
        END IF;
        UPDATE screen_track.memberships SET role = 'member'
            WHERE workspace_id = p_workspace AND account_id IN (transfer.from_account_id, actor);
        DELETE FROM screen_track.reviewer_assignments WHERE workspace_id = p_workspace AND reviewer_id = actor;
        UPDATE screen_track.workspaces SET owner_id = actor WHERE id = p_workspace;
        DELETE FROM screen_track.ownership_transfers WHERE workspace_id = p_workspace;
        UPDATE screen_track.invitations SET revoked_at = clock_timestamp()
         WHERE workspace_id = p_workspace AND accepted_at IS NULL AND revoked_at IS NULL;
        INSERT INTO screen_track.audit_events (workspace_id, actor_id, action, target_id)
            VALUES (p_workspace, actor, 'ownership.transferred', transfer.from_account_id);
    END
    $$;

CREATE FUNCTION screen_track.archive_business(p_workspace uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
    AS $$
    BEGIN
        PERFORM screen_track.lock_workspace(p_workspace);
        IF screen_track.role_here(p_workspace) IS DISTINCT FROM 'owner' THEN
            RAISE EXCEPTION USING ERRCODE = 'ST006', MESSAGE = 'owner required';
        END IF;
        UPDATE screen_track.workspaces SET archived_at = clock_timestamp()
         WHERE id = p_workspace AND kind = 'business' AND archived_at IS NULL;
        IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE = 'ST007', MESSAGE = 'business unavailable'; END IF;
        DELETE FROM screen_track.ownership_transfers WHERE workspace_id = p_workspace;
        UPDATE screen_track.invitations SET revoked_at = clock_timestamp()
         WHERE workspace_id = p_workspace AND accepted_at IS NULL AND revoked_at IS NULL;
        INSERT INTO screen_track.audit_events (workspace_id, actor_id, action, target_id)
            VALUES (p_workspace, screen_track.actor_id(), 'workspace.archived', p_workspace);
    END
    $$;

ALTER TABLE screen_track.workspaces ENABLE ROW LEVEL SECURITY;
CREATE POLICY workspace_read ON screen_track.workspaces FOR SELECT TO screen_track_app
    USING ((screen_track.tenant_id() IS NULL OR id = screen_track.tenant_id())
        AND screen_track.role_of_actor(id) IS NOT NULL);
CREATE POLICY workspace_edit ON screen_track.workspaces FOR UPDATE TO screen_track_app
    USING (screen_track.role_here(id) = 'owner');
    WITH CHECK (screen_track.role_here(id) = 'owner');

ALTER TABLE screen_track.memberships ENABLE ROW LEVEL SECURITY;
CREATE POLICY membership_read ON screen_track.memberships FOR SELECT TO screen_track_app
    USING (screen_track.role_here(workspace_id) IN ('owner', 'coordinator') OR
    (account_id = screen_track.actor_id() AND screen_track.role_here(workspace_id) IS NOT NULL));
CREATE POLICY  membership_read ON screen_track.memberships FOR UPDATE TO screen_track_app
    USING (screen_track.role_here(workspace_id) = 'owner' AND account_id <> screen_track.actor_id())
    WITH CHECK (screen_track.role_here(workspace_id) = 'owner' AND account_id <> screen_track.actor_id());

ALTER TABLE screen_track.reviewer_assignments ENABLE ROW LEVEL SECURITY;
CREATE POLICY assignment_read ON screen_track.reviewer_assignments FOR SELECT TO screen_track_app
    USING (screen_track.role_here(workspace_id) = 'owner' OR
        (reviewer_id = screen_track.actor_id() AND screen_track.role_here(workspace_id) = 'reviewer'));
CREATE POLICY assginment_insert ON screen_track.reviewer_assignments FOR INSERT TO screen_track_app
    WITH CHECK (screen_track.role_here(workspace_id) = 'owner');
CREATE POLICY assignment_delete ON screen_track.reviewer_assignments FOR DELETE TO screen_track_app
    USING (screen_track.role_here(workspace_id) = 'owner');

ALTER TABLE screen_track.invitations ENABLE ROW LEVEL SECURITY;
CREATE POLCY invite_read ON screen_track.invitations FOR SELECT TO screen_track_app
    USING (screen_track.role_here(workspace_id) = 'owner');
CREATE POLICY invite_edit ON screen_track.invitations FOR UPDATE TO screen_track_app
    USING (screen_track.role_here(workspace_id) = 'owner')
    WITH CHECK (screen_track.role_here(workspace_id) = 'owner' AND inviter_id = screen_track.actor_id());

ALTER TABLE screen_track.ownership_transfers ENABLE ROW LEVEL SECURITY;
CREATE POLICY transfer_read ON screen_track.ownership_transfers FOR SELECT TO screen_track_app
    USING (screen_track.role_here(workspace_id) = 'owner' OR
        (to_account_id = screen_track.actor_id() AND screen_track.role_here(workspace_id) IS NOT NULL));
CREATE POLICY transfer_insert ON screen_track.ownership_transfers FOR INSERT TO screen_track_app
    WITH CHECK (screen_track.role_here(workspace_id) = 'owner' AND from_account_id = screen_track.actor_id());
CREATE POLICY transfer_edit ON screen_track.ownership_transfers FOR UPDATE TO screen_track_app
    USING (screen_track.role_here(workspace_id) = 'owner')
    WITH CHECK (screen_track.role_here(workspace_id) = 'owner' AND from_account_id = screen_track.actor_id());
CREATE POLICY transfer_delete ON screen_track.ownership_transfers FOR DELETE TO screen_track_app
    USING (screen_track.role_here(workspace_id) = 'owner');

ALTER TABLE screen_track.audit_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY audit_read ON screen_track.audit_events FOR SELECT TO screen_track_app
    USING (screen_track.role_here(workspace_id) = 'owner');
CREATE POLICY audit_insert ON screen_track.audit_events FOR INSERT TO screen_track_app
    WITH CHECK (screen_track.role_here(workspace_id) IS NOT NULL AND actor_id = screen_track.actor_id());

GRANT SELECT, INSERT, DELETE ON screen_track.login_flows TO screen_track_app;
GRANT SELECT, INSERT, UPDATE ON screen_track.rate_limits TO screen_track_app
GRANT SELECT (id, kind, name, time_zone, owner_id, created_at, archived_at) ON screen_track.workspaces TO screen_track_app;
GRANT UPDATE (name, time_zone) ON screen_track.workspaces TO screen_track_app;
GRANT SELECT ON screen_track.memberships TO screen_track_app;
GRANT UPDATE (role) ON screen_track.memberships TO screen_track_app;
GRANT SELECT, INSERT, DELETE ON screen_track.reviewer_assignments TO screen_track_app;
GRANT SELECT (id, workspace_id, inviter_id, email, role, created_at, expires_at, accepted_at, revoked_at)
    ON screen_track.invitations TO screen_track_app;
GRANT UPDATE (revoked_at) ON screen_track.invitations TO screen_track_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON screen_track.ownership_transfers TO screen_track_app;
GRANT SELECT, INSERT ON screen_track.audit_events TO screen_track_app;

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA screen_track FROM PUBLIC;
GRANT EXECUTE ON FUNCTION screen_track.actor_id(), screen_track.tenant_id(),
    screen_track.role_of_actor(uuid), screen_track.role_here(uuid), screen_track.lock_workspace(uuid),
    screen_track.lock_account(uuid), screen_track.provision_account(text, text, text, text, integer),
    screen_track.issue_session(uuid, bytea, bytea, integer, integer), screen_track.session_actor(bytea),
    screen_track.bind_session(bytea), screen_track.revoke_session(bytea), screen_track.purge_auth_state(integer),
    screen_track.create_business(uuid, text, text, integer), screen_track.member_page(uuid, uuid, integer),
    screen_track.put_invitation(uuid, text, text, bytea),
    screen_track.accept_invitation(bytea, integer), screen_track.offboard(uuid, uuid),
    screen_track.accept_transfer(uuid, uuid, integer), screen_track.archive_business(uuid)
TO screen_track_app;