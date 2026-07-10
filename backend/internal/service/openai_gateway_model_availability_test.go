//go:build unit

package service

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestOpenAIDiagnoseModelAvailability_AllSupportingAccountsRateLimited(t *testing.T) {
	resetSoon := time.Now().Add(30 * time.Minute).UTC()
	resetLater := time.Now().Add(90 * time.Minute).UTC()
	repo := &mockAccountRepoForPlatform{
		accounts: []Account{
			{
				ID:               1,
				Platform:         PlatformOpenAI,
				Status:           StatusActive,
				Schedulable:      true,
				GroupIDs:         []int64{7},
				RateLimitResetAt: &resetLater,
				Credentials:      map[string]any{"model_mapping": map[string]any{"gpt-5.5": "gpt-5.5"}},
			},
			{
				ID:               2,
				Platform:         PlatformOpenAI,
				Status:           StatusActive,
				Schedulable:      true,
				GroupIDs:         []int64{7},
				RateLimitResetAt: &resetSoon,
				Credentials:      map[string]any{"model_mapping": map[string]any{"gpt-5.5": "gpt-5.5"}},
			},
		},
		accountsByID: map[int64]*Account{},
	}
	svc := &OpenAIGatewayService{accountRepo: repo, cfg: testConfig()}
	groupID := int64(7)

	diag := svc.DiagnoseModelAvailabilityForPlatform(context.Background(), &groupID, "gpt-5.5", PlatformOpenAI)

	require.True(t, diag.HasAccountsInPool)
	require.True(t, diag.HasModelSupport)
	require.True(t, diag.AllModelSupportingAccountsRateLimited)
	require.NotNil(t, diag.RateLimitResetAt)
	require.WithinDuration(t, resetSoon, *diag.RateLimitResetAt, time.Second)
}

func TestOpenAIDiagnoseModelAvailability_AllSupportingAccountsModelScopedRateLimited(t *testing.T) {
	resetSoon := time.Now().Add(30 * time.Minute).UTC()
	resetLater := time.Now().Add(90 * time.Minute).UTC()
	repo := &mockAccountRepoForPlatform{
		accounts: []Account{
			{
				ID:          1,
				Platform:    PlatformOpenAI,
				Status:      StatusActive,
				Schedulable: true,
				GroupIDs:    []int64{7},
				Credentials: map[string]any{"model_mapping": map[string]any{"gpt-5.6-sol": "gpt-5.6-sol"}},
				Extra: map[string]any{
					"model_rate_limits": map[string]any{
						"gpt-5.6-sol": map[string]any{
							"reason":              "openai_model_rate_limited",
							"rate_limit_reset_at": resetLater.Format(time.RFC3339),
						},
					},
				},
			},
			{
				ID:          2,
				Platform:    PlatformOpenAI,
				Status:      StatusActive,
				Schedulable: true,
				GroupIDs:    []int64{7},
				Credentials: map[string]any{"model_mapping": map[string]any{"gpt-5.6-sol": "gpt-5.6-sol"}},
				Extra: map[string]any{
					"model_rate_limits": map[string]any{
						"gpt-5.6-sol": map[string]any{
							"reason":              "openai_model_rate_limited",
							"rate_limit_reset_at": resetSoon.Format(time.RFC3339),
						},
					},
				},
			},
		},
		accountsByID: map[int64]*Account{},
	}
	svc := &OpenAIGatewayService{accountRepo: repo, cfg: testConfig()}
	groupID := int64(7)

	diag := svc.DiagnoseModelAvailabilityForPlatform(context.Background(), &groupID, "gpt-5.6-sol", PlatformOpenAI)

	require.True(t, diag.HasAccountsInPool)
	require.True(t, diag.HasModelSupport)
	require.True(t, diag.AllModelSupportingAccountsRateLimited)
	require.NotNil(t, diag.RateLimitResetAt)
	require.WithinDuration(t, resetSoon, *diag.RateLimitResetAt, time.Second)
}

func TestOpenAIDiagnoseModelAvailability_ModelScopedRateLimitUsesMappedModel(t *testing.T) {
	resetAt := time.Now().Add(30 * time.Minute).UTC()
	repo := &mockAccountRepoForPlatform{
		accounts: []Account{
			{
				ID:          1,
				Platform:    PlatformOpenAI,
				Status:      StatusActive,
				Schedulable: true,
				GroupIDs:    []int64{7},
				Credentials: map[string]any{"model_mapping": map[string]any{"claude-opus-4-8": "gpt-5.6-sol"}},
				Extra: map[string]any{
					"model_rate_limits": map[string]any{
						"gpt-5.6-sol": map[string]any{
							"reason":              "openai_model_rate_limited",
							"rate_limit_reset_at": resetAt.Format(time.RFC3339),
						},
					},
				},
			},
		},
		accountsByID: map[int64]*Account{},
	}
	svc := &OpenAIGatewayService{accountRepo: repo, cfg: testConfig()}
	groupID := int64(7)

	diag := svc.DiagnoseModelAvailabilityForPlatform(context.Background(), &groupID, "claude-opus-4-8", PlatformOpenAI)

	require.True(t, diag.HasAccountsInPool)
	require.True(t, diag.HasModelSupport)
	require.True(t, diag.AllModelSupportingAccountsRateLimited)
	require.NotNil(t, diag.RateLimitResetAt)
	require.WithinDuration(t, resetAt, *diag.RateLimitResetAt, time.Second)
}

func TestOpenAIDiagnoseModelAvailability_MixedRateLimitedAndUsableDoesNotReturnRateLimit(t *testing.T) {
	resetAt := time.Now().Add(30 * time.Minute).UTC()
	repo := &mockAccountRepoForPlatform{
		accounts: []Account{
			{
				ID:               1,
				Platform:         PlatformOpenAI,
				Status:           StatusActive,
				Schedulable:      true,
				GroupIDs:         []int64{7},
				RateLimitResetAt: &resetAt,
				Credentials:      map[string]any{"model_mapping": map[string]any{"gpt-5.5": "gpt-5.5"}},
			},
			{
				ID:          2,
				Platform:    PlatformOpenAI,
				Status:      StatusActive,
				Schedulable: true,
				GroupIDs:    []int64{7},
				Credentials: map[string]any{"model_mapping": map[string]any{"gpt-5.5": "gpt-5.5"}},
			},
		},
		accountsByID: map[int64]*Account{},
	}
	svc := &OpenAIGatewayService{accountRepo: repo, cfg: testConfig()}
	groupID := int64(7)

	diag := svc.DiagnoseModelAvailabilityForPlatform(context.Background(), &groupID, "gpt-5.5", PlatformOpenAI)

	require.True(t, diag.HasAccountsInPool)
	require.True(t, diag.HasModelSupport)
	require.False(t, diag.AllModelSupportingAccountsRateLimited)
	require.NotNil(t, diag.RateLimitResetAt)
}
