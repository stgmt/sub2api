package service

import (
	"context"
	"errors"
	"log/slog"
	"strings"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/config"
)

// DiagnoseModelAvailabilityForPlatform reports whether the requested model
// is configured to be served by any OpenAI-compatible account in the group
// for the given platform (e.g. PlatformOpenAI, PlatformGrok). The platform
// scopes the candidate pool so distinct OpenAI-compatible platforms do not
// cross-contaminate diagnosis results.
//
// Safe to call on the error path: returns {true,true} on any internal
// failure or when the inputs preclude meaningful diagnosis (empty model,
// nil service), so callers stay on the 503 fallback branch. Unlike the
// generic diagnoser, this OpenAI/Codex path also inspects model-scoped
// cooldowns in account extra because the scheduler filters those before
// account selection.
func (s *OpenAIGatewayService) DiagnoseModelAvailabilityForPlatform(
	ctx context.Context,
	groupID *int64,
	requestedModel string,
	platform string,
) ModelAvailabilityDiagnosis {
	if s == nil {
		return ModelAvailabilityDiagnosis{HasAccountsInPool: true, HasModelSupport: true}
	}
	requestedModel = strings.TrimSpace(requestedModel)
	if requestedModel == "" {
		return ModelAvailabilityDiagnosis{HasAccountsInPool: true, HasModelSupport: true}
	}

	accounts, err := s.listAccountsForNoAccountDiagnosis(ctx, groupID, platform)
	if err != nil {
		// Conservative fallback so the caller keeps returning 503; we do not
		// want a transient lookup failure to flip into 404 model_not_found.
		return ModelAvailabilityDiagnosis{HasAccountsInPool: true, HasModelSupport: true}
	}

	diag := ModelAvailabilityDiagnosis{}
	matchingModelAccounts := 0
	rateLimitedMatchingAccounts := 0
	authErroredMatchingAccounts := 0
	now := time.Now()
	for i := range accounts {
		diag.HasAccountsInPool = true
		// Mirrors the per-candidate filter used during account selection
		// (openai_account_scheduler.isAccountRequestCompatible): empty
		// model_mapping accepts everything; otherwise the explicit / wildcard
		// mapping must match.
		if accounts[i].IsModelSupported(requestedModel) {
			diag.HasModelSupport = true
			matchingModelAccounts++
			if isOpenAIOAuthCredentialError(&accounts[i]) {
				authErroredMatchingAccounts++
				if diag.AuthErrorMessage == "" {
					diag.AuthErrorMessage = summarizeOpenAIOAuthCredentialError(accounts[i].ErrorMessage)
				}
				continue
			}
			if resetAt := accountRequestRateLimitResetAt(ctx, &accounts[i], requestedModel, now); resetAt != nil {
				rateLimitedMatchingAccounts++
				if diag.RateLimitResetAt == nil || resetAt.Before(*diag.RateLimitResetAt) {
					resetAtCopy := *resetAt
					diag.RateLimitResetAt = &resetAtCopy
				}
			}
		}
	}
	if matchingModelAccounts > 0 && matchingModelAccounts == rateLimitedMatchingAccounts {
		diag.AllModelSupportingAccountsRateLimited = true
	}
	if matchingModelAccounts > 0 && matchingModelAccounts == authErroredMatchingAccounts {
		diag.AllModelSupportingAccountsAuthErrored = true
	}
	return diag
}

func isOpenAIOAuthCredentialError(account *Account) bool {
	if account == nil || !account.IsOpenAIOAuth() || account.Status != StatusError {
		return false
	}
	msg := strings.ToLower(strings.TrimSpace(account.ErrorMessage))
	if msg == "" {
		return false
	}
	if strings.Contains(msg, "openai_oauth_token_refresh_failed") ||
		strings.Contains(msg, "token refresh failed") {
		return strings.Contains(msg, "refresh_token_reused") ||
			strings.Contains(msg, "invalid_refresh_token") ||
			strings.Contains(msg, "refresh_token_invalidated") ||
			strings.Contains(msg, "token_expired") ||
			strings.Contains(msg, "invalid_grant") ||
			strings.Contains(msg, "app_session_terminated") ||
			strings.Contains(msg, "no refresh token available")
	}
	return false
}

