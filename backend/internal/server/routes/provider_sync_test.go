package routes

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/config"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
)

func TestProviderSyncAuth(t *testing.T) {
	gin.SetMode(gin.TestMode)
	tests := []struct {
		name, remote, token string
		want                int
	}{
		{name: "private valid", remote: "172.18.0.1:1234", token: "sync-secret", want: http.StatusNoContent},
		{name: "private invalid token", remote: "172.18.0.1:1234", token: "wrong", want: http.StatusUnauthorized},
		{name: "public source denied", remote: "203.0.113.4:1234", token: "sync-secret", want: http.StatusUnauthorized},
		{name: "empty configured token fails closed", remote: "127.0.0.1:1234", token: "", want: http.StatusUnauthorized},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := gin.New()
			cfg := &config.Config{}
			if tt.name != "empty configured token fails closed" {
				cfg.ProviderSync.Token = "sync-secret"
			}
			r.Use(providerSyncAuth(cfg))
			r.POST("/sync", func(c *gin.Context) { c.Status(http.StatusNoContent) })
			req := httptest.NewRequest(http.MethodPost, "/sync", nil)
			req.RemoteAddr = tt.remote
			req.Header.Set("X-Provider-Sync-Key", tt.token)
			w := httptest.NewRecorder()
			r.ServeHTTP(w, req)
			require.Equal(t, tt.want, w.Code)
		})
	}
}
