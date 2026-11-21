package httpapi

import (
	"context"
	"net/http"
	"time"
)

func (s *Server) routes() {
	s.handle("GET /health", func(_ *http.Request) (response, error) {
		return jsonResponse(http.StatusOK, map[string]string{"status": "ok"}), nil
	})
	s.handle("GET /ready", s.ready)

	read := limit{}
	write := limit{"workspace_write", 90, time.Minute}
	workspaceCreate := limit{"workspace_create", 10, time.Hour}
	invites := limit{"workspace_invitation", 30, time.Hour}
	acceptInvite := limit{"accept_invitation", 30, time.Hour}
	recordingChanges := limit{"recording_write", 60, time.Minute}

	s.handle("GET /api/v1/auth/login", s.login)
	s.handle("POST /api/v1/auth/step-up", s.stepUp)
	s.handle("GET /api/v1/auth/callback", s.callback)
	s.handle("POST /api/v1/auth/logout", s.logout)
	s.handle("GET /api/v1/me", s.authed(read, me))

	s.handle("GET /api/v1/workspaces", s.authed(read, listWorkspaces))
	s.handle("POST /api/v1/workspaces", s.authed(workspaceCreate, s.createWorkspace))
	const workspace = "/api/v1/workspaces/{workspace}"
	s.handle("GET "+workspace, s.tenant(false, read, getWorkspace))
	s.handle("PUT "+workspace, s.tenant(true, write, updateWorkspace))
	s.handle("POST "+workspace+"/archive", s.tenant(true, write, archiveWorkspace))
	s.handle("POST "+workspace+"/leave", s.tenant(true, write, leaveWorkspace))
	s.handle("GET "+workspace+"/members", s.tenant(false, read, listMembers))
	s.handle("PUT "+workspace+"/members/{account}/role", s.tenant(true, write, setMemberRole))
	s.handle("DELETE "+workspace+"/members/{account}", s.tenant(true, write, removeMember))
	s.handle("GET "+workspace+"/invitations", s.tenant(false, read, listInvitations))
	s.handle("POST "+workspace+"/invitations", s.tenant(true, invites, createInvitation))
	s.handle("DELETE "+workspace+"/invitations/{invitation}", s.tenant(true, invites, cancelInvitation))
	s.handle("POST /api/v1/invitations/accept", s.authed(acceptInvite, s.acceptInvitation))
	s.handle("GET "+workspace+"/reviewer-assignments", s.tenant(false, read, listAssignments))
	s.handle("PUT "+workspace+"/reviewer-assignments/{reviewer}/{member}", s.tenant(true, write, setAssignmment(true)))
	s.handle("DELETE "+workspace+"/reviewer-assignments/{reviewer}/{member}", s.tenant(true, write, setAssignment(false)))
	s.handle("GET "+workspace+"/ownership-transfer", s.tenant(false, read, getTransfer))
	s.handle("POST "+workspace+"/ownership-transfer", s.tenant(true, write, requestTransfer))
	s.handle("DELETE "+workspace+"/ownership-transfer/{transfer}", s.tenant(true, write, cancelTransfer))
	s.handle("POST "+workspace+"/ownership-transfer/{transfer}/accept", s.tenant(true, write, s.acceptTransfer))
	s.handle("GET "+workspace+"/audit", s.tenant(false, read, listAudit))

	s.handle("GET "+workspace+"/recordings", s.tenant(false, read, listRecordings))
	s.handle("GET "+workspace+"/recordings/{recording}", s.tenant(false, read, getRecording))
	s.handle("PUT "+workspace+"/recordings/{recording}/capture", s.tenant(true, recordingChanges, s.acquireCapture))
	s.handle("POST "+workspace+"/recordings/{recording}/capture/renew", s.tenant(true, recordingChanges, s.renewCapture))
	s.handle("PUT "+workspace+"/recordings/{recording}/finish", s.tenant(true, recordingChanges, finishRecording))
	s.handle("GET "+workspace+"/calendar", s.tenant(false, read, recordingCalendar))
	s.handle("GET "+workspace+"/usage", s.tenant(false, read, s.workspaceUsage))
}

func (s *Server) ready(r *http.Request) (response, error) {
	ctx, cancel := context.WithTimeout(r.Context(), 1500*time.Millisecond)
	defer cancel()

	if err := s.db.Ready(ctx); err != nil {
		return jsonResponse(http.StatusServiceUnavailable, map[string]string{"status": "unavailable"}), nil
	}
	return jsonResponse(http.StatusOK, map[string]string{"status": "ready"}), nil
}
