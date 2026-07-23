package service

import "testing"

import "github.com/stretchr/testify/require"

func TestNormalizeOpenAIMessagesDispatchModelConfig(t *testing.T) {
	t.Parallel()

	cfg := normalizeOpenAIMessagesDispatchModelConfig(OpenAIMessagesDispatchModelConfig{
		OpusMappedModel:    " gpt-5.4-high ",
		SonnetMappedModel:  "gpt-5.3-codex",
		HaikuMappedModel:   " gpt-5.3-codex-spark ",
		CompactMappedModel: " qwen3.8-max-preview ",
		ExactModelMappings: map[string]string{
			" claude-sonnet-4-5-20250929 ": " gpt-5.2-high ",
			"":                             "gpt-5.4",
			"claude-opus-4-6":              " ",
		},
		ModelFallbacks: map[string][]string{
			" gpt-5.3-codex-spark ":  []string{" gpt-5.6-luna ", " "},
			" gpt-5.6-terra-medium ": []string{" gpt-5.6-sol-medium "},
			"":                       []string{"gpt-5.4"},
		},
	})

	require.Equal(t, "gpt-5.4", cfg.OpusMappedModel)
	require.Equal(t, "gpt-5.3-codex", cfg.SonnetMappedModel)
	require.Equal(t, "gpt-5.3-codex-spark", cfg.HaikuMappedModel)
	require.Equal(t, "qwen3.8-max-preview", cfg.CompactMappedModel)
	require.Equal(t, map[string]string{
		"claude-sonnet-4-5-20250929": "gpt-5.2",
	}, cfg.ExactModelMappings)
	require.Equal(t, map[string][]string{
		"gpt-5.3-codex-spark":  []string{"gpt-5.6-luna"},
		"gpt-5.6-terra-medium": []string{"gpt-5.6-sol-medium"},
	}, cfg.ModelFallbacks)
}

func TestResolveMessagesDispatchExplicitModel(t *testing.T) {
	t.Parallel()

	group := &Group{
		MessagesDispatchModelConfig: OpenAIMessagesDispatchModelConfig{
			HaikuMappedModel: "qwen3.8-max-preview",
			ExactModelMappings: map[string]string{
				"fable": "qwen3.8-max-preview",
			},
		},
	}

	require.Equal(t, "qwen3.8-max-preview", group.ResolveMessagesDispatchExplicitModel("claude-haiku-4-5-20251001"))
	require.Equal(t, "qwen3.8-max-preview", group.ResolveMessagesDispatchExplicitModel("fable"))
	require.Empty(t, group.ResolveMessagesDispatchExplicitModel("claude-sonnet-4-6"))
	require.Empty(t, (&Group{}).ResolveMessagesDispatchExplicitModel("claude-haiku-4-5-20251001"))
}

func TestGroupResolveMessagesDispatchModel_GrokMapsClaudeFamilyToGrok(t *testing.T) {
	t.Parallel()

	group := &Group{Platform: PlatformGrok}

	require.Equal(t, "grok-4.3", group.ResolveMessagesDispatchModel("claude-sonnet-4-5"))
	require.Equal(t, "grok-4.3", group.ResolveMessagesDispatchModel("claude-opus-4-6"))
	require.Equal(t, "grok-4.3", group.ResolveMessagesDispatchModel("claude-haiku-4-5"))
	require.Empty(t, group.ResolveMessagesDispatchModel("grok"))
	require.Empty(t, group.ResolveMessagesDispatchModel("gpt-5.3-codex"))
}

func TestResolveMessagesDispatchFallbackModels(t *testing.T) {
	t.Parallel()

	group := &Group{
		Platform: PlatformOpenAI,
		MessagesDispatchModelConfig: OpenAIMessagesDispatchModelConfig{
			HaikuMappedModel: "gpt-5.3-codex-spark",
			ModelFallbacks: map[string][]string{
				"gpt-5.3-codex-spark":  []string{" gpt-5.6-luna "},
				"claude-haiku-*":       []string{"gpt-5.6-luna"},
				"gpt-5.6-terra-medium": []string{"gpt-5.6-sol-medium"},
			},
		},
	}

	got := group.ResolveMessagesDispatchFallbackModels("claude-haiku-4-5", "gpt-5.3-codex-spark")
	require.Equal(t, []string{"gpt-5.6-luna"}, got)

	got = group.ResolveMessagesDispatchFallbackModels("gpt-5.6-terra-medium", "")
	require.Equal(t, []string{"gpt-5.6-sol-medium"}, got)
}

func TestGroupResolveMessagesDispatchCompactModel(t *testing.T) {
	t.Parallel()

	group := &Group{
		Platform: PlatformOpenAI,
		MessagesDispatchModelConfig: OpenAIMessagesDispatchModelConfig{
			CompactMappedModel: " qwen3.8-max-preview ",
		},
	}

	require.Equal(t, "qwen3.8-max-preview", group.ResolveMessagesDispatchCompactModel())
	require.Empty(t, (*Group)(nil).ResolveMessagesDispatchCompactModel())
}