func summarizeOpenAIOAuthCredentialError(message string) string {
	msg := strings.ToLower(message)
	for _, code := range []string{
		"refresh_token_reused",
		"invalid_refresh_token",
		"refresh_token_invalidated",
		"token_expired",
		"invalid_grant",
		"app_session_terminated",
		"no refresh token available",
	} {
		if strings.Contains(msg, code) {
			return code
		}
	}
	return "oauth_refresh_failed"
}

func accountRequestRateLimitResetAt(ctx context.Context, account *Account, requestedModel string, now time.Time) *time.Time {
	if account == nil {
		return nil
	}

	var readyAt *time.Time
	if account.RateLimitResetAt != nil && now.Before(*account.RateLimitResetAt) {
		resetAt := *account.RateLimitResetAt
		readyAt = &resetAt
	}
	for _, key := range account.modelRateLimitKeysForRequest(ctx, requestedModel) {
		resetAt := account.modelRateLimitResetAt(key)
		if resetAt == nil || !now.Before(*resetAt) {
			continue
		}
		if readyAt == nil || resetAt.After(*readyAt) {
			resetAtCopy := *resetAt
			readyAt = &resetAtCopy
		}
	}
	return readyAt
}

func (s *OpenAIGatewayService) listAccountsForNoAccountDiagnosis(ctx context.Context, groupID *int64, platform string) ([]Account, error) {
	if s == nil || s.accountRepo == nil {
		return nil, nil
	}
	platform = normalizeOpenAICompatiblePlatform(platform)
	if s.cfg != nil && s.cfg.RunMode == config.RunModeSimple {
		return s.accountRepo.ListAllWithFilters(ctx, platform, "", "", "", 0, "")
	}

	groupFilter := AccountListGroupUngrouped
	if groupID != nil {
		groupFilter = *groupID
	}
	return s.accountRepo.ListAllWithFilters(ctx, platform, "", "", "", groupFilter, "")
}

func openAIAccountHasGroupID(account *Account, groupID int64) bool {
	if account == nil {
		return false
	}
	for _, id := range account.GroupIDs {
		if id == groupID {
			return true
		}
	}
	return false
}

func (s *OpenAIGatewayService) tryRecoverOpenAIOAuthAccountsFromCodexAuthFile(ctx context.Context, groupID *int64, platform string, requestedModel string) bool {
	if s == nil || s.accountRepo == nil || normalizeOpenAICompatiblePlatform(platform) != PlatformOpenAI {
		return false
	}
	requestedModel = strings.TrimSpace(requestedModel)
	if requestedModel == "" {
		return false
	}
	accounts, err := s.listAccountsForNoAccountDiagnosis(ctx, groupID, platform)
	if err != nil {
		slog.Warn("openai_codex_auth_file_recovery_list_failed", "platform", platform, "error", err)
		return false
	}

	recovered := false
	for i := range accounts {
		account := &accounts[i]
		if !account.IsModelSupported(requestedModel) || !isOpenAIOAuthCredentialError(account) {
			continue
		}
		if recoverOpenAIOAuthFromCodexAuthFile(ctx, s.accountRepo, nil, account, errors.New(account.ErrorMessage)) {
			s.invalidateOpenAITokenCache(ctx, account)
			recovered = true
		}
	}
	return recovered
}

func (s *OpenAIGatewayService) invalidateOpenAITokenCache(ctx context.Context, account *Account) {
	if s == nil || s.openAITokenProvider == nil || s.openAITokenProvider.tokenCache == nil || account == nil {
		return
	}
	if err := s.openAITokenProvider.tokenCache.DeleteAccessToken(ctx, OpenAITokenCacheKey(account)); err != nil {
		slog.Warn("openai_codex_auth_file_recovery_cache_delete_failed", "account_id", account.ID, "error", err)
	}
}
