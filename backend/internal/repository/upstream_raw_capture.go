package repository

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/config"
	"github.com/Wei-Shaw/sub2api/internal/service"
)

type rawUpstreamCaptureStore struct {
	directory       string
	retention       time.Duration
	cleanupInterval time.Duration
}

type rawUpstreamCaptureMetadata struct {
	ID                string     `json:"id"`
	StartedAt         time.Time  `json:"started_at"`
	FinishedAt        *time.Time `json:"finished_at,omitempty"`
	AccountID         int64      `json:"account_id"`
	Profile           string     `json:"profile"`
	Method            string     `json:"method"`
	Scheme            string     `json:"scheme"`
	Host              string     `json:"host"`
	Path              string     `json:"path"`
	StatusCode        int        `json:"status_code"`
	ContentType       string     `json:"content_type,omitempty"`
	ContentEncoding   string     `json:"content_encoding,omitempty"`
	UpstreamRequestID string     `json:"upstream_request_id,omitempty"`
	BodyFile          string     `json:"body_file"`
	BytesCaptured     int64      `json:"bytes_captured"`
	Complete          bool       `json:"complete"`
	ReadError         string     `json:"read_error,omitempty"`
	CaptureError      string     `json:"capture_error,omitempty"`
}

type rawUpstreamCaptureBody struct {
	source       io.ReadCloser
	file         *os.File
	metadataPath string
	metadata     rawUpstreamCaptureMetadata

	mu           sync.Mutex
	closed       bool
	sawEOF       bool
	captureErr   error
	bytesWritten int64
}

func newRawUpstreamCaptureStore(cfg *config.Config) *rawUpstreamCaptureStore {
	if cfg == nil || !cfg.Gateway.UpstreamRawCapture.Enabled {
		return nil
	}
	rawCfg := cfg.Gateway.UpstreamRawCapture
	directory := filepath.Clean(strings.TrimSpace(rawCfg.Directory))
	if directory == "." || directory == "" || rawCfg.RetentionHours <= 0 || rawCfg.CleanupIntervalMinutes <= 0 {
		slog.Error("upstream_raw_capture_invalid_config")
		return nil
	}
	absoluteDirectory, err := filepath.Abs(directory)
	if err != nil || absoluteDirectory == filepath.VolumeName(absoluteDirectory)+string(os.PathSeparator) {
		slog.Error("upstream_raw_capture_unsafe_directory", "directory", directory)
		return nil
	}
	directory = absoluteDirectory
	if err := os.MkdirAll(directory, 0o700); err != nil {
		slog.Error("upstream_raw_capture_directory_failed", "directory", directory, "error", err)
		return nil
	}
	if err := os.Chmod(directory, 0o700); err != nil {
		slog.Warn("upstream_raw_capture_chmod_failed", "directory", directory, "error", err)
	}
	store := &rawUpstreamCaptureStore{
		directory:       directory,
		retention:       time.Duration(rawCfg.RetentionHours) * time.Hour,
		cleanupInterval: time.Duration(rawCfg.CleanupIntervalMinutes) * time.Minute,
	}
	store.cleanupExpired(time.Now())
	go store.cleanupLoop()
	return store
}

func (s *rawUpstreamCaptureStore) cleanupLoop() {
	ticker := time.NewTicker(s.cleanupInterval)
	defer ticker.Stop()
	for now := range ticker.C {
		s.cleanupExpired(now)
	}
}

func (s *rawUpstreamCaptureStore) cleanupExpired(now time.Time) {
	if s == nil {
		return
	}
	cutoff := now.Add(-s.retention)
	entries, err := os.ReadDir(s.directory)
	if err != nil {
		return
	}
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		if _, parseErr := time.Parse("2006-01-02", entry.Name()); parseErr != nil {
			continue
		}
		dayDir := filepath.Join(s.directory, entry.Name())
		files, readErr := os.ReadDir(dayDir)
		if readErr != nil {
			continue
		}
		for _, file := range files {
			if file.IsDir() || !isRawUpstreamCaptureFile(file.Name()) {
				continue
			}
			info, infoErr := file.Info()
			if infoErr != nil || !info.ModTime().Before(cutoff) {
				continue
			}
			path := filepath.Join(dayDir, file.Name())
			if removeErr := os.Remove(path); removeErr != nil && !os.IsNotExist(removeErr) {
				slog.Warn("upstream_raw_capture_cleanup_failed", "path", path, "error", removeErr)
			}
		}
		_ = os.Remove(dayDir)
	}
}

func isRawUpstreamCaptureFile(name string) bool {
	return strings.HasSuffix(name, ".sse") ||
		strings.HasSuffix(name, ".json") ||
		strings.HasSuffix(name, ".body") ||
		strings.HasSuffix(name, ".meta.json") ||
		strings.HasSuffix(name, ".meta.json.tmp")
}

