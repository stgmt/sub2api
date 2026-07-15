//go:build unit

package service

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/config"
	"github.com/stretchr/testify/require"
)

type runtimeBlockRecorder struct {
	accounts   []*Account
	until      []time.Time
	reasons    []string
	clearedIDs []int64
}

func (r *runtimeBlockRecorder) BlockAccountScheduling(account *Account, until time.Time, reason string) {
	r.accounts = append(r.accounts, account)
	r.until = append(r.until, until)
	r.reasons = append(r.reasons, reason)
}

func (r *runtimeBlockRecorder) ClearAccountSchedulingBlock(accountID int64) {
	r.clearedIDs = append(r.clearedIDs, accountID)
}

func TestRateLimitService_HandleUpstreamError_OpenAI403FirstHitTempUnschedulable(t *testing.T) {
	repo := &rateLimitAccountRepoStub{}
	counter := &openAI403CounterCacheStub{counts: []int64{1}}
	blocker := &runtimeBlockRecorder{}
	service := NewRateLimitService(repo, nil, &config.Config{}, nil, nil)
	service.SetOpenAI403CounterCache(counter)
	service.SetAccountRuntimeBlocker(blocker)
	account := &Account{
		ID:       301,
		Platform: PlatformOpenAI,
		Type:     AccountTypeOAuth,
	}

	shouldDisable := service.HandleUpstreamError(
		context.Background(),
		account,
		http.StatusForbidden,
		http.Header{},
		[]byte(`{"error":{"message":"temporary edge rejection"}}`),
	)

	require.True(t, shouldDisable)
	require.Equal(t, 0, repo.setErrorCalls)
	require.Equal(t, 1, repo.tempCalls)
	require.Contains(t, repo.lastTempReason, "temporary edge rejection")
	require.Contains(t, repo.lastTempReason, "(1/3,")
	require.Contains(t, repo.lastTempReason, "retry_in=2s")
	require.WithinDuration(t, time.Now().Add(2*time.Second), repo.lastTempUntil, time.Second)
	require.Len(t, blocker.accounts, 1)
	require.Equal(t, account.ID, blocker.accounts[0].ID)
	require.Equal(t, "openai_403_temp", blocker.reasons[0])
	require.True(t, blocker.until[0].After(time.Now()))
}

func TestRateLimitService_HandleUpstreamError_OpenAI403ThresholdStaysTemporaryForOAuth(t *testing.T) {
	repo := &rateLimitAccountRepoStub{}
	counter := &openAI403CounterCacheStub{counts: []int64{3}}
	service := NewRateLimitService(repo, nil, &config.Config{}, nil, nil)
	service.SetOpenAI403CounterCache(counter)
	account := &Account{
		ID:       302,
		Platform: PlatformOpenAI,
		Type:     AccountTypeOAuth,
	}

	shouldDisable := service.HandleUpstreamError(
		context.Background(),
		account,
		http.StatusForbidden,
		http.Header{},
		[]byte(`{"error":{"message":"workspace forbidden by policy"}}`),
	)

	require.True(t, shouldDisable)
	require.Equal(t, 0, repo.setErrorCalls)
	require.Equal(t, 1, repo.tempCalls)
	require.Equal(t, account.ID, repo.lastTempID)
	require.Contains(t, repo.lastTempReason, "workspace forbidden by policy")
	require.Contains(t, repo.lastTempReason, "threshold reached")
	require.Contains(t, repo.lastTempReason, "consecutive_403=3/3")
	require.Contains(t, repo.lastTempReason, "retry_in=1m0s")
	require.WithinDuration(t, time.Now().Add(time.Minute), repo.lastTempUntil, time.Second)
}

func TestOpenAI403Cooldown(t *testing.T) {
	tests := []struct {
		count int64
		want  time.Duration
	}{
		{count: 0, want: 2 * time.Second},
		{count: 1, want: 2 * time.Second},
		{count: 2, want: 15 * time.Second},
		{count: 3, want: time.Minute},
		{count: 4, want: 5 * time.Minute},
		{count: 100, want: 5 * time.Minute},
	}

	for _, tt := range tests {
		require.Equal(t, tt.want, openAI403Cooldown(tt.count))
	}
}

