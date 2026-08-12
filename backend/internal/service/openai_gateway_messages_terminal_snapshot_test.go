package service

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/config"
	"github.com/Wei-Shaw/sub2api/internal/pkg/apicompat"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestOpenAIMessagesAnthropicStreamRecoversDoneSnapshotWithoutDelta(t *testing.T) {
	gin.SetMode(gin.TestMode)
	svc := &OpenAIGatewayService{cfg: &config.Config{Gateway: config.GatewayConfig{MaxLineSize: defaultMaxLineSize}}}

	rec := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(rec)
	c.Request = httptest.NewRequest(http.MethodPost, "/v1/messages", nil)

	resp := &http.Response{
		StatusCode: http.StatusOK,
		Header:     http.Header{"X-Request-Id": []string{"rid-done-snapshot"}},
		Body: io.NopCloser(strings.NewReader(strings.Join([]string{
			"event: response.created",
			`data: {"type":"response.created","response":{"id":"resp_snapshot","model":"gpt-5.6-luna","status":"in_progress"}}`,
			"",
			"event: response.output_item.added",
			`data: {"type":"response.output_item.added","output_index":0,"item":{"id":"msg_snapshot","type":"message","role":"assistant","content":[]}}`,
			"",
			"event: response.content_part.added",
			`data: {"type":"response.content_part.added","item_id":"msg_snapshot","output_index":0,"content_index":0,"part":{"type":"output_text","text":""}}`,
			"",
			"event: response.output_text.done",
			`data: {"type":"response.output_text.done","item_id":"msg_snapshot","output_index":0,"content_index":0,"text":"Recovered answer"}`,
			"",
			"event: response.content_part.done",
			`data: {"type":"response.content_part.done","item_id":"msg_snapshot","output_index":0,"content_index":0,"part":{"type":"output_text","text":"Recovered answer"}}`,
			"",
			"event: response.output_item.done",
			`data: {"type":"response.output_item.done","output_index":0,"item":{"id":"msg_snapshot","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Recovered answer"}]}}`,
			"",
			"event: response.completed",
			`data: {"type":"response.completed","response":{"id":"resp_snapshot","model":"gpt-5.6-luna","status":"completed","output":[],"usage":{"input_tokens":305454,"output_tokens":860,"total_tokens":306314}}}`,
			"",
		}, "\n"))),
	}

	result, err := svc.handleAnthropicStreamingResponse(resp, c, &Account{ID: 1, Platform: PlatformOpenAI, Name: "acc"}, "gpt-5.6-luna", "gpt-5.6-luna", "gpt-5.6-luna", time.Now(), 305454)

	require.NoError(t, err)
	require.NotNil(t, result)
	assert.True(t, result.ClientOutputStarted)
	body := rec.Body.String()
	assert.Equal(t, 1, strings.Count(body, "Recovered answer"))
	assert.Contains(t, body, "event: message_start")
	assert.Contains(t, body, "event: content_block_delta")
	assert.Contains(t, body, "event: message_stop")
}

func TestOpenAIMessagesStreamDiagnosticCountsTerminalSnapshotBytes(t *testing.T) {
	diag := newOpenAIMessagesStreamDiagnostic(10)
	diag.Record(apicompat.ResponsesStreamEvent{
		Type: "response.output_text.done",
		Text: "done",
	})
	diag.Record(apicompat.ResponsesStreamEvent{
		Type: "response.content_part.done",
		Part: &apicompat.ResponsesContentPart{Type: "output_text", Text: "part"},
	})
	diag.Record(apicompat.ResponsesStreamEvent{
		Type: "response.output_item.done",
		Item: &apicompat.ResponsesOutput{
			Type: "message",
			Content: []apicompat.ResponsesContentPart{{
				Type: "output_text",
				Text: "item",
			}},
		},
	})

	assert.Equal(t, 4, diag.OutputTextDoneBytes)
	assert.Equal(t, 4, diag.ContentPartDoneTextBytes)
	assert.Equal(t, 4, diag.OutputItemDoneTextBytes)
}
