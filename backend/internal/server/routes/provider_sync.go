package routes

import (
	"crypto/subtle"
	"net"
	"net/http"
	"strings"

	"github.com/Wei-Shaw/sub2api/internal/config"
	"github.com/Wei-Shaw/sub2api/internal/handler"
	"github.com/gin-gonic/gin"
)

// RegisterProviderSyncRoutes exposes the single service-owned mutation path
// used by host credential synchronizers. It is not an administrator API.
func RegisterProviderSyncRoutes(v1 *gin.RouterGroup, h *handler.Handlers, cfg *config.Config) {
	group := v1.Group("/provider-sync")
	group.Use(providerSyncAuth(cfg))
	group.POST("/accounts", h.Admin.Account.ProviderSync)
}

func providerSyncAuth(cfg *config.Config) gin.HandlerFunc {
	return func(c *gin.Context) {
		expected := strings.TrimSpace(cfg.ProviderSync.Token)
		provided := strings.TrimSpace(c.GetHeader("X-Provider-Sync-Key"))
		host, _, err := net.SplitHostPort(c.Request.RemoteAddr)
		if err != nil {
			host = c.Request.RemoteAddr
		}
		ip := net.ParseIP(host)
		privateSource := ip != nil && (ip.IsLoopback() || ip.IsPrivate())
		validToken := expected != "" && len(expected) == len(provided) &&
			subtle.ConstantTimeCompare([]byte(expected), []byte(provided)) == 1
		if !privateSource || !validToken {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "provider_sync_unauthorized"})
			return
		}
		c.Next()
	}
}
