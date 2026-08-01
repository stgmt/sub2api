package handler

import (
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
)

func planProfileBody(t *testing.T, system, userText, sessionID string, tools []string) []byte {
	t.Helper()
	toolObjects := make([]map[string]string, 0, len(tools))
	for _, name := range tools {
		toolObjects = append(toolObjects, map[string]string{"name": name})
	}
	body, err := json.Marshal(map[string]any{
		"model":    "gpt-5.6-luna",
		"system":   []map[string]string{{"type": "text", "text": system}},
		"tools":    toolObjects,
		"messages": []map[string]string{{"role": "user", "content": userText}},
		"metadata": map[string]string{"user_id": sessionID},
	})
	require.NoError(t, err)
	return body
}

func planProfileSystem() string {
	return "x-anthropic-billing-header: cc_entrypoint=sdk-cli; cc_is_subagent=true;\n" +
		"You are a software architect and planning specialist for Claude Code.\n" +
		"=== CRITICAL: READ-ONLY MODE - NO FILE MODIFICATIONS ===\n" +
		"This is a READ-ONLY planning task."
}

func sdkCLIContext() *gin.Context {
	c, _ := gin.CreateTestContext(httptest.NewRecorder())
	c.Request = httptest.NewRequest("POST", "/v1/messages", nil)
	c.Request.Header.Set("User-Agent", "claude-cli/2.1.219 (external, sdk-cli)")
	return c
}

func TestClaudeCodeAgentRoleSessionCache_TTLAndBound(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, time.July, 27, 10, 0, 0, 0, time.UTC)
	cache := newClaudeCodeAgentRoleSessionCache(10*time.Minute, 2, func() time.Time { return now })

	cache.Remember("session-1", service.ClaudeCodeAgentRolePlan)
	cache.Remember("session-2", service.ClaudeCodeAgentRolePlan)
	require.Equal(t, service.ClaudeCodeAgentRolePlan, cache.Lookup("session-1"))

	cache.Remember("session-3", service.ClaudeCodeAgentRolePlan)
	require.Equal(t, service.ClaudeCodeAgentRoleUnknown, cache.Lookup("session-1"), "oldest entry must be evicted")
	require.Equal(t, service.ClaudeCodeAgentRolePlan, cache.Lookup("session-3"))

	now = now.Add(11 * time.Minute)
	require.Equal(t, service.ClaudeCodeAgentRoleUnknown, cache.Lookup("session-2"))
	require.Equal(t, service.ClaudeCodeAgentRoleUnknown, cache.Lookup("session-3"))
}

func TestClaudeCodeAgentRoleSessionCache_ConcurrentAccessStaysBounded(t *testing.T) {
	t.Parallel()
	cache := newClaudeCodeAgentRoleSessionCache(time.Hour, 32, time.Now)

	var workers sync.WaitGroup
	for index := 0; index < 256; index++ {
		workers.Add(1)
		go func(sessionID string) {
			defer workers.Done()
			cache.Remember(sessionID, service.ClaudeCodeAgentRolePlan)
			_ = cache.Lookup(sessionID)
		}(fmt.Sprintf("session-%d", index))
	}
	workers.Wait()

	cache.mu.Lock()
	defer cache.mu.Unlock()
	require.LessOrEqual(t, len(cache.entries), cache.maxEntries)
}

func TestResolveClaudeCodeAgentProfile_PlanWinsOverGenericSDK(t *testing.T) {
	t.Parallel()
	group := &service.Group{MessagesDispatchModelConfig: service.OpenAIMessagesDispatchModelConfig{
		PlanMappedModel:       "gpt-5.6-sol",
		PlanReasoningEffort:   "high",
		SDKCLIMappedModel:     "gpt-5.6-luna",
		SDKCLIReasoningEffort: "max",
	}}
	cache := newClaudeCodeAgentRoleSessionCache(time.Hour, 32, time.Now)
	body := planProfileBody(t, planProfileSystem(), "Create a plan", "plan-session", []string{"Bash", "Glob", "Grep", "Read", "ToolSearch"})

	profile, matched := resolveClaudeCodeAgentProfile(sdkCLIContext(), body, group, cache)

	require.True(t, matched)
	require.Equal(t, "gpt-5.6-sol", profile.Model)
	require.Equal(t, "high", profile.ReasoningEffort)
	require.Equal(t, service.ClaudeCodeAgentRolePlan, profile.Role)
	require.Equal(t, claudeCodeAgentRoleSourceSystemComposite, profile.Source)
}

