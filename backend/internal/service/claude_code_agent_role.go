package service

import (
	"strings"

	"github.com/tidwall/gjson"
)

type ClaudeCodeAgentRole string

const (
	ClaudeCodeAgentRoleUnknown ClaudeCodeAgentRole = ""
	ClaudeCodeAgentRolePlan    ClaudeCodeAgentRole = "plan"
)

type ClaudeCodeAgentRoleDetection struct {
	Role      ClaudeCodeAgentRole
	SessionID string
}

const (
	claudeCodePlanArchitectAnchor = "You are a software architect and planning specialist for Claude Code."
	claudeCodePlanReadOnlyAnchor  = "=== CRITICAL: READ-ONLY MODE - NO FILE MODIFICATIONS ==="
	claudeCodePlanTaskAnchor      = "This is a READ-ONLY planning task."
)

// DetectClaudeCodeAgentRole classifies only trusted request structure. User
// messages are deliberately excluded so prompt text cannot buy a premium route.
func DetectClaudeCodeAgentRole(userAgent string, body []byte) ClaudeCodeAgentRoleDetection {
	if !isClaudeCodeSDKCLIUserAgent(userAgent) || !gjson.ValidBytes(body) {
		return ClaudeCodeAgentRoleDetection{}
	}

	sessionID := strings.TrimSpace(gjson.GetBytes(body, "metadata.user_id").String())
	detection := ClaudeCodeAgentRoleDetection{SessionID: sessionID}
	if sessionID == "" {
		return detection
	}

	systemText := claudeCodeSystemText(body)
	if !strings.Contains(systemText, "cc_entrypoint=sdk-cli") ||
		!strings.Contains(systemText, "cc_is_subagent=true") ||
		!strings.Contains(systemText, claudeCodePlanArchitectAnchor) ||
		!strings.Contains(systemText, claudeCodePlanReadOnlyAnchor) ||
		!strings.Contains(systemText, claudeCodePlanTaskAnchor) {
		return detection
	}

	tools := claudeCodeToolNames(body)
	for _, required := range []string{"Bash", "Glob", "Grep", "Read"} {
		if !tools[required] {
			return detection
		}
	}
	if tools["Edit"] || tools["Write"] {
		return detection
	}

	detection.Role = ClaudeCodeAgentRolePlan
	return detection
}

// IsClaudeCodeSubagentRequest recognizes Claude Code child requests from
// trusted request structure. The sdk-cli User-Agent is shared by standalone
// `claude -p`, so it is necessary but never sufficient on its own.
func IsClaudeCodeSubagentRequest(userAgent string, body []byte) bool {
	if !isClaudeCodeSDKCLIUserAgent(userAgent) || !gjson.ValidBytes(body) {
		return false
	}
	if strings.TrimSpace(gjson.GetBytes(body, "metadata.user_id").String()) == "" {
		return false
	}
	systemText := claudeCodeSystemText(body)
	return strings.Contains(systemText, "cc_entrypoint=sdk-cli") &&
		strings.Contains(systemText, "cc_is_subagent=true")
}

func isClaudeCodeSDKCLIUserAgent(userAgent string) bool {
	userAgent = strings.ToLower(strings.TrimSpace(userAgent))
	return strings.HasPrefix(userAgent, "claude-cli/") && strings.Contains(userAgent, "external, sdk-cli")
}

func claudeCodeSystemText(body []byte) string {
	system := gjson.GetBytes(body, "system")
	if system.Type == gjson.String {
		return system.String()
	}
	if !system.IsArray() {
		return ""
	}
	var text strings.Builder
	system.ForEach(func(_, block gjson.Result) bool {
		blockText := block.Get("text").String()
		if blockText == "" {
			return true
		}
		if text.Len() > 0 {
			text.WriteByte('\n')
		}
		text.WriteString(blockText)
		return true
	})
	return text.String()
}

func claudeCodeToolNames(body []byte) map[string]bool {
	tools := make(map[string]bool)
	gjson.GetBytes(body, "tools").ForEach(func(_, tool gjson.Result) bool {
		if name := strings.TrimSpace(tool.Get("name").String()); name != "" {
			tools[name] = true
		}
		return true
	})
	return tools
}
