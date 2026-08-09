package service

import (
	"strings"

	"github.com/Wei-Shaw/sub2api/internal/pkg/apicompat"
	"github.com/Wei-Shaw/sub2api/internal/pkg/claude"
	"github.com/Wei-Shaw/sub2api/internal/pkg/logger"
	"go.uber.org/zap"
)

// anthropicFastModeSource returns the client signal that requested Anthropic
// fast mode. Claude Code versions have used the beta header, while newer
// Messages API clients also send speed:"fast" in the request body.
//
// Either signal is sufficient at this compatibility boundary. A client that
// already sent speed:"fast" has explicitly opted in even if an intermediary
// stripped the beta header; accepting both forms prevents a silent downgrade.
func anthropicFastModeSource(betaHeader, speed string) string {
	headerFast := containsBetaToken(betaHeader, claude.BetaFastMode)
	bodyFast := strings.EqualFold(strings.TrimSpace(speed), "fast")
	switch {
	case headerFast && bodyFast:
		return "beta_header+body"
	case headerFast:
		return "beta_header"
	case bodyFast:
		return "body"
	default:
		return ""
	}
}

// applyAnthropicFastModeToResponses translates the Anthropic fast-mode signal
// into the OpenAI-compatible tier used by the Codex/OpenAI upstream. It is
// intentionally opt-in: absent a fast signal, the request remains on the
// provider default tier.
func applyAnthropicFastModeToResponses(req *apicompat.ResponsesRequest, betaHeader, speed string) (bool, string) {
	if req == nil {
		return false, ""
	}
	source := anthropicFastModeSource(betaHeader, speed)
	if source == "" {
		return false, ""
	}
	req.ServiceTier = OpenAIFastTierPriority
	return true, source
}

func logAnthropicFastModeProviderConfirmation(account *Account, originalModel, upstreamModel, source string, result *OpenAIForwardResult) {
	providerTier := ""
	requestTier := ""
	if result != nil {
		if result.ProviderServiceTier != nil {
			providerTier = strings.TrimSpace(*result.ProviderServiceTier)
		}
		if result.ServiceTier != nil {
			requestTier = strings.TrimSpace(*result.ServiceTier)
		}
	}
	logger.L().Info("openai_messages.fast_mode_provider_confirmation",
		zap.Int64("account_id", account.ID),
		zap.String("original_model", originalModel),
		zap.String("upstream_model", upstreamModel),
		zap.String("source", source),
		zap.String("request_service_tier", requestTier),
		zap.String("provider_service_tier", providerTier),
		zap.Bool("provider_confirmed", isOpenAIFastProviderTier(providerTier)),
	)
}

// isOpenAIFastProviderTier accepts both names used by OpenAI-compatible
// Responses implementations. The ChatGPT OAuth endpoint currently requests
// `priority`, while newer API surfaces may echo `fast` directly.
func isOpenAIFastProviderTier(tier string) bool {
	switch strings.ToLower(strings.TrimSpace(tier)) {
	case OpenAIFastTierPriority, "fast":
		return true
	default:
		return false
	}
}

// reconcileOpenAIServiceTierWithProvider replaces the request intent with the
// tier that the upstream response says actually served the turn. This keeps
// billing and usage_logs truthful when ChatGPT-auth/headless traffic silently
// downgrades priority to default.
func reconcileOpenAIServiceTierWithProvider(result *OpenAIForwardResult) {
	if result == nil || result.ProviderServiceTier == nil {
		return
	}
	providerTier := strings.TrimSpace(*result.ProviderServiceTier)
	if providerTier == "" {
		return
	}
	result.ServiceTier = &providerTier
}
