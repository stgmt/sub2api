package handler

import (
	"bytes"
	"context"
	"net/http"
	"strings"

	"github.com/Wei-Shaw/sub2api/internal/pkg/ctxkey"
	pkghttputil "github.com/Wei-Shaw/sub2api/internal/pkg/httputil"
	middleware2 "github.com/Wei-Shaw/sub2api/internal/server/middleware"
	"github.com/Wei-Shaw/sub2api/internal/service"

	"github.com/gin-gonic/gin"
	"github.com/tidwall/gjson"
)

type claudeCodeMessagesRoute int

const (
	claudeCodeMessagesRouteNative claudeCodeMessagesRoute = iota
	claudeCodeMessagesRouteOpenAI
	claudeCodeMessagesRouteAnthropic
)

// MultiproviderMessages keeps one Claude-compatible endpoint usable for mixed
// groups. GPT/Codex requests stay on the OpenAI bridge, while Anthropic/Qwen
// family requests use Anthropic-compatible passthrough accounts in the same
// group instead of being silently remapped by OpenAI dispatch aliases.
func (h *Handlers) MultiproviderMessages(c *gin.Context) {
	body, err := pkghttputil.ReadRequestBodyWithPrealloc(c.Request)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"type": "error",
			"error": gin.H{
				"type":    "invalid_request_error",
				"message": "Failed to read request body: " + err.Error(),
			},
		})
		return
	}
	resetGinRequestBody(c, body)

	model := strings.TrimSpace(gjson.GetBytes(body, "model").String())
	groupPlatform := ""
	if apiKey, _ := middleware2.GetAPIKeyFromContext(c); apiKey != nil && apiKey.Group != nil {
		groupPlatform = apiKey.Group.Platform
	}

	switch classifyClaudeCodeMessagesRoute(model, groupPlatform) {
	case claudeCodeMessagesRouteOpenAI:
		h.OpenAIGateway.Messages(c)
	case claudeCodeMessagesRouteAnthropic:
		forceGinPlatform(c, service.PlatformAnthropic)
		h.Gateway.Messages(c)
	default:
		h.Gateway.Messages(c)
	}
}

// MultiproviderCountTokens mirrors MultiproviderMessages for Claude Code's
// /v1/messages/count_tokens preflight. Without this guard, mixed OpenAI groups
// can send Qwen/Claude-family token-counting probes to the Codex account before
// the real /v1/messages request is routed correctly.
func (h *Handlers) MultiproviderCountTokens(c *gin.Context) {
	body, err := pkghttputil.ReadRequestBodyWithPrealloc(c.Request)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"type": "error",
			"error": gin.H{
				"type":    "invalid_request_error",
				"message": "Failed to read request body: " + err.Error(),
			},
		})
		return
	}
	resetGinRequestBody(c, body)

	model := strings.TrimSpace(gjson.GetBytes(body, "model").String())
	groupPlatform := ""
	if apiKey, _ := middleware2.GetAPIKeyFromContext(c); apiKey != nil && apiKey.Group != nil {
		groupPlatform = apiKey.Group.Platform
	}

	switch classifyClaudeCodeCountTokensRoute(model, groupPlatform) {
	case claudeCodeMessagesRouteOpenAI:
		h.OpenAIGateway.CountTokens(c)
	case claudeCodeMessagesRouteAnthropic:
		if isAlibabaTokenPlanAnthropicModel(model) {
			writeLocalCountTokensEstimate(c, body)
			return
		}
		forceGinPlatform(c, service.PlatformAnthropic)
		h.Gateway.CountTokens(c)
	default:
		if strings.EqualFold(strings.TrimSpace(groupPlatform), service.PlatformGrok) {
			writeCountTokensUnsupported(c)
			return
		}
		h.Gateway.CountTokens(c)
	}
}

func resetGinRequestBody(c *gin.Context, body []byte) {
	c.Request.Header.Del("Content-Encoding")
	c.Request.Body = http.NoBody
	c.Request.ContentLength = int64(len(body))
	if len(body) > 0 {
		c.Request.Body = ioNopCloser{Reader: bytes.NewReader(body)}
	}
}

func forceGinPlatform(c *gin.Context, platform string) {
	ctx := context.WithValue(c.Request.Context(), ctxkey.ForcePlatform, platform)
	c.Request = c.Request.WithContext(ctx)
	c.Set(string(middleware2.ContextKeyForcePlatform), platform)
}

func classifyClaudeCodeMessagesRoute(model, groupPlatform string) claudeCodeMessagesRoute {
	model = strings.ToLower(strings.TrimSpace(model))
	groupPlatform = strings.ToLower(strings.TrimSpace(groupPlatform))
	if model != "" {
		switch {
		case isClaudeFamilyModel(model), isAlibabaTokenPlanAnthropicModel(model):
			return claudeCodeMessagesRouteAnthropic
		case isOpenAICodexFamilyModel(model):
			return claudeCodeMessagesRouteOpenAI
		}
	}
	switch groupPlatform {
	case service.PlatformOpenAI, service.PlatformGrok:
		return claudeCodeMessagesRouteOpenAI
	default:
		return claudeCodeMessagesRouteNative
	}
}

func classifyClaudeCodeCountTokensRoute(model, groupPlatform string) claudeCodeMessagesRoute {
	model = strings.ToLower(strings.TrimSpace(model))
	groupPlatform = strings.ToLower(strings.TrimSpace(groupPlatform))
	if model != "" {
		switch {
		case isClaudeFamilyModel(model), isAlibabaTokenPlanAnthropicModel(model):
			return claudeCodeMessagesRouteAnthropic
		case isOpenAICodexFamilyModel(model):
			return claudeCodeMessagesRouteOpenAI
		}
	}
	switch groupPlatform {
	case service.PlatformOpenAI:
		return claudeCodeMessagesRouteOpenAI
	default:
		return claudeCodeMessagesRouteNative
	}
}

func isClaudeFamilyModel(model string) bool {
	return model == "opus" ||
		model == "sonnet" ||
		model == "haiku" ||
		model == "fable" ||
		strings.HasPrefix(model, "claude-")
}

func isAlibabaTokenPlanAnthropicModel(model string) bool {
	return strings.HasPrefix(model, "qwen") ||
		strings.HasPrefix(model, "qwq") ||
		strings.HasPrefix(model, "glm-") ||
		strings.HasPrefix(model, "deepseek-")
}

func isOpenAICodexFamilyModel(model string) bool {
	return strings.HasPrefix(model, "gpt-") ||
		strings.HasPrefix(model, "chatgpt-") ||
		strings.Contains(model, "codex") ||
		model == "codex" ||
		strings.HasPrefix(model, "o1") ||
		strings.HasPrefix(model, "o3") ||
		strings.HasPrefix(model, "o4")
}

type ioNopCloser struct {
	*bytes.Reader
}

func (c ioNopCloser) Close() error { return nil }

func writeLocalCountTokensEstimate(c *gin.Context, body []byte) {
	estimated := len(body) / 4
	if estimated < 1 {
		estimated = 1
	}
	c.JSON(http.StatusOK, gin.H{"input_tokens": estimated})
}

func writeCountTokensUnsupported(c *gin.Context) {
	service.MarkOpsClientBusinessLimited(c, service.OpsClientBusinessLimitedReasonLocalFeatureGate)
	c.JSON(http.StatusNotFound, gin.H{
		"type": "error",
		"error": gin.H{
			"type":    "not_found_error",
			"message": "Token counting is not supported for this platform",
		},
	})
}
