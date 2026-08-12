package apicompat

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestResponsesEventToAnthropicEvents_OutputTextDoneRecoversSnapshotWithoutDelta(t *testing.T) {
	state := NewResponsesEventToAnthropicState()
	startResponsesAnthropicMessage(t, state)

	events := ResponsesEventToAnthropicEvents(&ResponsesStreamEvent{
		Type:         "response.output_text.done",
		OutputIndex:  0,
		ContentIndex: 0,
		Text:         "Recovered answer",
	}, state)

	require.Len(t, events, 3)
	assert.Equal(t, "content_block_start", events[0].Type)
	assert.Equal(t, "content_block_delta", events[1].Type)
	require.NotNil(t, events[1].Delta)
	assert.Equal(t, "Recovered answer", events[1].Delta.Text)
	assert.Equal(t, "content_block_stop", events[2].Type)
	assert.Equal(t, len("Recovered answer"), state.RecoveredTextBytes)
	assert.Equal(t, len("Recovered answer"), state.RecoveredTextSources["output_text_done"])
}

func TestResponsesEventToAnthropicEvents_ContentPartDoneRecoversSnapshotWithoutDelta(t *testing.T) {
	state := NewResponsesEventToAnthropicState()
	startResponsesAnthropicMessage(t, state)

	events := ResponsesEventToAnthropicEvents(&ResponsesStreamEvent{
		Type:         "response.content_part.done",
		OutputIndex:  0,
		ContentIndex: 0,
		Part: &ResponsesContentPart{
			Type: "output_text",
			Text: "Recovered part",
		},
	}, state)

	require.Len(t, events, 3)
	require.NotNil(t, events[1].Delta)
	assert.Equal(t, "Recovered part", events[1].Delta.Text)
	assert.Equal(t, len("Recovered part"), state.RecoveredTextSources["content_part_done"])
}

func TestResponsesEventToAnthropicEvents_OutputItemDoneRecoversSnapshotWithoutDelta(t *testing.T) {
	state := NewResponsesEventToAnthropicState()
	startResponsesAnthropicMessage(t, state)

	events := ResponsesEventToAnthropicEvents(&ResponsesStreamEvent{
		Type:        "response.output_item.done",
		OutputIndex: 0,
		Item: &ResponsesOutput{
			Type: "message",
			Content: []ResponsesContentPart{{
				Type: "output_text",
				Text: "Recovered item",
			}},
		},
	}, state)

	require.Len(t, events, 3)
	require.NotNil(t, events[1].Delta)
	assert.Equal(t, "Recovered item", events[1].Delta.Text)
	assert.Equal(t, len("Recovered item"), state.RecoveredTextSources["output_item_done"])
}

func TestResponsesEventToAnthropicEvents_DoneSnapshotAppendsOnlyMissingSuffix(t *testing.T) {
	state := NewResponsesEventToAnthropicState()
	startResponsesAnthropicMessage(t, state)

	events := ResponsesEventToAnthropicEvents(&ResponsesStreamEvent{
		Type:         "response.output_text.delta",
		OutputIndex:  0,
		ContentIndex: 0,
		Delta:        "Hello",
	}, state)
	require.Len(t, events, 2)

	events = ResponsesEventToAnthropicEvents(&ResponsesStreamEvent{
		Type:         "response.output_text.done",
		OutputIndex:  0,
		ContentIndex: 0,
		Text:         "Hello world",
	}, state)

	require.Len(t, events, 2)
	require.NotNil(t, events[0].Delta)
	assert.Equal(t, " world", events[0].Delta.Text)
	assert.Equal(t, "content_block_stop", events[1].Type)
	assert.Equal(t, len(" world"), state.RecoveredTextBytes)

	events = ResponsesEventToAnthropicEvents(&ResponsesStreamEvent{
		Type:         "response.content_part.done",
		OutputIndex:  0,
		ContentIndex: 0,
		Part:         &ResponsesContentPart{Type: "output_text", Text: "Hello world"},
	}, state)
	assert.Empty(t, events, "a later full snapshot must not duplicate already emitted text")
}

func TestResponsesEventToAnthropicEvents_ConflictingSnapshotFailsClosed(t *testing.T) {
	state := NewResponsesEventToAnthropicState()
	startResponsesAnthropicMessage(t, state)

	ResponsesEventToAnthropicEvents(&ResponsesStreamEvent{
		Type:         "response.output_text.delta",
		OutputIndex:  0,
		ContentIndex: 0,
		Delta:        "Hello",
	}, state)

	events := ResponsesEventToAnthropicEvents(&ResponsesStreamEvent{
		Type:         "response.output_text.done",
		OutputIndex:  0,
		ContentIndex: 0,
		Text:         "Goodbye",
	}, state)

	require.Len(t, events, 1)
	assert.Equal(t, "content_block_stop", events[0].Type)
	assert.Equal(t, 1, state.TextSnapshotConflicts)
	assert.Zero(t, state.RecoveredTextBytes)
}

func TestResponsesEventToAnthropicEvents_TerminalSnapshotRecoversTextAfterReasoning(t *testing.T) {
	state := NewResponsesEventToAnthropicState()
	startResponsesAnthropicMessage(t, state)

	ResponsesEventToAnthropicEvents(&ResponsesStreamEvent{
		Type:        "response.output_item.added",
		OutputIndex: 0,
		Item:        &ResponsesOutput{Type: "reasoning"},
	}, state)
	ResponsesEventToAnthropicEvents(&ResponsesStreamEvent{
		Type:        "response.reasoning_summary_text.delta",
		OutputIndex: 0,
		Delta:       "private reasoning",
	}, state)

	events := ResponsesEventToAnthropicEvents(&ResponsesStreamEvent{
		Type: "response.completed",
		Response: &ResponsesResponse{
			ID:     "resp_terminal_recovery",
			Model:  "gpt-5.6-luna",
			Status: "completed",
			Output: []ResponsesOutput{{
				Type: "reasoning",
			}, {
				Type: "message",
				Content: []ResponsesContentPart{{
					Type: "output_text",
					Text: "Terminal answer",
				}},
			}},
			Usage: &ResponsesUsage{InputTokens: 10, OutputTokens: 4},
		},
	}, state)

	require.Len(t, events, 6)
	assert.Equal(t, "content_block_stop", events[0].Type)
	assert.Equal(t, "content_block_start", events[1].Type)
	assert.Equal(t, "content_block_delta", events[2].Type)
	require.NotNil(t, events[2].Delta)
	assert.Equal(t, "Terminal answer", events[2].Delta.Text)
	assert.Equal(t, "content_block_stop", events[3].Type)
	assert.Equal(t, "message_delta", events[4].Type)
	assert.Equal(t, "message_stop", events[5].Type)
	assert.Equal(t, len("Terminal answer"), state.RecoveredTextSources["terminal_output"])
}

func startResponsesAnthropicMessage(t *testing.T, state *ResponsesEventToAnthropicState) {
	t.Helper()
	events := ResponsesEventToAnthropicEvents(&ResponsesStreamEvent{
		Type: "response.created",
		Response: &ResponsesResponse{
			ID:     "resp_snapshot",
			Model:  "gpt-5.6-luna",
			Status: "in_progress",
		},
	}, state)
	require.Len(t, events, 1)
}
