package admin

import (
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/stretchr/testify/require"
)

func TestValidateProviderSyncRequest(t *testing.T) {
	cline := providerSyncRequest{
		Source: "cline_pass_cli", Platform: service.PlatformOpenAI, AccountType: service.AccountTypeAPIKey,
		GroupName: "mixed", GroupPlatform: service.PlatformOpenAI,
		Credentials: map[string]any{"base_url": "https://api.cline.bot/api/v1"},
	}
	require.Empty(t, validateProviderSyncRequest(&cline))
	require.Equal(t, service.SubscriptionTypeSubscription, cline.Subscription)
	require.Equal(t, 3, cline.Concurrency)

	bad := cline
	bad.Source = "unknown"
	require.Equal(t, "unsupported_provider_sync_source", validateProviderSyncRequest(&bad))

	bad = cline
	bad.Credentials = map[string]any{"base_url": "https://evil.invalid/v1"}
	require.Equal(t, "invalid_cline_provider_contract", validateProviderSyncRequest(&bad))
}

func TestProviderSyncCompositeModelCatalog(t *testing.T) {
	models := providerSyncModelsListConfig()
	require.True(t, models.Enabled)
	require.True(t, models.Explicit)
	require.Equal(t, []string{
		"gpt-5.6-sol", "gpt-5.6", "gpt-5.6-luna", "grok-4.6", "grok-4.5",
		"cline-pass/qwen3.8-max", "poolside/laguna-s-2.1:free", "cline-pass/kimi-k3",
		"cline-pass/minimax-m3", "cline-pass/deepseek-v4-flash", "cline-pass/deepseek-v4-pro",
		"deepseek/deepseek-v4-flash", "cline-pass/mimo-v2.5", "cline-pass/mimo-v2.5-pro",
		"cline-pass/glm-5.3",
	}, models.Models)
	require.NotContains(t, models.Models, "gpt-5.4")
	require.NotContains(t, models.Models, "nvidia/nemotron")

	models.Models[0] = "mutated"
	require.Equal(t, "gpt-5.6-sol", providerSyncModelsListConfig().Models[0])
}

func TestProviderSyncCredentialsPreservesServiceOwnedAccessState(t *testing.T) {
	current := map[string]any{
		"refresh_token": "same-refresh", "access_token": "service-access", "expires_at": "service-expiry",
		"base_url": "https://old.invalid/v1",
	}
	incoming := map[string]any{
		"refresh_token": "same-refresh", "access_token": "host-access", "expires_at": "host-expiry",
		"base_url": "https://cli-chat-proxy.grok.com/v1", "auth_source": "grok_build_cli",
	}
	merged := providerSyncCredentials(current, incoming, true)
	require.Equal(t, "service-access", merged["access_token"])
	require.Equal(t, "service-expiry", merged["expires_at"])
	require.Equal(t, "https://cli-chat-proxy.grok.com/v1", merged["base_url"])

	incoming["refresh_token"] = "rotated-refresh"
	rotated := providerSyncCredentials(current, incoming, true)
	require.Equal(t, "host-access", rotated["access_token"])
	require.Equal(t, "rotated-refresh", rotated["refresh_token"])

	cline := providerSyncCredentials(current, map[string]any{
		"refresh_token": "same-refresh", "api_key": "fresh-cline-access",
	}, false)
	require.Equal(t, "fresh-cline-access", cline["api_key"])
}