func TestRateLimitService_RecoverOpenAI403AfterSuccessClearsOnly403State(t *testing.T) {
	repo := &rateLimitAccountRepoStub{}
	counter := &openAI403CounterCacheStub{}
	cache := &tempUnschedCacheRecorder{}
	blocker := &runtimeBlockRecorder{}
	service := NewRateLimitService(repo, nil, &config.Config{}, nil, cache)
	service.SetOpenAI403CounterCache(counter)
	service.SetAccountRuntimeBlocker(blocker)
	account := &Account{
		ID:                      305,
		Platform:                PlatformOpenAI,
		Type:                    AccountTypeOAuth,
		TempUnschedulableReason: "OpenAI OAuth 403 temporary cooldown (1/3, retry_in=2s): edge rejection",
	}

	service.RecoverOpenAI403AfterSuccess(context.Background(), account)

	require.Equal(t, []int64{account.ID}, counter.resetCalls)
	require.Equal(t, 1, repo.clearTempCalls)
	require.Equal(t, []int64{account.ID}, cache.deletedIDs)
	require.Equal(t, []int64{account.ID}, blocker.clearedIDs)
}

func TestRateLimitService_RecoverOpenAI403AfterSuccessPreservesOtherTempState(t *testing.T) {
	repo := &rateLimitAccountRepoStub{}
	counter := &openAI403CounterCacheStub{}
	cache := &tempUnschedCacheRecorder{}
	blocker := &runtimeBlockRecorder{}
	service := NewRateLimitService(repo, nil, &config.Config{}, nil, cache)
	service.SetOpenAI403CounterCache(counter)
	service.SetAccountRuntimeBlocker(blocker)
	account := &Account{
		ID:                      306,
		Platform:                PlatformOpenAI,
		Type:                    AccountTypeOAuth,
		TempUnschedulableReason: "openai_model_rate_limited",
	}

	service.RecoverOpenAI403AfterSuccess(context.Background(), account)

	require.Equal(t, []int64{account.ID}, counter.resetCalls)
	require.Zero(t, repo.clearTempCalls)
	require.Empty(t, cache.deletedIDs)
	require.Empty(t, blocker.clearedIDs)
}

func TestRateLimitService_RecoverOpenAI403AfterSuccessKeepsBlockWhenDatabaseClearFails(t *testing.T) {
	repo := &rateLimitAccountRepoStub{clearTempErr: context.Canceled}
	counter := &openAI403CounterCacheStub{}
	cache := &tempUnschedCacheRecorder{}
	blocker := &runtimeBlockRecorder{}
	service := NewRateLimitService(repo, nil, &config.Config{}, nil, cache)
	service.SetOpenAI403CounterCache(counter)
	service.SetAccountRuntimeBlocker(blocker)
	account := &Account{
		ID:                      307,
		Platform:                PlatformOpenAI,
		Type:                    AccountTypeOAuth,
		TempUnschedulableReason: "OpenAI OAuth 403 temporary cooldown (1/3, retry_in=2s): edge rejection",
	}

	service.RecoverOpenAI403AfterSuccess(context.Background(), account)

	require.Equal(t, []int64{account.ID}, counter.resetCalls)
	require.Equal(t, 1, repo.clearTempCalls)
	require.Empty(t, cache.deletedIDs)
	require.Empty(t, blocker.clearedIDs)
}

func TestRateLimitService_HandleUpstreamError_OpenAI403TempWriteFailureDoesNotDisableOAuth(t *testing.T) {
	repo := &rateLimitAccountRepoStub{tempErr: context.Canceled}
	counter := &openAI403CounterCacheStub{counts: []int64{3}}
	service := NewRateLimitService(repo, nil, &config.Config{}, nil, nil)
	service.SetOpenAI403CounterCache(counter)
	account := &Account{
		ID:       303,
		Platform: PlatformOpenAI,
		Type:     AccountTypeOAuth,
	}

	shouldDisable := service.HandleUpstreamError(
		context.Background(),
		account,
		http.StatusForbidden,
		http.Header{},
		[]byte(`<html>Access denied</html>`),
	)

	require.True(t, shouldDisable)
	require.Equal(t, 0, repo.setErrorCalls)
	require.Equal(t, 1, repo.tempCalls)
	require.Contains(t, repo.lastTempReason, "threshold reached")
}

func TestRateLimitService_HandleUpstreamError_OpenAI403NonOAuthStillDisables(t *testing.T) {
	repo := &rateLimitAccountRepoStub{}
	service := NewRateLimitService(repo, nil, &config.Config{}, nil, nil)
	account := &Account{
		ID:       304,
		Platform: PlatformOpenAI,
		Type:     AccountTypeAPIKey,
	}

	shouldDisable := service.HandleUpstreamError(
		context.Background(),
		account,
		http.StatusForbidden,
		http.Header{},
		[]byte(`{"error":{"message":"api key forbidden"}}`),
	)

	require.True(t, shouldDisable)
	require.Equal(t, 1, repo.setErrorCalls)
	require.Equal(t, 0, repo.tempCalls)
	require.Contains(t, repo.lastErrorMsg, "api key forbidden")
}
