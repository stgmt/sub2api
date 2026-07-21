package handler

import (
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/service"
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
