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
// into the OpenAI OAuth wire tier. The user-facing Codex setting is called
// `fast`, but the native ChatGPT/Codex client sends service_tier="priority".
func applyAnthropicFastModeToResponses(req *apicompat.ResponsesRequest, betaHeader, speed string) (bool, string) {
	return applyAnthropicFastModeToResponsesForAccount(req, betaHeader, speed, nil)
}

func applyAnthropicFastModeToResponsesForAccount(req *apicompat.ResponsesRequest, betaHeader, speed string, account *Account) (bool, string) {
	if req == nil {
		return false, ""
	}
	source := anthropicFastModeSource(betaHeader, speed)
	if source == "" {
		return false, ""
	}
	req.ServiceTier = openAIFastTierForAccount(account)
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

// isOpenAIFastProviderTier accepts the tier names that an OpenAI-compatible
// provider may return. The current ChatGPT/Codex OAuth path sends priority;
// accepting fast as an echoed value keeps confirmation parsing compatible with
// other OpenAI-compatible implementations.
func isOpenAIFastProviderTier(tier string) bool {
	switch strings.ToLower(strings.TrimSpace(tier)) {
	case OpenAIFastTierFast, OpenAIFastTierPriority:
		return true
	default:
		return false
	}
}

func openAIFastTierForAccount(_ *Account) string {
	// `fast` is a Codex configuration alias. The OpenAI OAuth Responses
	// endpoint used by this gateway rejects raw service_tier="fast"; native
	// Codex serializes the subscription Fast toggle as service_tier="priority".
	return OpenAIFastTierPriority
}

func normalizeOpenAIServiceTierForAccount(raw string, _ *Account) string {
	tier := normalizedOpenAIServiceTierValue(raw)
	if tier == OpenAIFastTierFast {
		return OpenAIFastTierPriority
	}
	return tier
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
