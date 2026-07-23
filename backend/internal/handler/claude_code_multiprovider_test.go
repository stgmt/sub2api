package handler

import (
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
)

func TestClassifyClaudeCodeMessagesRoute_MixedClaudeEndpoint(t *testing.T) {
	tests := []struct {
		name          string
		model         string
		groupPlatform string
		want          claudeCodeMessagesRoute
	}{
		{
			name:          "GPT stays on OpenAI dispatch",
			model:         "gpt-5.6-sol",
			groupPlatform: service.PlatformOpenAI,
			want:          claudeCodeMessagesRouteOpenAI,
		},
		{
			name:          "Codex Spark stays on OpenAI dispatch",
			model:         "gpt-5.3-codex-spark",
			groupPlatform: service.PlatformOpenAI,
			want:          claudeCodeMessagesRouteOpenAI,
		},
		{
			name:          "Qwen routes to Anthropic-compatible passthrough",
			model:         "qwen3.8-max-preview",
			groupPlatform: service.PlatformOpenAI,
			want:          claudeCodeMessagesRouteAnthropic,
		},
		{
			name:          "DeepSeek Token Plan routes to passthrough",
			model:         "deepseek-v4-pro",
			groupPlatform: service.PlatformOpenAI,
			want:          claudeCodeMessagesRouteAnthropic,
		},
		{
			name:          "Claude alias stays Claude-family",
			model:         "opus",
			groupPlatform: service.PlatformOpenAI,
			want:          claudeCodeMessagesRouteAnthropic,
		},
		{
			name:          "Claude version stays Claude-family",
			model:         "claude-opus-4-8",
			groupPlatform: service.PlatformOpenAI,
			want:          claudeCodeMessagesRouteAnthropic,
		},
		{
			name:          "Fable alias stays Claude-family",
			model:         "fable",
			groupPlatform: service.PlatformOpenAI,
			want:          claudeCodeMessagesRouteAnthropic,
		},
		{
			name:          "Empty model falls back to group OpenAI behavior",
			model:         "",
			groupPlatform: service.PlatformOpenAI,
			want:          claudeCodeMessagesRouteOpenAI,
		},
		{
			name:          "Unknown non-OpenAI group remains native",
			model:         "",
			groupPlatform: service.PlatformAnthropic,
			want:          claudeCodeMessagesRouteNative,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			require.Equal(t, tt.want, classifyClaudeCodeMessagesRoute(tt.model, tt.groupPlatform))
		})
	}
}

func TestClassifyClaudeCodeCountTokensRoute_MixedClaudeEndpoint(t *testing.T) {
	tests := []struct {
		name          string
		model         string
		groupPlatform string
		want          claudeCodeMessagesRoute
	}{
		{
			name:          "GPT count_tokens stays on OpenAI bridge",
			model:         "gpt-5.6-sol",
			groupPlatform: service.PlatformOpenAI,
			want:          claudeCodeMessagesRouteOpenAI,
		},
		{
			name:          "Qwen count_tokens does not hit Codex account",
			model:         "qwen3.8-max-preview",
			groupPlatform: service.PlatformOpenAI,
			want:          claudeCodeMessagesRouteAnthropic,
		},
		{
			name:          "GLM count_tokens stays Token Plan family",
			model:         "glm-5.2",
			groupPlatform: service.PlatformOpenAI,
			want:          claudeCodeMessagesRouteAnthropic,
		},
		{
			name:          "Claude count_tokens stays passthrough family",
			model:         "claude-opus-4-8",
			groupPlatform: service.PlatformOpenAI,
			want:          claudeCodeMessagesRouteAnthropic,
		},
		{
			name:          "Empty model falls back to OpenAI group behavior",
			model:         "",
			groupPlatform: service.PlatformOpenAI,
			want:          claudeCodeMessagesRouteOpenAI,
		},
		{
			name:          "Grok group remains native unsupported",
			model:         "grok",
			groupPlatform: service.PlatformGrok,
			want:          claudeCodeMessagesRouteNative,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			require.Equal(t, tt.want, classifyClaudeCodeCountTokensRoute(tt.model, tt.groupPlatform))
		})
	}
}

