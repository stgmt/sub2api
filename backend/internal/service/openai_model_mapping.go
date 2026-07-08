package service

import "strings"

// resolveOpenAIForwardModel 解析 OpenAI 兼容转发使用的模型。
// defaultMappedModel 只服务于 /v1/messages 的 Claude 系列显式调度映射，
// 不作为普通 OpenAI 请求的未知模型兜底。
func resolveOpenAIForwardModel(account *Account, requestedModel, defaultMappedModel string) string {
	if account == nil {
		if defaultMappedModel != "" && claudeMessagesDispatchFamily(requestedModel) != "" {
			return defaultMappedModel
		}
		return requestedModel
	}

	mappedModel, matched := account.ResolveMappedModel(requestedModel)
	if !matched && defaultMappedModel != "" && claudeMessagesDispatchFamily(requestedModel) != "" {
		return defaultMappedModel
	}
	return mappedModel
}

// resolveOpenAICompactForwardModel determines the compact-only upstream model
// for /responses/compact requests. It never affects normal /responses traffic.
// When no compact-specific mapping matches, the input model is returned as-is.
func resolveOpenAICompactForwardModel(account *Account, model string) string {
	trimmedModel := strings.TrimSpace(model)
	if trimmedModel == "" || account == nil {
		return trimmedModel
	}

	mappedModel, matched := account.ResolveCompactMappedModel(trimmedModel)
	if !matched {
		return trimmedModel
	}
	if trimmedMapped := strings.TrimSpace(mappedModel); trimmedMapped != "" {
		return trimmedMapped
	}
	return trimmedModel
}

func resolveOpenAICompactFallbackForwardModels(account *Account, requestedModel, mappedModel string) []string {
	if account == nil {
		return nil
	}
	primaryUpstreamModel := normalizeOpenAIModelForUpstream(account, mappedModel)
	rawCandidates := account.ResolveCompactFallbackModels(requestedModel, mappedModel)
	if len(rawCandidates) == 0 {
		return nil
	}

	result := make([]string, 0, len(rawCandidates))
	seen := make(map[string]bool, len(rawCandidates)+1)
	if primaryUpstreamModel != "" {
		seen[strings.ToLower(primaryUpstreamModel)] = true
	}
	for _, candidate := range rawCandidates {
		trimmed := strings.TrimSpace(candidate)
		if trimmed == "" {
			continue
		}
		upstreamModel := normalizeOpenAIModelForUpstream(account, trimmed)
		if upstreamModel == "" {
			continue
		}
		key := strings.ToLower(upstreamModel)
		if seen[key] {
			continue
		}
		seen[key] = true
		result = append(result, upstreamModel)
	}
	return result
}
