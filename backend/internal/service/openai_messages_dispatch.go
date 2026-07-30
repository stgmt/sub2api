package service

import (
	"strings"

	"github.com/Wei-Shaw/sub2api/internal/pkg/xai"
)

const (
	defaultOpenAIMessagesDispatchOpusMappedModel   = "gpt-5.4"
	defaultOpenAIMessagesDispatchSonnetMappedModel = "gpt-5.3-codex"
	defaultOpenAIMessagesDispatchHaikuMappedModel  = "gpt-5.3-codex-spark"
)

func normalizeOpenAIMessagesDispatchMappedModel(model string) string {
	// Preserve reasoning aliases such as gpt-5.6-terra-medium until request
	// normalization, where the suffix also clamps output_config.effort.
	return strings.TrimSpace(model)
}

func normalizeOpenAIMessagesDispatchFallbackModel(model string) string {
	return strings.TrimSpace(model)
}

func normalizeOpenAIMessagesDispatchReasoningEffort(effort string) string {
	effort = strings.ToLower(strings.TrimSpace(effort))
	effort = strings.ReplaceAll(effort, "-", "")
	switch effort {
	case "low", "medium", "high", "xhigh", "max":
		return effort
	default:
		return ""
	}
}

func normalizeOpenAIMessagesDispatchModelConfig(cfg OpenAIMessagesDispatchModelConfig) OpenAIMessagesDispatchModelConfig {
	out := OpenAIMessagesDispatchModelConfig{
		OpusMappedModel:        normalizeOpenAIMessagesDispatchMappedModel(cfg.OpusMappedModel),
		SonnetMappedModel:      normalizeOpenAIMessagesDispatchMappedModel(cfg.SonnetMappedModel),
		HaikuMappedModel:       normalizeOpenAIMessagesDispatchMappedModel(cfg.HaikuMappedModel),
		CompactMappedModel:     normalizeOpenAIMessagesDispatchFallbackModel(cfg.CompactMappedModel),
		CompactReasoningEffort: normalizeOpenAIMessagesDispatchReasoningEffort(cfg.CompactReasoningEffort),
		PlanMappedModel:        normalizeOpenAIMessagesDispatchFallbackModel(cfg.PlanMappedModel),
		PlanReasoningEffort:    normalizeOpenAIMessagesDispatchReasoningEffort(cfg.PlanReasoningEffort),
		SDKCLIMappedModel:      normalizeOpenAIMessagesDispatchFallbackModel(cfg.SDKCLIMappedModel),
		SDKCLIReasoningEffort:  normalizeOpenAIMessagesDispatchReasoningEffort(cfg.SDKCLIReasoningEffort),
	}

	if len(cfg.ExactModelMappings) > 0 {
		out.ExactModelMappings = make(map[string]string, len(cfg.ExactModelMappings))
		for requestedModel, mappedModel := range cfg.ExactModelMappings {
			requestedModel = strings.TrimSpace(requestedModel)
			mappedModel = normalizeOpenAIMessagesDispatchMappedModel(mappedModel)
			if requestedModel == "" || mappedModel == "" {
				continue
			}
			out.ExactModelMappings[requestedModel] = mappedModel
		}
		if len(out.ExactModelMappings) == 0 {
			out.ExactModelMappings = nil
		}
	}

	out.ModelFallbacks = normalizeOpenAIMessagesDispatchFallbacks(cfg.ModelFallbacks)
	out.AutomaticModelFallbacks = normalizeOpenAIMessagesDispatchFallbacks(cfg.AutomaticModelFallbacks)

	return out
}

func normalizeOpenAIMessagesDispatchFallbacks(fallbacks map[string][]string) map[string][]string {
	if len(fallbacks) == 0 {
		return nil
	}
	normalized := make(map[string][]string, len(fallbacks))
	for requestedModel, fallbackModels := range fallbacks {
		requestedModel = strings.TrimSpace(requestedModel)
		if requestedModel == "" {
			continue
		}
		normalizedFallbacks := make([]string, 0, len(fallbackModels))
		seen := make(map[string]bool, len(fallbackModels))
		for _, fallbackModel := range fallbackModels {
			fallbackModel = normalizeOpenAIMessagesDispatchFallbackModel(fallbackModel)
			if fallbackModel == "" {
				continue
			}
			key := strings.ToLower(fallbackModel)
			if seen[key] {
				continue
			}
			seen[key] = true
			normalizedFallbacks = append(normalizedFallbacks, fallbackModel)
		}
		normalized[requestedModel] = normalizedFallbacks
	}
	if len(normalized) == 0 {
		return nil
	}
	return normalized
}

func claudeMessagesDispatchFamily(model string) string {
	normalized := strings.ToLower(strings.TrimSpace(model))
	if !strings.HasPrefix(normalized, "claude") {
		return ""
	}
	switch {
	case strings.Contains(normalized, "opus"):
		return "opus"
	case strings.Contains(normalized, "sonnet"):
		return "sonnet"
	case strings.Contains(normalized, "haiku"):
		return "haiku"
	default:
		return ""
	}
}

