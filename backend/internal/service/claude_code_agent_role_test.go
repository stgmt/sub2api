package service

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

const (
	planArchitectAnchor = "You are a software architect and planning specialist for Claude Code."
	planReadOnlyAnchor  = "=== CRITICAL: READ-ONLY MODE - NO FILE MODIFICATIONS ==="
	planTaskAnchor      = "This is a READ-ONLY planning task."
)

func claudeCodeAgentRoleBody(t *testing.T, system any, tools []string, userText, sessionID string) []byte {
	t.Helper()
	toolObjects := make([]map[string]string, 0, len(tools))
	for _, name := range tools {
		toolObjects = append(toolObjects, map[string]string{"name": name})
	}
	body, err := json.Marshal(map[string]any{
		"model":    "gpt-5.6-luna",
		"system":   system,
		"tools":    toolObjects,
		"messages": []map[string]any{{"role": "user", "content": userText}},
		"metadata": map[string]string{"user_id": sessionID},
	})
	require.NoError(t, err)
	return body
}

func planSystemText() string {
	return "x-anthropic-billing-header: cc_entrypoint=sdk-cli; cc_is_subagent=true;\n" +
		planArchitectAnchor + " Your role is to explore the codebase and design implementation plans.\n" +
		planReadOnlyAnchor + "\n" + planTaskAnchor + " You are STRICTLY PROHIBITED from modifying files."
}

func TestDetectClaudeCodeAgentRole_PlanComposite(t *testing.T) {
	t.Parallel()
	body := claudeCodeAgentRoleBody(t,
		[]map[string]string{
			{"type": "text", "text": planSystemText()},
			{"type": "text", "text": "Headroom appended output-shaping guidance."},
		},
		[]string{"Bash", "Glob", "Grep", "Read", "ReportFindings", "Skill", "ToolSearch"},
		"Inspect the repository and return a plan.",
		"session-plan-1",
	)

	detection := DetectClaudeCodeAgentRole("claude-cli/2.1.219 (external, sdk-cli)", body)

	require.Equal(t, ClaudeCodeAgentRolePlan, detection.Role)
	require.Equal(t, "session-plan-1", detection.SessionID)
}

func TestDetectClaudeCodeAgentRole_RejectsMutatedComposite(t *testing.T) {
	t.Parallel()
	validSystem := planSystemText()
	validTools := []string{"Bash", "Glob", "Grep", "Read", "ReportFindings", "Skill", "ToolSearch"}
	tests := []struct {
		name      string
		userAgent string
		system    string
		tools     []string
		userText  string
		sessionID string
	}{
		{name: "interactive CLI", userAgent: "claude-cli/2.1.219 (external, cli)", system: validSystem, tools: validTools, sessionID: "s1"},
		{name: "not a subagent", userAgent: "claude-cli/2.1.219 (external, sdk-cli)", system: strings.Replace(validSystem, "cc_is_subagent=true", "cc_is_subagent=false", 1), tools: validTools, sessionID: "s2"},
		{name: "missing sdk entrypoint", userAgent: "claude-cli/2.1.219 (external, sdk-cli)", system: strings.Replace(validSystem, "cc_entrypoint=sdk-cli", "cc_entrypoint=cli", 1), tools: validTools, sessionID: "s-entrypoint"},
		{name: "missing architect anchor", userAgent: "claude-cli/2.1.219 (external, sdk-cli)", system: "cc_entrypoint=sdk-cli; cc_is_subagent=true;\n" + planReadOnlyAnchor + "\n" + planTaskAnchor, tools: validTools, sessionID: "s3"},
		{name: "missing read-only anchor", userAgent: "claude-cli/2.1.219 (external, sdk-cli)", system: "cc_entrypoint=sdk-cli; cc_is_subagent=true;\n" + planArchitectAnchor + "\n" + planTaskAnchor, tools: validTools, sessionID: "s4"},
		{name: "missing planning-task anchor", userAgent: "claude-cli/2.1.219 (external, sdk-cli)", system: "cc_entrypoint=sdk-cli; cc_is_subagent=true;\n" + planArchitectAnchor + "\n" + planReadOnlyAnchor, tools: validTools, sessionID: "s5"},
		{name: "edit tool present", userAgent: "claude-cli/2.1.219 (external, sdk-cli)", system: validSystem, tools: append(append([]string{}, validTools...), "Edit"), sessionID: "s6"},
		{name: "write tool present", userAgent: "claude-cli/2.1.219 (external, sdk-cli)", system: validSystem, tools: append(append([]string{}, validTools...), "Write"), sessionID: "s7"},
		{name: "missing read tool", userAgent: "claude-cli/2.1.219 (external, sdk-cli)", system: validSystem, tools: []string{"Bash", "Glob", "Grep"}, sessionID: "s8"},
		{name: "missing bash tool", userAgent: "claude-cli/2.1.219 (external, sdk-cli)", system: validSystem, tools: []string{"Glob", "Grep", "Read"}, sessionID: "s-bash"},
		{name: "missing glob tool", userAgent: "claude-cli/2.1.219 (external, sdk-cli)", system: validSystem, tools: []string{"Bash", "Grep", "Read"}, sessionID: "s-glob"},
		{name: "missing grep tool", userAgent: "claude-cli/2.1.219 (external, sdk-cli)", system: validSystem, tools: []string{"Bash", "Glob", "Read"}, sessionID: "s-grep"},
		{name: "anchors only in user prompt", userAgent: "claude-cli/2.1.219 (external, sdk-cli)", system: "You are the Explore Claude Code subagent.", tools: validTools, userText: validSystem, sessionID: "s9"},
		{name: "missing session id", userAgent: "claude-cli/2.1.219 (external, sdk-cli)", system: validSystem, tools: validTools},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			body := claudeCodeAgentRoleBody(t, tt.system, tt.tools, tt.userText, tt.sessionID)
			detection := DetectClaudeCodeAgentRole(tt.userAgent, body)
			require.Equal(t, ClaudeCodeAgentRoleUnknown, detection.Role)
		})
	}
}

func TestDetectClaudeCodeAgentRole_MalformedBodyFailsClosed(t *testing.T) {
	t.Parallel()
	detection := DetectClaudeCodeAgentRole("claude-cli/2.1.219 (external, sdk-cli)", []byte(`{"system":`))
	require.Equal(t, ClaudeCodeAgentRoleUnknown, detection.Role)
	require.Empty(t, detection.SessionID)
}
