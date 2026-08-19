package admin

import (
	"encoding/json"
	"net/http"
	"net/url"
	"reflect"
	"strings"

	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
)

type providerSyncRequest struct {
	Source         string          `json:"source" binding:"required"`
	AccountName    string          `json:"account_name" binding:"required"`
	Platform       string          `json:"platform" binding:"required"`
	AccountType    string          `json:"account_type" binding:"required"`
	Credentials    map[string]any  `json:"credentials" binding:"required"`
	Extra          map[string]any  `json:"extra"`
	GroupName      string          `json:"group_name" binding:"required"`
	GroupPlatform  string          `json:"group_platform" binding:"required"`
	Subscription   string          `json:"subscription_type"`
	RequireOAuth   bool            `json:"require_oauth_only"`
	LegacyModels   json.RawMessage `json:"models_list_config,omitempty"`
	Concurrency    int             `json:"concurrency"`
	Priority       int             `json:"priority"`
	RateMultiplier float64         `json:"rate_multiplier"`
}

// providerSyncCompositeModels is the single service-owned picker contract for
// the Headroom composite group. Host sync clients submit credentials only;
// they cannot replace the shared model catalog with a provider-local subset.
var providerSyncCompositeModels = service.GroupModelsListConfig{
	Enabled:  true,
	Explicit: true,
	Models: []string{
		"gpt-5.6-sol",
		"gpt-5.6",
		"gpt-5.6-luna",
		"grok-4.6",
		"grok-4.5",
		"cline-pass/qwen3.8-max",
		"poolside/laguna-s-2.1:free",
		"cline-pass/kimi-k3",
		"cline-pass/minimax-m3",
		"cline-pass/deepseek-v4-flash",
		"cline-pass/deepseek-v4-pro",
		"deepseek/deepseek-v4-flash",
		"cline-pass/mimo-v2.5",
		"cline-pass/mimo-v2.5-pro",
		"cline-pass/glm-5.3",
	},
}

func providerSyncModelsListConfig() service.GroupModelsListConfig {
	models := providerSyncCompositeModels
	models.Models = append([]string(nil), providerSyncCompositeModels.Models...)
	return models
}

