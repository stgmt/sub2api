package main

import (
	"testing"
	"time"
)

func TestServerShutdownTimeout(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want time.Duration
	}{
		{name: "default", want: 85 * time.Second},
		{name: "configured duration", raw: "2m30s", want: 150 * time.Second},
		{name: "whitespace", raw: " 45s ", want: 45 * time.Second},
		{name: "invalid falls back", raw: "not-a-duration", want: 85 * time.Second},
		{name: "zero falls back", raw: "0s", want: 85 * time.Second},
		{name: "negative falls back", raw: "-1s", want: 85 * time.Second},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := serverShutdownTimeout(func(key string) string {
				if key != serverShutdownTimeoutEnv {
					t.Fatalf("unexpected environment key: %s", key)
				}
				return tt.raw
			})
			if got != tt.want {
				t.Fatalf("serverShutdownTimeout() = %s, want %s", got, tt.want)
			}
		})
	}
}
