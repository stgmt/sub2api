package service

import (
	"context"
	"strings"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/config"
)

// ModelAvailabilityDiagnosis describes whether the requested model can be
// served by any configured account in the group, ignoring transient state
// (rate limits, quota auto-pause, runtime blocks). Handlers use this on the
// "no available accounts" error path to distinguish 404 model_not_found from
// 503 service_unavailable.
type ModelAvailabilityDiagnosis struct {
	// HasAccountsInPool is true if the group has at least one configured
	// account on the queried platform (or, for Anthropic/Gemini, on the
	// platform plus mixed-scheduled Antigravity accounts).
	HasAccountsInPool bool
	// HasModelSupport is true if at least one account's model mapping admits
	// the requested model.
	HasModelSupport bool
	// AllModelSupportingAccountsRateLimited is true when every account that
	// could serve the requested model is currently blocked by a global or
	// model-scoped upstream rate-limit cooldown.
	AllModelSupportingAccountsRateLimited bool
	// RateLimitResetAt is the earliest reset time among model-supporting
	// accounts when AllModelSupportingAccountsRateLimited is true.
	RateLimitResetAt *time.Time
	// AllModelSupportingAccountsAuthErrored is true when every account that
	// could serve the requested model is permanently blocked by an OAuth
	// credential refresh failure. This is not a transient service outage and
	// should be surfaced as an authentication/credential repair problem.
	AllModelSupportingAccountsAuthErrored bool
	AuthErrorMessage                      string
}

// ModelAvailabilityDiagnoser is implemented by gateway services that can
// report whether the requested model is configured to be served by any
// account. Both *GatewayService and *OpenAIGatewayService implement this so
// handlers in either package can share a single classifier.
type ModelAvailabilityDiagnoser interface {
	DiagnoseModelAvailabilityForPlatform(
		ctx context.Context,
		groupID *int64,
		requestedModel string,
		platform string,
	) ModelAvailabilityDiagnosis
}

// DiagnoseModelAvailabilityForPlatform inspects all configured accounts of
// the given platform and returns whether the requested model is configured to
// be served by any of them. It deliberately ignores schedulability so it can
// distinguish a persisted rate-limit circuit from concurrency pressure or
// another transient scheduler miss.
//
// Safe to call on the error path: returns {true,true} on any internal failure
// or when the inputs preclude meaningful diagnosis (empty model, etc.), so
// callers stay on the 503 fallback branch.
func (s *GatewayService) DiagnoseModelAvailabilityForPlatform(
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
		// No model specified — cannot decide model_not_found. Caller falls back to 503.
		return ModelAvailabilityDiagnosis{HasAccountsInPool: true, HasModelSupport: true}
	}
	if strings.TrimSpace(platform) == "" {
		// Without a platform we cannot scope the lookup; bail out to the
		// 503 branch rather than make an unscoped scan.
		return ModelAvailabilityDiagnosis{HasAccountsInPool: true, HasModelSupport: true}
	}

	accounts, err := s.listAccountsForNoAccountDiagnosis(ctx, groupID, platform)
	if err != nil {
		// Conservative fallback: pretend everything is fine so the caller
		// returns 503 (we don't want to flip to 404 just because a lookup
		// hiccup'd).
		return ModelAvailabilityDiagnosis{HasAccountsInPool: true, HasModelSupport: true}
	}

	diag := ModelAvailabilityDiagnosis{}
	matchingModelAccounts := 0
	rateLimitedMatchingAccounts := 0
	now := time.Now()
	for i := range accounts {
		diag.HasAccountsInPool = true
		if s.isModelSupportedByAccountWithContext(ctx, &accounts[i], requestedModel) {
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

func (s *GatewayService) listAccountsForNoAccountDiagnosis(ctx context.Context, groupID *int64, platform string) ([]Account, error) {
	if s == nil || s.accountRepo == nil {
		return nil, nil
	}

	groupFilter := AccountListGroupUngrouped
	if s.cfg != nil && s.cfg.RunMode == config.RunModeSimple {
		groupFilter = 0
	} else if groupID != nil {
		groupFilter = *groupID
	}

	listPlatform := func(candidatePlatform string) ([]Account, error) {
		return s.accountRepo.ListAllWithFilters(ctx, candidatePlatform, "", "", "", groupFilter, "")
	}

	accounts, err := listPlatform(platform)
	if err != nil {
		return nil, err
	}
	if platform != PlatformAnthropic && platform != PlatformGemini {
		return accounts, nil
	}

	mixedAccounts, err := listPlatform(PlatformAntigravity)
	if err != nil {
		return nil, err
	}
	for i := range mixedAccounts {
		if mixedAccounts[i].IsMixedSchedulingEnabled() {
			accounts = append(accounts, mixedAccounts[i])
		}
	}
	return accounts, nil
}
