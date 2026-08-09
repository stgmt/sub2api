package service

import (
	"testing"
	"time"
)

import "github.com/stretchr/testify/require"

func TestNormalizeOpenAIMessagesDispatchModelConfig(t *testing.T) {
	t.Parallel()

	cfg := normalizeOpenAIMessagesDispatchModelConfig(OpenAIMessagesDispatchModelConfig{
		OpusMappedModel:        " gpt-5.4-high ",
		SonnetMappedModel:      "gpt-5.3-codex",
		HaikuMappedModel:       " gpt-5.3-codex-spark ",
		FastMappedModel:        " gpt-5.6-luna ",
		CompactMappedModel:     " claude-sonnet-5 ",
		CompactReasoningEffort: " LOW ",
		PlanMappedModel:        " gpt-5.6-sol ",
		PlanReasoningEffort:    " HIGH ",
		SDKCLIMappedModel:      " qwen3.8-max-preview ",
		SDKCLIReasoningEffort:  " HIGH ",
		ExactModelMappings: map[string]string{
			" claude-sonnet-4-5-20250929 ": " gpt-5.2-high ",
			"":                             "gpt-5.4",
			"claude-opus-4-6":              " ",
		},
		ExactModelReasoningEfforts: map[string]string{
			" gpt-5.6-terra-medium ": " MAX ",
			"gpt-5.6-luna":           "x-high",
			"":                       "high",
		},
		ModelFallbacks: map[string][]string{
			" gpt-5.3-codex-spark ":  []string{" gpt-5.6-luna ", " "},
			" gpt-5.6-terra-medium ": []string{" gpt-5.6-sol-medium "},
			"":                       []string{"gpt-5.4"},
		},
		AutomaticModelFallbacks: map[string][]string{
			" gpt-5.6-luna ": []string{" gpt-5.6-sol ", "GPT-5.6-SOL", " "},
		},
	})

	require.Equal(t, "gpt-5.4-high", cfg.OpusMappedModel)
	require.Equal(t, "gpt-5.3-codex", cfg.SonnetMappedModel)
	require.Equal(t, "gpt-5.3-codex-spark", cfg.HaikuMappedModel)
	require.Equal(t, "gpt-5.6-luna", cfg.FastMappedModel)
	require.Equal(t, "claude-sonnet-5", cfg.CompactMappedModel)
	require.Equal(t, "low", cfg.CompactReasoningEffort)
	require.Equal(t, "gpt-5.6-sol", cfg.PlanMappedModel)
	require.Equal(t, "high", cfg.PlanReasoningEffort)
	require.Equal(t, "qwen3.8-max-preview", cfg.SDKCLIMappedModel)
	require.Equal(t, "high", cfg.SDKCLIReasoningEffort)
	require.Equal(t, map[string]string{
		"claude-sonnet-4-5-20250929": "gpt-5.2-high",
	}, cfg.ExactModelMappings)
	require.Equal(t, map[string]string{
		"gpt-5.6-terra-medium": "max",
		"gpt-5.6-luna":         "xhigh",
	}, cfg.ExactModelReasoningEfforts)
	require.Equal(t, map[string][]string{
		"gpt-5.3-codex-spark":  []string{"gpt-5.6-luna"},
		"gpt-5.6-terra-medium": []string{"gpt-5.6-sol-medium"},
	}, cfg.ModelFallbacks)
	require.Equal(t, map[string][]string{
		"gpt-5.6-luna": []string{"gpt-5.6-sol"},
	}, cfg.AutomaticModelFallbacks)
}

func TestGroupResolveMessagesDispatchFastModel(t *testing.T) {
	t.Parallel()

	group := &Group{
		Platform: PlatformOpenAI,
		MessagesDispatchModelConfig: OpenAIMessagesDispatchModelConfig{
			OpusMappedModel: "gpt-5.6-sol",
			FastMappedModel: " gpt-5.6-luna ",
		},
	}

	require.Equal(t, "gpt-5.6-luna", group.ResolveMessagesDispatchFastModel())
	require.Empty(t, (&Group{}).ResolveMessagesDispatchFastModel())
}

