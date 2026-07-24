//go:build unit

package service

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestAlibabaTokenPlanQuotaResetAt_ParsesExplicitWeeklyReset(t *testing.T) {
	now := time.Date(2026, time.July, 24, 10, 0, 0, 0, time.UTC)
	body := []byte(`{"code":"Throttling.AllocationQuota","message":"Your token-plan 1-week quota has been exhausted. The quota will reset at 07-28 14:20:00 UTC."}`)

	resetAt, exhausted := AlibabaTokenPlanQuotaResetAt(body, now)

	require.True(t, exhausted)
	require.Equal(t, time.Date(2026, time.July, 28, 14, 20, 0, 0, time.UTC), resetAt)
}

func TestAlibabaTokenPlanQuotaResetAt_RollsResetIntoNextYear(t *testing.T) {
	now := time.Date(2026, time.December, 31, 23, 0, 0, 0, time.UTC)
	body := []byte(`{"error":{"code":"Throttling.AllocationQuota","message":"Your token-plan 1-week quota has been exhausted. The quota will reset at 01-01 01:00:00 UTC."}}`)

	resetAt, exhausted := AlibabaTokenPlanQuotaResetAt(body, now)

	require.True(t, exhausted)
	require.Equal(t, time.Date(2027, time.January, 1, 1, 0, 0, 0, time.UTC), resetAt)
}

func TestAlibabaTokenPlanQuotaResetAt_RejectsTransientAllocationLimit(t *testing.T) {
	body := []byte(`{"code":"Throttling.AllocationQuota","message":"Requests rate limit exceeded, retry in one minute."}`)

	_, exhausted := AlibabaTokenPlanQuotaResetAt(body, time.Now())

	require.False(t, exhausted)
}

func TestAlibabaTokenPlanQuotaResetAt_TerminalQuotaWithoutResetUsesBoundedReprobe(t *testing.T) {
	now := time.Date(2026, time.July, 24, 10, 0, 0, 0, time.UTC)
	body := []byte(`{"code":"Throttling.AllocationQuota","message":"Your token-plan 1-week quota has been exhausted."}`)

	resetAt, exhausted := AlibabaTokenPlanQuotaResetAt(body, now)

	require.True(t, exhausted)
	require.Equal(t, now.Add(alibabaTokenPlanUnknownResetCooldown), resetAt)
}

func TestAlibabaTokenPlanQuotaResetAt_InvalidResetUsesBoundedReprobe(t *testing.T) {
	now := time.Date(2026, time.July, 24, 10, 0, 0, 0, time.UTC)
	body := []byte(`{"code":"Throttling.AllocationQuota","message":"Your token-plan 1-week quota has been exhausted. The quota will reset at 99-99 99:99:99 UTC."}`)

	resetAt, exhausted := AlibabaTokenPlanQuotaResetAt(body, now)

	require.True(t, exhausted)
	require.Equal(t, now.Add(alibabaTokenPlanUnknownResetCooldown), resetAt)
}

func TestHandleUpstreamError_AlibabaTokenPlanQuotaPersistsAccountCircuit(t *testing.T) {
	repo := &anthropicWindowLimitRepo{}
	svc := NewRateLimitService(repo, nil, nil, nil, nil)
	account := &Account{ID: 42, Type: AccountTypeAPIKey, Platform: PlatformAnthropic}
	body := []byte(`{"code":"Throttling.AllocationQuota","message":"Your token-plan 1-week quota has been exhausted. The quota will reset at 12-31 23:59:59 UTC."}`)

	svc.HandleUpstreamError(context.Background(), account, http.StatusTooManyRequests, http.Header{}, body, "qwen3.8-max-preview")

	require.Equal(t, 1, repo.rateLimitCalls)
	require.Equal(t, time.December, repo.lastRateLimitReset.Month())
	require.Equal(t, 31, repo.lastRateLimitReset.Day())
	require.Equal(t, 23, repo.lastRateLimitReset.Hour())
	require.True(t, repo.lastRateLimitReset.After(time.Now().UTC()))
	require.Zero(t, repo.tempUnschedCalls)
}
