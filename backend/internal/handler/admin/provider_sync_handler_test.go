package admin

import (
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/domain"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/stretchr/testify/require"
)

func TestValidateProviderSyncRequest(t *testing.T) {
	cline := providerSyncRequest{
		Source: "cline_pass_cli", Platform: service.PlatformOpenAI, AccountType: service.AccountTypeAPIKey,
		GroupName: "mixed", GroupPlatform: service.PlatformOpenAI,
		Credentials: map[string]any{"base_url": "https://api.cline.bot/api/v1"},
		Models:      &domain.GroupModelsListConfig{Enabled: true, Explicit: true, Models: []string{"cline-pass/qwen3.8-max"}},
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
