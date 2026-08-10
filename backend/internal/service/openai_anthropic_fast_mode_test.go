package service

import (
	"encoding/json"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/pkg/apicompat"
	"github.com/stretchr/testify/require"
)

func TestAnthropicFastModeSource(t *testing.T) {
	for _, tc := range []struct {
		name   string
		header string
		speed  string
		want   string
	}{
		{name: "beta header", header: "fast-mode-2026-02-01", want: "beta_header"},
		{name: "body", speed: "fast", want: "body"},
		{name: "both", header: "fast-mode-2026-02-01", speed: "FAST", want: "beta_header+body"},
		{name: "ordinary", speed: "standard", want: ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			require.Equal(t, tc.want, anthropicFastModeSource(tc.header, tc.speed))
		})
	}
}

func TestApplyAnthropicFastModeToResponses(t *testing.T) {
	ordinary := &apicompat.ResponsesRequest{Model: "gpt-5.6-luna"}
	requested, source := applyAnthropicFastModeToResponses(ordinary, "", "")
	require.False(t, requested)
	require.Empty(t, source)
	require.Empty(t, ordinary.ServiceTier, "ordinary Claude requests must not become fast")

	fast := &apicompat.ResponsesRequest{Model: "gpt-5.6-luna"}
	requested, source = applyAnthropicFastModeToResponses(fast, "", "fast")
	require.True(t, requested)
	require.Equal(t, "body", source)
	require.Equal(t, OpenAIFastTierPriority, fast.ServiceTier)
}

func TestApplyAnthropicFastModeToResponsesForAccountUsesCodexWireTier(t *testing.T) {
	fast := &apicompat.ResponsesRequest{Model: "gpt-5.6-luna"}
	oauth := &Account{Platform: PlatformOpenAI, Type: AccountTypeOAuth}

	requested, source := applyAnthropicFastModeToResponsesForAccount(fast, "fast-mode-2026-02-01", "", oauth)

	require.True(t, requested)
	require.Equal(t, "beta_header", source)
	require.Equal(t, OpenAIFastTierPriority, fast.ServiceTier)
}

func TestApplyAnthropicFastModeToResponsesForAccountUsesPriorityForAPIKey(t *testing.T) {
	fast := &apicompat.ResponsesRequest{Model: "gpt-5.6-luna"}
	apiKey := &Account{Platform: PlatformOpenAI, Type: AccountTypeAPIKey}

	requested, _ := applyAnthropicFastModeToResponsesForAccount(fast, "fast-mode-2026-02-01", "", apiKey)

	require.True(t, requested)
	require.Equal(t, OpenAIFastTierPriority, fast.ServiceTier)
}

func TestAnthropicSpeedSurvivesMessagesParsingAndReachesChatFallbackTier(t *testing.T) {
	body := []byte(`{"model":"gpt-5.6-luna","max_tokens":64,"speed":"fast","messages":[{"role":"user","content":"hi"}]}`)
	var anthropicReq apicompat.AnthropicRequest
	require.NoError(t, json.Unmarshal(body, &anthropicReq))
	require.Equal(t, "fast", anthropicReq.Speed)

	responsesReq, err := apicompat.AnthropicToResponses(&anthropicReq)
	require.NoError(t, err)
	requested, _ := applyAnthropicFastModeToResponses(responsesReq, "", anthropicReq.Speed)
	require.True(t, requested)

	chatReq, err := apicompat.ResponsesToChatCompletionsRequest(responsesReq)
	require.NoError(t, err)
	chatBody, err := json.Marshal(chatReq)
	require.NoError(t, err)
	serviceTier := extractOpenAIServiceTierFromBody(chatBody)
	require.NotNil(t, serviceTier)
	require.Equal(t, OpenAIFastTierPriority, *serviceTier)
}

func TestProviderServiceTierIsReadFromResponsesTerminal(t *testing.T) {
	var response apicompat.ResponsesResponse
	require.NoError(t, json.Unmarshal([]byte(`{"id":"resp_1","object":"response","model":"gpt-5.6-luna","status":"completed","service_tier":"priority","output":[]}`), &response))
	require.Equal(t, OpenAIFastTierPriority, response.ServiceTier)
}

func TestReconcileOpenAIServiceTierWithProvider(t *testing.T) {
	requestTier := OpenAIFastTierPriority
	providerTier := "default"
	result := &OpenAIForwardResult{ServiceTier: &requestTier, ProviderServiceTier: &providerTier}

	reconcileOpenAIServiceTierWithProvider(result)

	require.NotNil(t, result.ServiceTier)
	require.Equal(t, "default", *result.ServiceTier)
}

func TestIsOpenAIFastProviderTier(t *testing.T) {
	for _, tier := range []string{OpenAIFastTierPriority, "fast", " FAST "} {
		require.True(t, isOpenAIFastProviderTier(tier), "tier %q must count as provider-confirmed fast", tier)
	}
	for _, tier := range []string{"", "default", "auto", "flex"} {
		require.False(t, isOpenAIFastProviderTier(tier), "tier %q must not count as provider-confirmed fast", tier)
	}
}
