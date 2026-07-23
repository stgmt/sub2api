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
	model = NormalizeOpenAICompatRequestedModel(strings.TrimSpace(model))
	return strings.TrimSpace(model)
}

func normalizeOpenAIMessagesDispatchFallbackModel(model string) string {
	return strings.TrimSpace(model)
}

func normalizeOpenAIMessagesDispatchModelConfig(cfg OpenAIMessagesDispatchModelConfig) OpenAIMessagesDispatchModelConfig {
	out := OpenAIMessagesDispatchModelConfig{
		OpusMappedModel:    normalizeOpenAIMessagesDispatchMappedModel(cfg.OpusMappedModel),
		SonnetMappedModel:  normalizeOpenAIMessagesDispatchMappedModel(cfg.SonnetMappedModel),
		HaikuMappedModel:   normalizeOpenAIMessagesDispatchMappedModel(cfg.HaikuMappedModel),
		CompactMappedModel: normalizeOpenAIMessagesDispatchFallbackModel(cfg.CompactMappedModel),
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

	if len(cfg.ModelFallbacks) > 0 {
		out.ModelFallbacks = make(map[string][]string, len(cfg.ModelFallbacks))
		for requestedModel, fallbackModels := range cfg.ModelFallbacks {
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
			out.ModelFallbacks[requestedModel] = normalizedFallbacks
		}
		if len(out.ModelFallbacks) == 0 {
			out.ModelFallbacks = nil
		}
	}

	return out
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

	var candidates []string
	for _, key := range []string{strings.TrimSpace(mappedModel), strings.TrimSpace(requestedModel)} {
		if key == "" {
			continue
		}
		if models, matched := resolveRequestedModelInSliceMapping(cfg.ModelFallbacks, key); matched {
			candidates = append(candidates, models...)
		}
	}
	return compactModelFallbackCandidates(candidates, mappedModel)
}

func (g *Group) ResolveMessagesDispatchCompactModel() string {
	if g == nil {
		return ""
	}
	cfg := normalizeOpenAIMessagesDispatchModelConfig(g.MessagesDispatchModelConfig)
	return strings.TrimSpace(cfg.CompactMappedModel)
}

func sanitizeGroupMessagesDispatchFields(g *Group) {
	if g == nil || g.Platform == PlatformOpenAI {
		return
	}
	g.AllowMessagesDispatch = false
	g.DefaultMappedModel = ""
	g.MessagesDispatchModelConfig = OpenAIMessagesDispatchModelConfig{}
}