// ProviderSync owns validation, idempotent persistence, group membership and
// scheduler invalidation for host-side subscription credential synchronization.
func (h *AccountHandler) ProviderSync(c *gin.Context) {
	var req providerSyncRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid_provider_sync_request"})
		return
	}
	if err := validateProviderSyncRequest(&req); err != "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": err})
		return
	}
	ctx := c.Request.Context()

	groups, _, err := h.adminService.ListGroups(ctx, 1, 200, req.GroupPlatform, "", req.GroupName, nil, "id", "asc")
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "provider_sync_group_lookup_failed"})
		return
	}
	var group *service.Group
	for i := range groups {
		if groups[i].Name == req.GroupName {
			group = &groups[i]
			break
		}
	}
	groupCreated := false
	groupChanged := false
	models := providerSyncModelsListConfig()
	if group == nil {
		group, err = h.adminService.CreateGroup(ctx, &service.CreateGroupInput{
			Name: req.GroupName, Platform: req.GroupPlatform, SubscriptionType: req.Subscription,
			RateMultiplier: 1, RequireOAuthOnly: req.RequireOAuth, ModelsListConfig: models,
		})
		groupCreated = err == nil
	} else if group.Platform != req.GroupPlatform || group.SubscriptionType != req.Subscription ||
		group.RequireOAuthOnly != req.RequireOAuth || !reflect.DeepEqual(group.ModelsListConfig, models) {
		rate := 1.0
		requireOAuth := req.RequireOAuth
		update := &service.UpdateGroupInput{
			Name: req.GroupName, Platform: req.GroupPlatform, SubscriptionType: req.Subscription,
			Status: service.StatusActive, RateMultiplier: &rate, RequireOAuthOnly: &requireOAuth,
		}
		update.ModelsListConfig = &models
		group, err = h.adminService.UpdateGroup(ctx, group.ID, update)
		groupChanged = err == nil
	}
	if err != nil || group == nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "provider_sync_group_write_failed"})
		return
	}

	accounts, _, err := h.adminService.ListAccounts(ctx, 1, 200, req.Platform, "", "", req.AccountName, 0, "", "id", "asc")
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "provider_sync_account_lookup_failed"})
		return
	}
	var account *service.Account
	for i := range accounts {
		if accounts[i].Name == req.AccountName && accounts[i].Platform == req.Platform {
			account, err = h.adminService.GetAccount(ctx, accounts[i].ID)
			break
		}
	}
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "provider_sync_account_read_failed"})
		return
	}
	accountCreated := false
	credentialsChanged := false
	groupIDs := []int64{group.ID}
	rate := req.RateMultiplier
	if rate == 0 {
		rate = 1
	}
	if account == nil {
		account, err = h.adminService.CreateAccount(ctx, &service.CreateAccountInput{
			Name: req.AccountName, Platform: req.Platform, Type: req.AccountType,
			Credentials: req.Credentials, Extra: req.Extra, Concurrency: req.Concurrency,
			Priority: req.Priority, RateMultiplier: &rate, GroupIDs: groupIDs,
			SkipMixedChannelCheck: true,
		})
		accountCreated = err == nil
		credentialsChanged = accountCreated
	} else {
		merged := providerSyncCredentials(account.Credentials, req.Credentials, req.Source == "grok_build_cli")
		credentialsChanged = !reflect.DeepEqual(account.Credentials, merged)
		concurrency, priority := req.Concurrency, req.Priority
		account, err = h.adminService.UpdateAccount(ctx, account.ID, &service.UpdateAccountInput{
			Name: req.AccountName, Type: req.AccountType, Credentials: merged, Extra: req.Extra,
			Concurrency: &concurrency, Priority: &priority, RateMultiplier: &rate,
			Status: service.StatusActive, GroupIDs: &groupIDs, SkipMixedChannelCheck: true,
		})
		if err == nil {
			account, err = h.adminService.SetAccountSchedulable(ctx, account.ID, true)
		}
	}
	if err != nil || account == nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "provider_sync_account_write_failed"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"data": gin.H{
		"account_id": account.ID, "group_id": group.ID, "account_created": accountCreated,
		"group_created": groupCreated, "group_changed": groupChanged,
		"credentials_changed": credentialsChanged,
		"protocol_mode":       stringValue(req.Extra["openai_responses_mode"]),
	}})
}

func validateProviderSyncRequest(req *providerSyncRequest) string {
	if len(req.LegacyModels) != 0 {
		return "provider_models_service_owned"
	}
	baseURL, _ := req.Credentials["base_url"].(string)
	u, err := url.Parse(strings.TrimSpace(baseURL))
	if err != nil || u.Scheme != "https" {
		return "invalid_provider_endpoint"
	}
	switch req.Source {
	case "cline_pass_cli":
		if req.Platform != service.PlatformOpenAI || req.AccountType != service.AccountTypeAPIKey || u.Hostname() != "api.cline.bot" {
			return "invalid_cline_provider_contract"
		}
	case "grok_build_cli":
		if req.Platform != service.PlatformGrok || req.AccountType != service.AccountTypeOAuth || u.Hostname() != "cli-chat-proxy.grok.com" {
			return "invalid_grok_provider_contract"
		}
	default:
		return "unsupported_provider_sync_source"
	}
	if strings.TrimSpace(req.GroupName) == "" || req.GroupPlatform != service.PlatformOpenAI {
		return "invalid_provider_group"
	}
	if req.Subscription == "" {
		req.Subscription = service.SubscriptionTypeSubscription
	}
	if req.Concurrency <= 0 {
		req.Concurrency = 3
	}
	return ""
}

func providerSyncCredentials(current, incoming map[string]any, preserveServiceRefresh bool) map[string]any {
	merged := make(map[string]any, len(current)+len(incoming))
	for key, value := range current {
		merged[key] = value
	}
	// When the refresh-token owner is unchanged, keep service-refreshed access
	// state. Host metadata and routing fields still converge.
	sameOwner := preserveServiceRefresh && strings.TrimSpace(stringValue(current["refresh_token"])) != "" &&
		stringValue(current["refresh_token"]) == stringValue(incoming["refresh_token"])
	for key, value := range incoming {
		if sameOwner && (key == "access_token" || key == "api_key" || key == "expires_at" || key == "id_token") {
			continue
		}
		merged[key] = value
	}
	return merged
}

func stringValue(v any) string {
	value, _ := v.(string)
	return strings.TrimSpace(value)
}