func (s *rawUpstreamCaptureStore) wrap(
	req *http.Request,
	resp *http.Response,
	accountID int64,
	profile service.HTTPUpstreamProfile,
) io.ReadCloser {
	if s == nil || req == nil || req.URL == nil || resp == nil || resp.Body == nil {
		if resp == nil {
			return nil
		}
		return resp.Body
	}
	startedAt := time.Now().UTC()
	id := rawUpstreamCaptureID(startedAt)
	dayDir := filepath.Join(s.directory, startedAt.Format("2006-01-02"))
	if err := os.MkdirAll(dayDir, 0o700); err != nil {
		slog.Warn("upstream_raw_capture_create_day_failed", "directory", dayDir, "error", err)
		return resp.Body
	}
	_ = os.Chmod(dayDir, 0o700)

	extension := rawUpstreamCaptureExtension(resp.Header.Get("Content-Type"))
	bodyName := id + extension
	bodyPath := filepath.Join(dayDir, bodyName)
	file, err := os.OpenFile(bodyPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		slog.Warn("upstream_raw_capture_create_body_failed", "path", bodyPath, "error", err)
		return resp.Body
	}

	metadataPath := filepath.Join(dayDir, id+".meta.json")
	metadata := rawUpstreamCaptureMetadata{
		ID:                id,
		StartedAt:         startedAt,
		AccountID:         accountID,
		Profile:           string(profile),
		Method:            req.Method,
		Scheme:            req.URL.Scheme,
		Host:              req.URL.Host,
		Path:              req.URL.EscapedPath(),
		StatusCode:        resp.StatusCode,
		ContentType:       resp.Header.Get("Content-Type"),
		ContentEncoding:   resp.Header.Get("Content-Encoding"),
		UpstreamRequestID: firstNonEmptyHeader(resp.Header, "x-request-id", "request-id", "x-correlation-id", "cf-ray"),
		BodyFile:          bodyName,
	}
	if err := writeRawUpstreamCaptureMetadata(metadataPath, metadata); err != nil {
		slog.Warn("upstream_raw_capture_create_metadata_failed", "path", metadataPath, "error", err)
	}
	return &rawUpstreamCaptureBody{
		source:       resp.Body,
		file:         file,
		metadataPath: metadataPath,
		metadata:     metadata,
	}
}

func (b *rawUpstreamCaptureBody) Read(p []byte) (int, error) {
	n, readErr := b.source.Read(p)
	b.mu.Lock()
	if n > 0 && b.captureErr == nil {
		written, writeErr := b.file.Write(p[:n])
		b.bytesWritten += int64(written)
		if writeErr != nil {
			b.captureErr = writeErr
		} else if written != n {
			b.captureErr = io.ErrShortWrite
		}
	}
	if readErr == io.EOF {
		b.sawEOF = true
	} else if readErr != nil {
		b.metadata.ReadError = readErr.Error()
	}
	b.mu.Unlock()
	return n, readErr
}

func (b *rawUpstreamCaptureBody) Close() error {
	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		return nil
	}
	b.closed = true
	b.mu.Unlock()

	sourceErr := b.source.Close()
	b.mu.Lock()
	fileErr := b.file.Close()
	finishedAt := time.Now().UTC()
	b.metadata.FinishedAt = &finishedAt
	b.metadata.BytesCaptured = b.bytesWritten
	b.metadata.Complete = b.sawEOF && b.metadata.ReadError == ""
	if b.captureErr != nil {
		b.metadata.CaptureError = b.captureErr.Error()
	} else if fileErr != nil {
		b.metadata.CaptureError = fileErr.Error()
	}
	metadata := b.metadata
	b.mu.Unlock()
	if err := writeRawUpstreamCaptureMetadata(b.metadataPath, metadata); err != nil {
		slog.Warn("upstream_raw_capture_finalize_metadata_failed", "path", b.metadataPath, "error", err)
	}
	return sourceErr
}

func writeRawUpstreamCaptureMetadata(path string, metadata rawUpstreamCaptureMetadata) error {
	data, err := json.MarshalIndent(metadata, "", "  ")
	if err != nil {
		return err
	}
	tempPath := path + ".tmp"
	if err := os.WriteFile(tempPath, append(data, '\n'), 0o600); err != nil {
		return err
	}
	if err := os.Chmod(tempPath, 0o600); err != nil {
		_ = os.Remove(tempPath)
		return err
	}
	if err := os.Rename(tempPath, path); err != nil {
		_ = os.Remove(tempPath)
		return err
	}
	return nil
}

func rawUpstreamCaptureID(now time.Time) string {
	random := make([]byte, 8)
	if _, err := rand.Read(random); err != nil {
		return fmt.Sprintf("%s-%d", now.Format("20060102T150405.000000000Z"), now.UnixNano())
	}
	return now.Format("20060102T150405.000000000Z") + "-" + hex.EncodeToString(random)
}

func rawUpstreamCaptureExtension(contentType string) string {
	lower := strings.ToLower(contentType)
	switch {
	case strings.Contains(lower, "text/event-stream"):
		return ".sse"
	case strings.Contains(lower, "json"):
		return ".json"
	default:
		return ".body"
	}
}

func firstNonEmptyHeader(header http.Header, names ...string) string {
	for _, name := range names {
		if value := strings.TrimSpace(header.Get(name)); value != "" {
			return value
		}
	}
	return ""
}