func TestIsClaudeCodeCompactRequestForMultiprovider(t *testing.T) {
	t.Parallel()

	gin.SetMode(gin.TestMode)
	req := httptest.NewRequest("POST", "/v1/messages", strings.NewReader(`{"model":"gpt-5.6-sol"}`))
	req.Header.Set("x-sub2api-claude-compact", "1")
	c, _ := gin.CreateTestContext(httptest.NewRecorder())
	c.Request = req

	require.True(t, isClaudeCodeCompactRequestForMultiprovider(c, []byte(`{"model":"gpt-5.6-sol"}`)))

	req = httptest.NewRequest("POST", "/v1/messages", strings.NewReader(`{"model":"gpt-5.6-sol"}`))
	c, _ = gin.CreateTestContext(httptest.NewRecorder())
	c.Request = req

	body := []byte(`{"model":"gpt-5.6-sol","messages":[{"role":"user","content":"Your task is to create a detailed summary of the conversation so far."}]}`)
	require.True(t, isClaudeCodeCompactRequestForMultiprovider(c, body))
	require.False(t, isClaudeCodeCompactRequestForMultiprovider(c, []byte(`{"model":"gpt-5.6-sol","messages":[{"role":"user","content":"ordinary task"}]}`)))
}

func TestRewriteClaudeCodeCompactModelForMultiprovider_RoutesGPTCompactToQwenFamily(t *testing.T) {
	t.Parallel()

	body := []byte(`{"model":"gpt-5.6-sol","messages":[{"role":"user","content":"compact"}]}`)
	rewritten, model, err := rewriteClaudeCodeCompactModelForMultiprovider(body, " qwen3.8-max-preview ")
	require.NoError(t, err)
	require.JSONEq(t, `{"model":"qwen3.8-max-preview","messages":[{"role":"user","content":"compact"}]}`, string(rewritten))
	require.Equal(t, "qwen3.8-max-preview", model)
	require.Equal(t, claudeCodeMessagesRouteAnthropic, classifyClaudeCodeMessagesRoute(model, service.PlatformOpenAI))
}

func TestRewriteClaudeCodeCompactModelForMultiprovider_NoopsWhenAlreadyMapped(t *testing.T) {
	t.Parallel()

	body := []byte(`{"model":"qwen3.8-max-preview"}`)
	rewritten, model, err := rewriteClaudeCodeCompactModelForMultiprovider(body, "qwen3.8-max-preview")
	require.NoError(t, err)
	require.Equal(t, body, rewritten)
	require.Equal(t, "qwen3.8-max-preview", model)
}

func TestRewriteExplicitClaudeCodeModelForMultiprovider_RoutesConfiguredAliasBeforeClassification(t *testing.T) {
	t.Parallel()

	body := []byte(`{"model":"claude-haiku-4-5-20251001","messages":[{"role":"user","content":"hi"}]}`)
	group := &service.Group{
		Platform: service.PlatformOpenAI,
		MessagesDispatchModelConfig: service.OpenAIMessagesDispatchModelConfig{
			HaikuMappedModel: "qwen3.8-max-preview",
		},
	}

	rewritten, model, err := rewriteExplicitClaudeCodeModelForMultiprovider(
		body,
		"claude-haiku-4-5-20251001",
		service.PlatformOpenAI,
		group,
	)
	require.NoError(t, err)
	require.JSONEq(t, `{"model":"qwen3.8-max-preview","messages":[{"role":"user","content":"hi"}]}`, string(rewritten))
	require.Equal(t, "qwen3.8-max-preview", model)
	require.Equal(t, claudeCodeMessagesRouteAnthropic, classifyClaudeCodeMessagesRoute(model, service.PlatformOpenAI))
}

func TestRewriteExplicitClaudeCodeModelForMultiprovider_PreservesUnmappedClaudePassthrough(t *testing.T) {
	t.Parallel()

	body := []byte(`{"model":"claude-opus-4-8"}`)
	rewritten, model, err := rewriteExplicitClaudeCodeModelForMultiprovider(
		body,
		"claude-opus-4-8",
		service.PlatformOpenAI,
		&service.Group{Platform: service.PlatformOpenAI},
	)
	require.NoError(t, err)
	require.Equal(t, body, rewritten)
	require.Equal(t, "claude-opus-4-8", model)
}
