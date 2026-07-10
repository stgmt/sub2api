package service

import (
	"context"
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
	return diag
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
	accounts, err := s.accountRepo.ListByPlatform(ctx, platform)
	if err != nil {
		return nil, err
	}
	if s.cfg != nil && s.cfg.RunMode == config.RunModeSimple {
		return accounts, nil
	}

	out := make([]Account, 0, len(accounts))
	for i := range accounts {
		if groupID != nil {
			if openAIAccountHasGroupID(&accounts[i], *groupID) {
				out = append(out, accounts[i])
			}
			continue
		}
		if len(accounts[i].GroupIDs) == 0 {
			out = append(out, accounts[i])
		}
	}
	return out, nil
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