func TestResolveClaudeCodeAgentProfile_UsesSessionStickyPlanAfterSystemRewrite(t *testing.T) {
	t.Parallel()
	group := &service.Group{MessagesDispatchModelConfig: service.OpenAIMessagesDispatchModelConfig{
		PlanMappedModel:       "gpt-5.6-sol",
		PlanReasoningEffort:   "high",
		SDKCLIMappedModel:     "gpt-5.6-luna",
		SDKCLIReasoningEffort: "max",
	}}
	cache := newClaudeCodeAgentRoleSessionCache(time.Hour, 32, time.Now)
	first := planProfileBody(t, planProfileSystem(), "Create a plan", "sticky-session", []string{"Bash", "Glob", "Grep", "Read"})
	_, matched := resolveClaudeCodeAgentProfile(sdkCLIContext(), first, group, cache)
	require.True(t, matched)

	compressed := planProfileBody(t, "Headroom compressed the original role prompt.", "Continue", "sticky-session", []string{"Bash", "Glob", "Grep", "Read"})
	profile, matched := resolveClaudeCodeAgentProfile(sdkCLIContext(), compressed, group, cache)

	require.True(t, matched)
	require.Equal(t, "gpt-5.6-sol", profile.Model)
	require.Equal(t, service.ClaudeCodeAgentRolePlan, profile.Role)
	require.Equal(t, claudeCodeAgentRoleSourceSessionCache, profile.Source)
}

func TestResolveClaudeCodeAgentProfile_UserPromptCannotEscalateExplore(t *testing.T) {
	t.Parallel()
	group := &service.Group{MessagesDispatchModelConfig: service.OpenAIMessagesDispatchModelConfig{
		PlanMappedModel:       "gpt-5.6-sol",
		PlanReasoningEffort:   "high",
		SDKCLIMappedModel:     "gpt-5.6-luna",
		SDKCLIReasoningEffort: "max",
	}}
	body := planProfileBody(t,
		"x-anthropic-billing-header: cc_entrypoint=sdk-cli; cc_is_subagent=true;\nYou are the Explore Claude Code subagent.",
		planProfileSystem(),
		"explore-session",
		[]string{"Agent", "Bash", "Edit", "Glob", "Grep", "Read", "Write"},
	)

	profile, matched := resolveClaudeCodeAgentProfile(sdkCLIContext(), body, group, newClaudeCodeAgentRoleSessionCache(time.Hour, 32, time.Now))

	require.True(t, matched)
	require.Equal(t, "gpt-5.6-luna", profile.Model)
	require.Equal(t, "max", profile.ReasoningEffort)
	require.Equal(t, service.ClaudeCodeAgentRoleUnknown, profile.Role)
	require.Equal(t, claudeCodeAgentRoleSourceGenericSDKCLI, profile.Source)
}

func TestResolveClaudeCodeAgentProfile_MissingPlanConfigFallsBackToGenericSDK(t *testing.T) {
	t.Parallel()
	group := &service.Group{MessagesDispatchModelConfig: service.OpenAIMessagesDispatchModelConfig{
		SDKCLIMappedModel:     "gpt-5.6-luna",
		SDKCLIReasoningEffort: "max",
	}}
	body := planProfileBody(t, planProfileSystem(), "Create a plan", "unconfigured-plan", []string{"Bash", "Glob", "Grep", "Read"})

	profile, matched := resolveClaudeCodeAgentProfile(sdkCLIContext(), body, group, newClaudeCodeAgentRoleSessionCache(time.Hour, 32, time.Now))

	require.True(t, matched)
	require.Equal(t, "gpt-5.6-luna", profile.Model)
	require.Equal(t, "max", profile.ReasoningEffort)
	require.Equal(t, claudeCodeAgentRoleSourceGenericSDKCLI, profile.Source)
}

func TestResolveClaudeCodeAgentProfile_StandaloneSDKCLIIsNotAChild(t *testing.T) {
	t.Parallel()
	group := &service.Group{MessagesDispatchModelConfig: service.OpenAIMessagesDispatchModelConfig{
		SDKCLIMappedModel:     "gpt-5.6-luna",
		SDKCLIReasoningEffort: "max",
	}}
	body := planProfileBody(t,
		"x-anthropic-billing-header: cc_entrypoint=sdk-cli; cc_is_subagent=false;",
		"Run a normal prompt.",
		"standalone-session",
		[]string{"Bash", "Read"},
	)

	profile, matched := resolveClaudeCodeAgentProfile(sdkCLIContext(), body, group, newClaudeCodeAgentRoleSessionCache(time.Hour, 32, time.Now))

	require.False(t, matched)
	require.Empty(t, profile.Model)
}