func TestNormalizeOpenAIMessagesDispatchModelConfig_PreservesDelegatedEffortAlias(t *testing.T) {
	t.Parallel()

	cfg := normalizeOpenAIMessagesDispatchModelConfig(OpenAIMessagesDispatchModelConfig{
		SonnetMappedModel: " gpt-5.6-terra-medium ",
		ExactModelMappings: map[string]string{
			"gpt-5.6-terra": " gpt-5.6-terra-medium ",
		},
	})

	require.Equal(t, "gpt-5.6-terra-medium", cfg.SonnetMappedModel)
	require.Equal(t, "gpt-5.6-terra-medium", cfg.ExactModelMappings["gpt-5.6-terra"])
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

func TestResolveMessagesDispatchExplicitReasoningEffort(t *testing.T) {
	t.Parallel()

	group := &Group{MessagesDispatchModelConfig: OpenAIMessagesDispatchModelConfig{
		ExactModelReasoningEfforts: map[string]string{
			"gpt-5.6-terra-medium": "max",
			"gpt-5.6-luna":         "max",
		},
	}}

	require.Equal(t, "max", group.ResolveMessagesDispatchExplicitReasoningEffort("gpt-5.6-terra", "gpt-5.6-terra-medium"))
	require.Equal(t, "max", group.ResolveMessagesDispatchExplicitReasoningEffort("GPT-5.6-LUNA", "gpt-5.6-luna"))
	require.Empty(t, group.ResolveMessagesDispatchExplicitReasoningEffort("gpt-5.6-sol", "gpt-5.6-sol"))
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

func TestResolveMessagesDispatchAutomaticFallbackModels(t *testing.T) {
	t.Parallel()

	group := &Group{
		Platform: PlatformOpenAI,
		MessagesDispatchModelConfig: OpenAIMessagesDispatchModelConfig{
			AutomaticModelFallbacks: map[string][]string{
				"gpt-5.6-luna": []string{"gpt-5.6-sol"},
			},
		},
	}

	require.Equal(t, []string{"gpt-5.6-sol"}, group.ResolveMessagesDispatchAutomaticFallbackModels("claude-haiku-4-5", "gpt-5.6-luna"))
	require.Empty(t, group.ResolveMessagesDispatchFallbackModels("claude-haiku-4-5", "gpt-5.6-luna"))
}

func TestGroupResolveMessagesDispatchCompactProfile(t *testing.T) {
	t.Parallel()

	group := &Group{
		Platform: PlatformOpenAI,
		MessagesDispatchModelConfig: OpenAIMessagesDispatchModelConfig{
			CompactMappedModel:     " claude-sonnet-5 ",
			CompactReasoningEffort: " LOW ",
		},
	}

	model, effort := group.ResolveMessagesDispatchCompactProfile()
	require.Equal(t, "claude-sonnet-5", model)
	require.Equal(t, "low", effort)

	model, effort = (*Group)(nil).ResolveMessagesDispatchCompactProfile()
	require.Empty(t, model)
	require.Empty(t, effort)
}

func TestGroupResolveMessagesDispatchSDKCLIProfile(t *testing.T) {
	t.Parallel()

	group := &Group{
		Platform: PlatformOpenAI,
		MessagesDispatchModelConfig: OpenAIMessagesDispatchModelConfig{
			SDKCLIMappedModel:     " qwen3.8-max-preview ",
			SDKCLIReasoningEffort: " HIGH ",
		},
	}

	model, effort := group.ResolveMessagesDispatchSDKCLIProfile()
	require.Equal(t, "qwen3.8-max-preview", model)
	require.Equal(t, "high", effort)

	model, effort = (*Group)(nil).ResolveMessagesDispatchSDKCLIProfile()
	require.Empty(t, model)
	require.Empty(t, effort)
}

func TestGroupResolveMessagesDispatchPlanProfile(t *testing.T) {
	t.Parallel()

	group := &Group{
		Platform: PlatformOpenAI,
		MessagesDispatchModelConfig: OpenAIMessagesDispatchModelConfig{
			PlanMappedModel:     " gpt-5.6-sol ",
			PlanReasoningEffort: " HIGH ",
		},
	}

	model, effort := group.ResolveMessagesDispatchPlanProfile()
	require.Equal(t, "gpt-5.6-sol", model)
	require.Equal(t, "high", effort)

	model, effort = (*Group)(nil).ResolveMessagesDispatchPlanProfile()
	require.Empty(t, model)
	require.Empty(t, effort)
}

func TestNormalizeOpenAIMessagesDispatchReasoningEffortRejectsUnknownValue(t *testing.T) {
	t.Parallel()

	require.Equal(t, "xhigh", normalizeOpenAIMessagesDispatchReasoningEffort("x-high"))
	require.Empty(t, normalizeOpenAIMessagesDispatchReasoningEffort("turbo"))
}

func TestAlibabaTimeWindowConfig_CrossMidnightBoundaries(t *testing.T) {
	t.Parallel()

	cfg := AlibabaTimeWindowConfig{
		Enabled:          true,
		Timezone:         "Europe/Moscow",
		Start:            "17:00",
		End:              "03:00",
		MainModel:        "qwen3.8-max-preview",
		PlanModel:        "qwen3.8-max-preview",
		SubagentModel:    "deepseek-v4-flash-0731",
		OutOfWindowModel: "deepseek-v4-flash-0731",
		ReasoningEffort:  "high",
	}

	tests := []struct {
		name                  string
		now                   time.Time
		plan, specialized     bool
		wantModel, wantEffort string
		wantActive            bool
	}{
		{"before start", time.Date(2026, time.August, 3, 13, 59, 0, 0, time.UTC), false, false, "deepseek-v4-flash-0731", "high", true},
		{"start inclusive", time.Date(2026, time.August, 3, 14, 0, 0, 0, time.UTC), false, false, "qwen3.8-max-preview", "high", true},
		{"plan in window", time.Date(2026, time.August, 3, 14, 0, 0, 0, time.UTC), true, false, "qwen3.8-max-preview", "high", true},
		{"subagent in window", time.Date(2026, time.August, 3, 14, 0, 0, 0, time.UTC), false, true, "deepseek-v4-flash-0731", "high", true},
		{"end exclusive", time.Date(2026, time.August, 4, 0, 0, 0, 0, time.UTC), false, false, "deepseek-v4-flash-0731", "high", true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			model, effort, active := cfg.Resolve(tt.now, tt.plan, tt.specialized)
			require.Equal(t, tt.wantModel, model)
			require.Equal(t, tt.wantEffort, effort)
			require.Equal(t, tt.wantActive, active)
		})
	}
}
