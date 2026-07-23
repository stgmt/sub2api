package service

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"log/slog"
	"os"
	"strings"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/pkg/openai"
)

const defaultOpenAICodexAuthFilePath = "/app/data/codex-auth.json"

type codexAuthFile struct {
	Tokens struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
		IDToken      string `json:"id_token"`
		AccountID    string `json:"account_id"`
	} `json:"tokens"`
	LastRefresh string `json:"last_refresh"`

	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	IDToken      string `json:"id_token"`
	AccountID    string `json:"account_id"`
}

type jwtExpiryClaims struct {
	Exp int64 `json:"exp"`
}

func (s *TokenRefreshService) tryRecoverOpenAIOAuthFromCodexAuthFile(ctx context.Context, account *Account, cause error) bool {
	if s == nil {
		return false
	}
	return recoverOpenAIOAuthFromCodexAuthFile(ctx, s.accountRepo, s.cacheInvalidator, account, cause)
}

func recoverOpenAIOAuthFromCodexAuthFile(ctx context.Context, repo AccountRepository, invalidator TokenCacheInvalidator, account *Account, cause error) bool {
	if repo == nil || account == nil || !account.IsOpenAIOAuth() || !isOpenAIRefreshCredentialFailure(cause) {
		return false
	}
	path := resolveOpenAICodexAuthFilePath()
	auth, err := readCodexAuthFile(path)
	if err != nil {
		slog.Warn("token_refresh.openai_codex_auth_file_recovery_skipped",
			"account_id", account.ID,
			"path", path,
			"reason", err.Error(),
		)
		return false
	}

	accessToken := strings.TrimSpace(auth.Tokens.AccessToken)
	refreshToken := strings.TrimSpace(auth.Tokens.RefreshToken)
	idToken := strings.TrimSpace(auth.Tokens.IDToken)
	accountID := strings.TrimSpace(auth.Tokens.AccountID)
	if accessToken == "" {
		accessToken = strings.TrimSpace(auth.AccessToken)
	}
	if refreshToken == "" {
		refreshToken = strings.TrimSpace(auth.RefreshToken)
	}
	if idToken == "" {
		idToken = strings.TrimSpace(auth.IDToken)
	}
	if accountID == "" {
		accountID = strings.TrimSpace(auth.AccountID)
	}

	if accessToken == "" || refreshToken == "" {
		slog.Warn("token_refresh.openai_codex_auth_file_recovery_skipped",
			"account_id", account.ID,
			"path", path,
			"reason", "missing access_token or refresh_token",
		)
		return false
	}
	if refreshToken == strings.TrimSpace(account.GetOpenAIRefreshToken()) {
		slog.Info("token_refresh.openai_codex_auth_file_recovery_skipped",
			"account_id", account.ID,
			"path", path,
			"reason", "auth file refresh token already matches stored credentials",
		)
		return false
	}

	expiresAt, hasExpiry, expired := jwtExpiresAt(accessToken, time.Now().UTC())
	if expired {
		slog.Warn("token_refresh.openai_codex_auth_file_recovery_skipped",
			"account_id", account.ID,
			"path", path,
			"reason", "access token in auth file is expired",
		)
		return false
	}

	credentials := shallowCopyMap(account.Credentials)
	credentials["access_token"] = accessToken
	credentials["refresh_token"] = refreshToken
	credentials["client_id"] = openai.ClientID
	credentials["_token_version"] = time.Now().UnixMilli()
	credentials["codex_auth_file_imported_at"] = time.Now().UTC().Format(time.RFC3339)
	if idToken != "" {
		credentials["id_token"] = idToken
	}
	if accountID != "" {
		credentials["chatgpt_account_id"] = accountID
	}
	if hasExpiry {
		credentials["expires_at"] = expiresAt.Format(time.RFC3339)
	}

	if err := persistAccountCredentials(ctx, repo, account, credentials); err != nil {
		slog.Error("token_refresh.openai_codex_auth_file_recovery_persist_failed",
			"account_id", account.ID,
			"path", path,
			"error", err,
		)
		return false
	}
	if invalidator != nil {
		if err := invalidator.InvalidateToken(ctx, account); err != nil {
			slog.Warn("token_refresh.openai_codex_auth_file_recovery_invalidate_failed",
				"account_id", account.ID,
				"error", err,
			)
		}
	}
	if err := repo.ClearError(ctx, account.ID); err != nil {
		slog.Warn("token_refresh.openai_codex_auth_file_recovery_clear_error_failed",
			"account_id", account.ID,
			"error", err,
		)
	}
	if err := repo.ClearTempUnschedulable(ctx, account.ID); err != nil {
		slog.Warn("token_refresh.openai_codex_auth_file_recovery_clear_temp_failed",
			"account_id", account.ID,
			"error", err,
		)
	}
	if err := repo.SetSchedulable(ctx, account.ID, true); err != nil {
		slog.Warn("token_refresh.openai_codex_auth_file_recovery_set_schedulable_failed",
			"account_id", account.ID,
			"error", err,
		)
	}

	slog.Info("token_refresh.openai_codex_auth_file_recovered",
		"account_id", account.ID,
		"path", path,
		"has_expiry", hasExpiry,
	)
	return true
}

func resolveOpenAICodexAuthFilePath() string {
	for _, key := range []string{"SUB2API_OPENAI_CODEX_AUTH_FILE", "CODEX_AUTH_FILE"} {
		if value := strings.TrimSpace(os.Getenv(key)); value != "" {
			return value
		}
	}
	return defaultOpenAICodexAuthFilePath
}

func readCodexAuthFile(path string) (*codexAuthFile, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var auth codexAuthFile
	if err := json.Unmarshal(body, &auth); err != nil {
		return nil, err
	}
	return &auth, nil
}

func isOpenAIRefreshCredentialFailure(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	if !strings.Contains(msg, "openai_oauth_token_refresh_failed") {
		return false
	}
	for _, needle := range []string{
		"invalid_grant",
		"invalid_refresh_token",
		"refresh_token_reused",
		"refresh_token_invalidated",
		"token_expired",
		"app_session_terminated",
	} {
		if strings.Contains(msg, needle) {
			return true
		}
	}
	return false
}

func jwtExpiresAt(token string, now time.Time) (time.Time, bool, bool) {
	parts := strings.Split(token, ".")
	if len(parts) < 2 {
		return time.Time{}, false, false
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return time.Time{}, false, false
	}
	var claims jwtExpiryClaims
	if err := json.Unmarshal(payload, &claims); err != nil || claims.Exp <= 0 {
		return time.Time{}, false, false
	}
	expiresAt := time.Unix(claims.Exp, 0).UTC()
	return expiresAt, true, !expiresAt.After(now.Add(2 * time.Minute))
}