func (g *Group) ResolveMessagesDispatchModel(requestedModel string) string {
	if g == nil {
		return ""
	}
	requestedModel = strings.TrimSpace(requestedModel)
	if requestedModel == "" {
		return ""
	}

	if g.Platform == PlatformGrok {
		if claudeMessagesDispatchFamily(requestedModel) != "" {
			return xai.DefaultModelMapping()["grok"]
		}
		return ""
	}

	cfg := normalizeOpenAIMessagesDispatchModelConfig(g.MessagesDispatchModelConfig)
	if mappedModel := strings.TrimSpace(cfg.ExactModelMappings[requestedModel]); mappedModel != "" {
		return mappedModel
	}

	switch claudeMessagesDispatchFamily(requestedModel) {
	case "opus":
		if mappedModel := strings.TrimSpace(cfg.OpusMappedModel); mappedModel != "" {
			return mappedModel
		}
		return defaultOpenAIMessagesDispatchOpusMappedModel
	case "sonnet":
		if mappedModel := strings.TrimSpace(cfg.SonnetMappedModel); mappedModel != "" {
			return mappedModel
		}
		return defaultOpenAIMessagesDispatchSonnetMappedModel
	case "haiku":
		if mappedModel := strings.TrimSpace(cfg.HaikuMappedModel); mappedModel != "" {
			return mappedModel
		}
		return defaultOpenAIMessagesDispatchHaikuMappedModel
	default:
		return ""
	}
}

// ResolveMessagesDispatchExplicitModel returns only mappings explicitly set on
// the group. Mixed-provider routing uses this before provider classification so
// compatibility aliases can intentionally cross-route without reviving the
// legacy implicit Claude-to-OpenAI defaults.
func (g *Group) ResolveMessagesDispatchExplicitModel(requestedModel string) string {
	if g == nil {
		return ""
	}
	requestedModel = strings.TrimSpace(requestedModel)
	if requestedModel == "" {
		return ""
	}

	cfg := normalizeOpenAIMessagesDispatchModelConfig(g.MessagesDispatchModelConfig)
	if mappedModel := strings.TrimSpace(cfg.ExactModelMappings[requestedModel]); mappedModel != "" {
		return mappedModel
	}

	switch claudeMessagesDispatchFamily(requestedModel) {
	case "opus":
		return strings.TrimSpace(cfg.OpusMappedModel)
	case "sonnet":
		return strings.TrimSpace(cfg.SonnetMappedModel)
	case "haiku":
		return strings.TrimSpace(cfg.HaikuMappedModel)
	default:
		return ""
	}
}

func (g *Group) ResolveMessagesDispatchFallbackModels(requestedModel, mappedModel string) []string {
	if g == nil {
		return nil
	}
	cfg := normalizeOpenAIMessagesDispatchModelConfig(g.MessagesDispatchModelConfig)
	if len(cfg.ModelFallbacks) == 0 {
		return nil
	}

	return resolveMessagesDispatchFallbackModels(cfg.ModelFallbacks, requestedModel, mappedModel)
}

func (g *Group) ResolveMessagesDispatchAutomaticFallbackModels(requestedModel, mappedModel string) []string {
	if g == nil {
		return nil
	}
	cfg := normalizeOpenAIMessagesDispatchModelConfig(g.MessagesDispatchModelConfig)
	return resolveMessagesDispatchFallbackModels(cfg.AutomaticModelFallbacks, requestedModel, mappedModel)
}

func resolveMessagesDispatchFallbackModels(fallbacks map[string][]string, requestedModel, mappedModel string) []string {
	if len(fallbacks) == 0 {
		return nil
	}
	var candidates []string
	for _, key := range []string{strings.TrimSpace(mappedModel), strings.TrimSpace(requestedModel)} {
		if key == "" {
			continue
		}
		if models, matched := resolveRequestedModelInSliceMapping(fallbacks, key); matched {
			candidates = append(candidates, models...)
		}
	}
	return compactModelFallbackCandidates(candidates, mappedModel)
}

func (g *Group) ResolveMessagesDispatchCompactProfile() (model, reasoningEffort string) {
	if g == nil {
		return "", ""
	}
	cfg := normalizeOpenAIMessagesDispatchModelConfig(g.MessagesDispatchModelConfig)
	return strings.TrimSpace(cfg.CompactMappedModel), strings.TrimSpace(cfg.CompactReasoningEffort)
}

func (g *Group) ResolveMessagesDispatchSDKCLIProfile() (model, reasoningEffort string) {
	if g == nil {
		return "", ""
	}
	cfg := normalizeOpenAIMessagesDispatchModelConfig(g.MessagesDispatchModelConfig)
	return strings.TrimSpace(cfg.SDKCLIMappedModel), strings.TrimSpace(cfg.SDKCLIReasoningEffort)
}

func (g *Group) ResolveMessagesDispatchPlanProfile() (model, reasoningEffort string) {
	if g == nil {
		return "", ""
	}
	cfg := normalizeOpenAIMessagesDispatchModelConfig(g.MessagesDispatchModelConfig)
	return strings.TrimSpace(cfg.PlanMappedModel), strings.TrimSpace(cfg.PlanReasoningEffort)
}

func sanitizeGroupMessagesDispatchFields(g *Group) {
	if g == nil || g.Platform == PlatformOpenAI {
		return
	}
	g.AllowMessagesDispatch = false
	g.DefaultMappedModel = ""
	g.MessagesDispatchModelConfig = OpenAIMessagesDispatchModelConfig{}
}
