package repository

import (
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/stretchr/testify/require"
)

func TestRawUpstreamCaptureStoresExactBodyForEveryProfile(t *testing.T) {
	profiles := []service.HTTPUpstreamProfile{
		service.HTTPUpstreamProfileDefault,
		service.HTTPUpstreamProfileOpenAI,
	}
	for _, profile := range profiles {
		t.Run(string(profile), func(t *testing.T) {
			directory := t.TempDir()
			store := &rawUpstreamCaptureStore{directory: directory, retention: 24 * time.Hour, cleanupInterval: time.Hour}
			payload := "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\ndata: [DONE]\n\n"
			req, err := http.NewRequest(http.MethodPost, "https://provider.example/v1/chat/completions?secret=omitted", nil)
			require.NoError(t, err)
			resp := &http.Response{
				StatusCode: http.StatusOK,
				Header: http.Header{
					"Content-Type": []string{"text/event-stream"},
					"X-Request-Id": []string{"upstream-request"},
				},
				Body: io.NopCloser(strings.NewReader(payload)),
			}

			body := store.wrap(req, resp, 42, profile)
			capturedByClient, err := io.ReadAll(body)
			require.NoError(t, err)
			require.NoError(t, body.Close())
			require.Equal(t, payload, string(capturedByClient))

			bodyFiles, err := filepath.Glob(filepath.Join(directory, "*", "*.sse"))
			require.NoError(t, err)
			require.Len(t, bodyFiles, 1)
			capturedRaw, err := os.ReadFile(bodyFiles[0])
			require.NoError(t, err)
			require.Equal(t, payload, string(capturedRaw))

			metadataFiles, err := filepath.Glob(filepath.Join(directory, "*", "*.meta.json"))
			require.NoError(t, err)
			require.Len(t, metadataFiles, 1)
			metadataBytes, err := os.ReadFile(metadataFiles[0])
			require.NoError(t, err)
			var metadata rawUpstreamCaptureMetadata
			require.NoError(t, json.Unmarshal(metadataBytes, &metadata))
			require.Equal(t, int64(42), metadata.AccountID)
			require.Equal(t, string(profile), metadata.Profile)
			require.Equal(t, "/v1/chat/completions", metadata.Path)
			require.NotContains(t, string(metadataBytes), "secret")
			require.Equal(t, int64(len(payload)), metadata.BytesCaptured)
			require.True(t, metadata.Complete)
			require.Equal(t, "upstream-request", metadata.UpstreamRequestID)
		})
	}
}

func TestRawUpstreamCaptureCleanupRemovesOnlyExpiredFiles(t *testing.T) {
	directory := t.TempDir()
	dayDir := filepath.Join(directory, "2026-01-01")
	require.NoError(t, os.MkdirAll(dayDir, 0o700))
	expired := filepath.Join(dayDir, "expired.sse")
	fresh := filepath.Join(dayDir, "fresh.sse")
	require.NoError(t, os.WriteFile(expired, []byte("old"), 0o600))
	require.NoError(t, os.WriteFile(fresh, []byte("new"), 0o600))
	now := time.Now()
	require.NoError(t, os.Chtimes(expired, now.Add(-25*time.Hour), now.Add(-25*time.Hour)))
	require.NoError(t, os.Chtimes(fresh, now.Add(-23*time.Hour), now.Add(-23*time.Hour)))

	store := &rawUpstreamCaptureStore{directory: directory, retention: 24 * time.Hour, cleanupInterval: time.Hour}
	store.cleanupExpired(now)

	_, err := os.Stat(expired)
	require.True(t, os.IsNotExist(err))
	_, err = os.Stat(fresh)
	require.NoError(t, err)
}

func TestRawUpstreamCaptureMarksEarlyCloseIncomplete(t *testing.T) {
	directory := t.TempDir()
	store := &rawUpstreamCaptureStore{directory: directory, retention: 24 * time.Hour, cleanupInterval: time.Hour}
	req, err := http.NewRequest(http.MethodPost, "https://provider.example/v1/responses", nil)
	require.NoError(t, err)
	resp := &http.Response{StatusCode: http.StatusOK, Header: http.Header{"Content-Type": []string{"application/json"}}, Body: io.NopCloser(strings.NewReader("abcdef"))}
	body := store.wrap(req, resp, 7, service.HTTPUpstreamProfileDefault)
	buffer := make([]byte, 2)
	_, err = body.Read(buffer)
	require.NoError(t, err)
	require.NoError(t, body.Close())

	metadataFiles, err := filepath.Glob(filepath.Join(directory, "*", "*.meta.json"))
	require.NoError(t, err)
	require.Len(t, metadataFiles, 1)
	metadataBytes, err := os.ReadFile(metadataFiles[0])
	require.NoError(t, err)
	var metadata rawUpstreamCaptureMetadata
	require.NoError(t, json.Unmarshal(metadataBytes, &metadata))
	require.False(t, metadata.Complete)
	require.Equal(t, int64(2), metadata.BytesCaptured)
}
