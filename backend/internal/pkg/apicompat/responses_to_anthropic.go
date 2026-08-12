package apicompat

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// ---------------------------------------------------------------------------
// Non-streaming: ResponsesResponse → AnthropicResponse
// ---------------------------------------------------------------------------

// ResponsesToAnthropic converts a Responses API response directly into an
// Anthropic Messages response. Reasoning output items are mapped to thinking
// blocks; function_call items become tool_use blocks.
func ResponsesToAnthropic(resp *ResponsesResponse, model string) *AnthropicResponse {
	out := &AnthropicResponse{
		ID:    resp.ID,
		Type:  "message",
		Role:  "assistant",
		Model: model,
	}

	var blocks []AnthropicContentBlock

	for _, item := range resp.Output {
		switch item.Type {
		case "reasoning":
			summaryText := ""
			for _, s := range item.Summary {
				if s.Type == "summary_text" && s.Text != "" {
					summaryText += s.Text
				}
			}
			if summaryText != "" {
				blocks = append(blocks, AnthropicContentBlock{
					Type:     "thinking",
					Thinking: summaryText,
				})
			}
		case "message":
			for _, part := range item.Content {
				if part.Type == "output_text" && part.Text != "" {
					blocks = append(blocks, AnthropicContentBlock{
						Type: "text",
						Text: part.Text,
					})
				}
			}
		case "function_call":
			blocks = append(blocks, AnthropicContentBlock{
				Type:  "tool_use",
				ID:    fromResponsesCallID(item.CallID),
				Name:  item.Name,
				Input: sanitizeAnthropicToolUseInput(item.Name, item.Arguments),
			})
		case "web_search_call":
			toolUseID := "srvtoolu_" + item.ID
			query := ""
			if item.Action != nil {
				query = item.Action.Query
			}
			inputJSON, _ := json.Marshal(map[string]string{"query": query})
			blocks = append(blocks, AnthropicContentBlock{
				Type:  "server_tool_use",
				ID:    toolUseID,
				Name:  "web_search",
				Input: inputJSON,
			})
			emptyResults, _ := json.Marshal([]struct{}{})
			blocks = append(blocks, AnthropicContentBlock{
				Type:      "web_search_tool_result",
				ToolUseID: toolUseID,
				Content:   emptyResults,
			})
		}
	}

	if len(blocks) == 0 {
		blocks = append(blocks, AnthropicContentBlock{Type: "text", Text: ""})
	}
	out.Content = blocks

	out.StopReason = responsesStatusToAnthropicStopReason(resp.Status, resp.IncompleteDetails, blocks)

	if resp.Usage != nil {
		out.Usage = anthropicUsageFromResponsesUsage(resp.Usage)
	}

	return out
}

func anthropicUsageFromResponsesUsage(usage *ResponsesUsage) AnthropicUsage {
	if usage == nil {
		return AnthropicUsage{}
	}

	cachedTokens := 0
	if usage.InputTokensDetails != nil {
		cachedTokens = usage.InputTokensDetails.CachedTokens
	}

	inputTokens := usage.InputTokens - cachedTokens
	if inputTokens < 0 {
		inputTokens = 0
	}

	return AnthropicUsage{
		InputTokens:          inputTokens,
		OutputTokens:         usage.OutputTokens,
		CacheReadInputTokens: cachedTokens,
	}
}

func responsesStatusToAnthropicStopReason(status string, details *ResponsesIncompleteDetails, blocks []AnthropicContentBlock) string {
	switch status {
	case "incomplete":
		if details != nil && details.Reason == "max_output_tokens" {
			return "max_tokens"
		}
		return "end_turn"
	case "completed":
		if containsAnthropicToolUseBlock(blocks) {
			return "tool_use"
		}
		return "end_turn"
	default:
		return "end_turn"
	}
}

func containsAnthropicToolUseBlock(blocks []AnthropicContentBlock) bool {
	for _, block := range blocks {
		if block.Type == "tool_use" {
			return true
		}
	}
	return false
}

func sanitizeAnthropicToolUseInput(name string, raw string) json.RawMessage {
	if name != "Read" || raw == "" {
		return json.RawMessage(raw)
	}

	var input map[string]json.RawMessage
	if err := json.Unmarshal([]byte(raw), &input); err != nil {
		return json.RawMessage(raw)
	}

	if pages, ok := input["pages"]; !ok || string(pages) != `""` {
		return json.RawMessage(raw)
	}

	delete(input, "pages")
	sanitized, err := json.Marshal(input)
	if err != nil {
		return json.RawMessage(raw)
	}
	return sanitized
}

// ---------------------------------------------------------------------------
// Streaming: ResponsesStreamEvent → []AnthropicStreamEvent (stateful converter)
// ---------------------------------------------------------------------------

// ResponsesEventToAnthropicState tracks state for converting a sequence of
// Responses SSE events directly into Anthropic SSE events.
type responsesTextKey struct {
	OutputIndex  int
	ContentIndex int
}

type responsesTextSnapshot struct {
	Emitted   string
	DeltaText string
	Done      bool
}

type ResponsesEventToAnthropicState struct {
	MessageStartSent bool
	MessageStopSent  bool

	ContentBlockIndex   int
	ContentBlockOpen    bool
	CurrentBlockType    string // "text" | "thinking" | "tool_use"
	CurrentToolName     string
	CurrentToolArgs     string
	CurrentToolHadDelta bool
	HasToolCall         bool
	CurrentTextKey      responsesTextKey
	CurrentTextKeySet   bool
	textSnapshots       map[responsesTextKey]*responsesTextSnapshot

	RecoveredTextBytes    int
	RecoveredTextSources  map[string]int
	TextSnapshotConflicts int

	// OutputIndexToBlockIdx maps Responses output_index → Anthropic content block index.
	OutputIndexToBlockIdx map[int]int

	InputTokens          int
	OutputTokens         int
	CacheReadInputTokens int

	ResponseID string
	Model      string
	Created    int64
}

// NewResponsesEventToAnthropicState returns an initialised stream state.
func NewResponsesEventToAnthropicState() *ResponsesEventToAnthropicState {
	return &ResponsesEventToAnthropicState{
		OutputIndexToBlockIdx: make(map[int]int),
		textSnapshots:         make(map[responsesTextKey]*responsesTextSnapshot),
		RecoveredTextSources:  make(map[string]int),
		Created:               time.Now().Unix(),
	}
}

// ResponsesEventToAnthropicEvents converts a single Responses SSE event into
// zero or more Anthropic SSE events, updating state as it goes.
func ResponsesEventToAnthropicEvents(
	evt *ResponsesStreamEvent,
	state *ResponsesEventToAnthropicState,
) []AnthropicStreamEvent {
	switch evt.Type {
	case "response.created":
		return resToAnthHandleCreated(evt, state)
	case "response.output_item.added":
		return resToAnthHandleOutputItemAdded(evt, state)
	case "response.content_part.added":
		return resToAnthHandleContentPartSnapshot(evt, state, "content_part_added", false)
	case "response.output_text.delta":
		return resToAnthHandleTextDelta(evt, state)
	case "response.output_text.done":
		return resToAnthHandleTextDone(evt, state)
	case "response.content_part.done":
		return resToAnthHandleContentPartSnapshot(evt, state, "content_part_done", true)
	case "response.function_call_arguments.delta",
		// custom/freeform 工具的输入增量与 function_call 参数增量同形。
		"response.custom_tool_call_input.delta":
		return resToAnthHandleFuncArgsDelta(evt, state)
	case "response.function_call_arguments.done":
		return resToAnthHandleFuncArgsDone(evt, state)
	case "response.output_item.done":
		return resToAnthHandleOutputItemDone(evt, state)
	case "response.reasoning_summary_text.delta",
		// 原始推理文本增量，与 reasoning summary 一样映射为 thinking。
		"response.reasoning_text.delta":
		return resToAnthHandleReasoningDelta(evt, state)
	case "response.reasoning_summary_text.done":
		return resToAnthHandleBlockDone(state)
	// response.done 是 Realtime/WS 与项目透传路径使用的终止别名；
	// 普通 Responses HTTP SSE 的公开终止事件仍以 response.completed 为主。
	case "response.completed", "response.done", "response.incomplete", "response.failed":
		return resToAnthHandleCompleted(evt, state)
	default:
		return nil
	}
}

// FinalizeResponsesAnthropicStream emits synthetic termination events if the
// stream ended without a proper completion event.
func FinalizeResponsesAnthropicStream(state *ResponsesEventToAnthropicState) []AnthropicStreamEvent {
	if !state.MessageStartSent || state.MessageStopSent {
		return nil
	}

	var events []AnthropicStreamEvent
	events = append(events, closeCurrentBlock(state)...)

	stopReason := "end_turn"
	if state.HasToolCall {
		stopReason = "tool_use"
	}

	events = append(events,
		AnthropicStreamEvent{
			Type: "message_delta",
			Delta: &AnthropicDelta{
				StopReason: stopReason,
			},
			Usage: &AnthropicUsage{
				InputTokens:          state.InputTokens,
				OutputTokens:         state.OutputTokens,
				CacheReadInputTokens: state.CacheReadInputTokens,
			},
		},
		AnthropicStreamEvent{Type: "message_stop"},
	)
	state.MessageStopSent = true
	return events
}

// ResponsesAnthropicEventToSSE formats an AnthropicStreamEvent as an SSE line pair.
func ResponsesAnthropicEventToSSE(evt AnthropicStreamEvent) (string, error) {
	data, err := json.Marshal(evt)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("event: %s\ndata: %s\n\n", evt.Type, data), nil
}

// --- internal handlers ---

func resToAnthHandleCreated(evt *ResponsesStreamEvent, state *ResponsesEventToAnthropicState) []AnthropicStreamEvent {
	if evt.Response != nil {
		state.ResponseID = evt.Response.ID
		// Only use upstream model if no override was set (e.g. originalModel)
		if state.Model == "" {
			state.Model = evt.Response.Model
		}
	}

	if state.MessageStartSent {
		return nil
	}
	state.MessageStartSent = true

	return []AnthropicStreamEvent{{
		Type: "message_start",
		Message: &AnthropicResponse{
			ID:      state.ResponseID,
			Type:    "message",
			Role:    "assistant",
			Content: []AnthropicContentBlock{},
			Model:   state.Model,
			Usage: AnthropicUsage{
				InputTokens:  state.InputTokens,
				OutputTokens: 0,
			},
		},
	}}
}

func resToAnthHandleOutputItemAdded(evt *ResponsesStreamEvent, state *ResponsesEventToAnthropicState) []AnthropicStreamEvent {
	if evt.Item == nil {
		return nil
	}

	switch evt.Item.Type {
	// function_call 与 custom_tool_call（custom/freeform 工具，如新版 apply_patch）
	// 同样映射为 Anthropic 的 tool_use 块。
	case "function_call", "custom_tool_call":
		var events []AnthropicStreamEvent
		events = append(events, closeCurrentBlock(state)...)

		idx := state.ContentBlockIndex
		state.OutputIndexToBlockIdx[evt.OutputIndex] = idx
		state.ContentBlockOpen = true
		state.CurrentBlockType = "tool_use"
		state.CurrentToolName = evt.Item.Name
		state.CurrentToolArgs = ""
		state.CurrentToolHadDelta = false
		state.HasToolCall = true

		events = append(events, AnthropicStreamEvent{
			Type:  "content_block_start",
			Index: &idx,
			ContentBlock: &AnthropicContentBlock{
				Type:  "tool_use",
				ID:    fromResponsesCallID(evt.Item.CallID),
				Name:  evt.Item.Name,
				Input: json.RawMessage("{}"),
			},
		})
		return events

	case "reasoning":
		var events []AnthropicStreamEvent
		events = append(events, closeCurrentBlock(state)...)

		idx := state.ContentBlockIndex
		state.OutputIndexToBlockIdx[evt.OutputIndex] = idx
		state.ContentBlockOpen = true
		state.CurrentBlockType = "thinking"

		events = append(events, AnthropicStreamEvent{
			Type:  "content_block_start",
			Index: &idx,
			ContentBlock: &AnthropicContentBlock{
				Type:     "thinking",
				Thinking: "",
			},
		})
		return events

	case "message":
		return nil
	}

	return nil
}

func resToAnthHandleTextDelta(evt *ResponsesStreamEvent, state *ResponsesEventToAnthropicState) []AnthropicStreamEvent {
	if evt.Delta == "" {
		return nil
	}

	key := responsesTextKey{OutputIndex: evt.OutputIndex, ContentIndex: evt.ContentIndex}
	snapshot := responsesTextSnapshotFor(state, key)
	snapshot.DeltaText += evt.Delta

	switch {
	case snapshot.Emitted == "":
		return emitResponsesText(state, key, snapshot, snapshot.DeltaText, false, "")
	case strings.HasPrefix(snapshot.Emitted, snapshot.DeltaText):
		return nil
	case strings.HasPrefix(snapshot.DeltaText, snapshot.Emitted):
		return emitResponsesText(state, key, snapshot, snapshot.DeltaText[len(snapshot.Emitted):], false, "")
	default:
		state.TextSnapshotConflicts++
		return nil
	}
}

func resToAnthHandleTextDone(evt *ResponsesStreamEvent, state *ResponsesEventToAnthropicState) []AnthropicStreamEvent {
	key := responsesTextKey{OutputIndex: evt.OutputIndex, ContentIndex: evt.ContentIndex}
	events := reconcileResponsesTextSnapshot(state, key, evt.Text, "output_text_done")
	responsesTextSnapshotFor(state, key).Done = true
	return append(events, closeResponsesTextBlock(state, key)...)
}

func resToAnthHandleContentPartSnapshot(evt *ResponsesStreamEvent, state *ResponsesEventToAnthropicState, source string, done bool) []AnthropicStreamEvent {
	if evt.Part == nil || evt.Part.Type != "output_text" {
		return nil
	}
	key := responsesTextKey{OutputIndex: evt.OutputIndex, ContentIndex: evt.ContentIndex}
	events := reconcileResponsesTextSnapshot(state, key, evt.Part.Text, source)
	if done {
		responsesTextSnapshotFor(state, key).Done = true
		events = append(events, closeResponsesTextBlock(state, key)...)
	}
	return events
}

func responsesTextSnapshotFor(state *ResponsesEventToAnthropicState, key responsesTextKey) *responsesTextSnapshot {
	if state.textSnapshots == nil {
		state.textSnapshots = make(map[responsesTextKey]*responsesTextSnapshot)
	}
	snapshot := state.textSnapshots[key]
	if snapshot == nil {
		snapshot = &responsesTextSnapshot{}
		state.textSnapshots[key] = snapshot
	}
	return snapshot
}

func reconcileResponsesTextSnapshot(state *ResponsesEventToAnthropicState, key responsesTextKey, text, source string) []AnthropicStreamEvent {
	if text == "" {
		return nil
	}
	snapshot := responsesTextSnapshotFor(state, key)
	switch {
	case snapshot.Emitted == "":
		return emitResponsesText(state, key, snapshot, text, true, source)
	case strings.HasPrefix(text, snapshot.Emitted):
		return emitResponsesText(state, key, snapshot, text[len(snapshot.Emitted):], true, source)
	case strings.HasPrefix(snapshot.Emitted, text):
		return nil
	default:
		state.TextSnapshotConflicts++
		return nil
	}
}

func emitResponsesText(state *ResponsesEventToAnthropicState, key responsesTextKey, snapshot *responsesTextSnapshot, text string, recovered bool, source string) []AnthropicStreamEvent {
	if text == "" {
		return nil
	}
	events := ensureResponsesTextBlock(state, key)
	idx := state.ContentBlockIndex
	events = append(events, AnthropicStreamEvent{
		Type:  "content_block_delta",
		Index: &idx,
		Delta: &AnthropicDelta{
			Type: "text_delta",
			Text: text,
		},
	})
	snapshot.Emitted += text
	if recovered {
		if state.RecoveredTextSources == nil {
			state.RecoveredTextSources = make(map[string]int)
		}
		state.RecoveredTextBytes += len(text)
		state.RecoveredTextSources[source] += len(text)
	}
	return events
}

func ensureResponsesTextBlock(state *ResponsesEventToAnthropicState, key responsesTextKey) []AnthropicStreamEvent {
	if state.ContentBlockOpen && state.CurrentBlockType == "text" && state.CurrentTextKeySet && state.CurrentTextKey == key {
		return nil
	}

	events := closeCurrentBlock(state)
	idx := state.ContentBlockIndex
	state.ContentBlockOpen = true
	state.CurrentBlockType = "text"
	state.CurrentTextKey = key
	state.CurrentTextKeySet = true
	return append(events, AnthropicStreamEvent{
		Type:  "content_block_start",
		Index: &idx,
		ContentBlock: &AnthropicContentBlock{
			Type: "text",
			Text: "",
		},
	})
}

func closeResponsesTextBlock(state *ResponsesEventToAnthropicState, key responsesTextKey) []AnthropicStreamEvent {
	if !state.ContentBlockOpen || state.CurrentBlockType != "text" || !state.CurrentTextKeySet || state.CurrentTextKey != key {
		return nil
	}
	return closeCurrentBlock(state)
}

func resToAnthHandleFuncArgsDelta(evt *ResponsesStreamEvent, state *ResponsesEventToAnthropicState) []AnthropicStreamEvent {
	if evt.Delta == "" {
		return nil
	}

	if state.CurrentBlockType == "tool_use" && state.CurrentToolName == "Read" {
		state.CurrentToolArgs += evt.Delta
		return nil
	}
	if state.CurrentBlockType == "tool_use" {
		state.CurrentToolHadDelta = true
	}

	blockIdx, ok := state.OutputIndexToBlockIdx[evt.OutputIndex]
	if !ok {
		return nil
	}

	return []AnthropicStreamEvent{{
		Type:  "content_block_delta",
		Index: &blockIdx,
		Delta: &AnthropicDelta{
			Type:        "input_json_delta",
			PartialJSON: evt.Delta,
		},
	}}
}

func resToAnthHandleFuncArgsDone(evt *ResponsesStreamEvent, state *ResponsesEventToAnthropicState) []AnthropicStreamEvent {
	if state.CurrentBlockType != "tool_use" {
		return resToAnthHandleBlockDone(state)
	}

	raw := evt.Arguments
	if raw == "" {
		raw = state.CurrentToolArgs
	}
	if raw == "" || state.CurrentToolHadDelta {
		return closeCurrentBlock(state)
	}
	if state.CurrentToolName == "Read" {
		sanitized := sanitizeAnthropicToolUseInput(state.CurrentToolName, raw)
		if len(sanitized) == 0 {
			return closeCurrentBlock(state)
		}
		raw = string(sanitized)
	}

	idx := state.ContentBlockIndex
	events := []AnthropicStreamEvent{{
		Type:  "content_block_delta",
		Index: &idx,
		Delta: &AnthropicDelta{
			Type:        "input_json_delta",
			PartialJSON: raw,
		},
	}}
	events = append(events, closeCurrentBlock(state)...)
	return events
}

func resToAnthHandleReasoningDelta(evt *ResponsesStreamEvent, state *ResponsesEventToAnthropicState) []AnthropicStreamEvent {
	if evt.Delta == "" {
		return nil
	}

	blockIdx, ok := state.OutputIndexToBlockIdx[evt.OutputIndex]
	if !ok {
		return nil
	}

	return []AnthropicStreamEvent{{
		Type:  "content_block_delta",
		Index: &blockIdx,
		Delta: &AnthropicDelta{
			Type:     "thinking_delta",
			Thinking: evt.Delta,
		},
	}}
}

func resToAnthHandleBlockDone(state *ResponsesEventToAnthropicState) []AnthropicStreamEvent {
	if !state.ContentBlockOpen {
		return nil
	}
	return closeCurrentBlock(state)
}

func resToAnthHandleOutputItemDone(evt *ResponsesStreamEvent, state *ResponsesEventToAnthropicState) []AnthropicStreamEvent {
	if evt.Item == nil {
		return nil
	}

	if evt.Item.Type == "message" {
		var events []AnthropicStreamEvent
		for contentIndex, part := range evt.Item.Content {
			if part.Type != "output_text" {
				continue
			}
			key := responsesTextKey{OutputIndex: evt.OutputIndex, ContentIndex: contentIndex}
			events = append(events, reconcileResponsesTextSnapshot(state, key, part.Text, "output_item_done")...)
			responsesTextSnapshotFor(state, key).Done = true
		}
		return append(events, closeCurrentBlock(state)...)
	}

	// Handle web_search_call → synthesize server_tool_use + web_search_tool_result blocks.
	if evt.Item.Type == "web_search_call" && evt.Item.Status == "completed" {
		return resToAnthHandleWebSearchDone(evt, state)
	}

	if state.ContentBlockOpen {
		return closeCurrentBlock(state)
	}
	return nil
}

// resToAnthHandleWebSearchDone converts an OpenAI web_search_call output item
// into Anthropic server_tool_use + web_search_tool_result content block pairs.
// This allows Claude Code to count the searches performed.
func resToAnthHandleWebSearchDone(evt *ResponsesStreamEvent, state *ResponsesEventToAnthropicState) []AnthropicStreamEvent {
	var events []AnthropicStreamEvent
	events = append(events, closeCurrentBlock(state)...)

	toolUseID := "srvtoolu_" + evt.Item.ID
	query := ""
	if evt.Item.Action != nil {
		query = evt.Item.Action.Query
	}
	inputJSON, _ := json.Marshal(map[string]string{"query": query})

	// Emit server_tool_use block (start + stop).
	idx1 := state.ContentBlockIndex
	events = append(events, AnthropicStreamEvent{
		Type:  "content_block_start",
		Index: &idx1,
		ContentBlock: &AnthropicContentBlock{
			Type:  "server_tool_use",
			ID:    toolUseID,
			Name:  "web_search",
			Input: inputJSON,
		},
	})
	events = append(events, AnthropicStreamEvent{
		Type:  "content_block_stop",
		Index: &idx1,
	})
	state.ContentBlockIndex++

	// Emit web_search_tool_result block (start + stop).
	// Content is empty because OpenAI does not expose individual search results;
	// the model consumes them internally and produces text output.
	emptyResults, _ := json.Marshal([]struct{}{})
	idx2 := state.ContentBlockIndex
	events = append(events, AnthropicStreamEvent{
		Type:  "content_block_start",
		Index: &idx2,
		ContentBlock: &AnthropicContentBlock{
			Type:      "web_search_tool_result",
			ToolUseID: toolUseID,
			Content:   emptyResults,
		},
	})
	events = append(events, AnthropicStreamEvent{
		Type:  "content_block_stop",
		Index: &idx2,
	})
	state.ContentBlockIndex++

	return events
}

func resToAnthHandleCompleted(evt *ResponsesStreamEvent, state *ResponsesEventToAnthropicState) []AnthropicStreamEvent {
	if state.MessageStopSent {
		return nil
	}

	hadStreamOutput := state.ContentBlockOpen || state.ContentBlockIndex > 0
	var events []AnthropicStreamEvent
	events = append(events, closeCurrentBlock(state)...)

	if evt.Usage != nil {
		usage := anthropicUsageFromResponsesUsage(evt.Usage)
		state.InputTokens = usage.InputTokens
		state.OutputTokens = usage.OutputTokens
		state.CacheReadInputTokens = usage.CacheReadInputTokens
	}
	if evt.Response != nil {
		if evt.Response.ID != "" {
			state.ResponseID = evt.Response.ID
		}
		if state.Model == "" {
			state.Model = evt.Response.Model
		}
		if evt.Response.Usage != nil {
			usage := anthropicUsageFromResponsesUsage(evt.Response.Usage)
			state.InputTokens = usage.InputTokens
			state.OutputTokens = usage.OutputTokens
			state.CacheReadInputTokens = usage.CacheReadInputTokens
		}
		if hadStreamOutput {
			events = append(events, resToAnthHandleTerminalTextSnapshots(evt.Response, state)...)
		} else {
			events = append(events, resToAnthHandleTerminalOutput(evt.Response, state)...)
		}
	}
	events = append(events, closeCurrentBlock(state)...)

	stopReason := "end_turn"
	if evt.Response != nil {
		switch evt.Response.Status {
		case "incomplete":
			if evt.Response.IncompleteDetails != nil && evt.Response.IncompleteDetails.Reason == "max_output_tokens" {
				stopReason = "max_tokens"
			}
		case "completed":
			if state.HasToolCall {
				stopReason = "tool_use"
			}
		}
	}

	events = append(events,
		AnthropicStreamEvent{
			Type: "message_delta",
			Delta: &AnthropicDelta{
				StopReason: stopReason,
			},
			Usage: &AnthropicUsage{
				InputTokens:          state.InputTokens,
				OutputTokens:         state.OutputTokens,
				CacheReadInputTokens: state.CacheReadInputTokens,
			},
		},
		AnthropicStreamEvent{Type: "message_stop"},
	)
	state.MessageStopSent = true
	return events
}

func resToAnthHandleTerminalTextSnapshots(resp *ResponsesResponse, state *ResponsesEventToAnthropicState) []AnthropicStreamEvent {
	if resp == nil {
		return nil
	}
	var events []AnthropicStreamEvent
	for outputIndex, item := range resp.Output {
		if item.Type != "message" {
			continue
		}
		for contentIndex, part := range item.Content {
			if part.Type != "output_text" {
				continue
			}
			key := responsesTextKey{OutputIndex: outputIndex, ContentIndex: contentIndex}
			events = append(events, reconcileResponsesTextSnapshot(state, key, part.Text, "terminal_output")...)
			responsesTextSnapshotFor(state, key).Done = true
		}
	}
	return events
}

func resToAnthHandleTerminalOutput(resp *ResponsesResponse, state *ResponsesEventToAnthropicState) []AnthropicStreamEvent {
	if resp == nil || state.ContentBlockOpen || state.ContentBlockIndex > 0 {
		return nil
	}
	anthropicResp := ResponsesToAnthropic(resp, state.Model)
	var blocks []AnthropicContentBlock
	for _, block := range anthropicResp.Content {
		switch block.Type {
		case "text":
			if block.Text != "" {
				blocks = append(blocks, block)
			}
		case "thinking":
			if block.Thinking != "" {
				blocks = append(blocks, block)
			}
		case "tool_use", "server_tool_use", "web_search_tool_result":
			blocks = append(blocks, block)
		}
	}
	if len(blocks) == 0 {
		return nil
	}

	var events []AnthropicStreamEvent
	if !state.MessageStartSent {
		state.MessageStartSent = true
		events = append(events, AnthropicStreamEvent{
			Type: "message_start",
			Message: &AnthropicResponse{
				ID:      state.ResponseID,
				Type:    "message",
				Role:    "assistant",
				Content: []AnthropicContentBlock{},
				Model:   state.Model,
				Usage: AnthropicUsage{
					InputTokens:  state.InputTokens,
					OutputTokens: 0,
				},
			},
		})
	}

	for _, block := range blocks {
		idx := state.ContentBlockIndex
		startBlock := block
		switch block.Type {
		case "text":
			startBlock.Text = ""
		case "thinking":
			startBlock.Thinking = ""
		case "tool_use", "server_tool_use":
			state.HasToolCall = true
		}
		events = append(events, AnthropicStreamEvent{
			Type:         "content_block_start",
			Index:        &idx,
			ContentBlock: &startBlock,
		})
		switch block.Type {
		case "text":
			events = append(events, AnthropicStreamEvent{
				Type:  "content_block_delta",
				Index: &idx,
				Delta: &AnthropicDelta{
					Type: "text_delta",
					Text: block.Text,
				},
			})
			if state.RecoveredTextSources == nil {
				state.RecoveredTextSources = make(map[string]int)
			}
			state.RecoveredTextBytes += len(block.Text)
			state.RecoveredTextSources["terminal_output"] += len(block.Text)
		case "thinking":
			events = append(events, AnthropicStreamEvent{
				Type:  "content_block_delta",
				Index: &idx,
				Delta: &AnthropicDelta{
					Type:     "thinking_delta",
					Thinking: block.Thinking,
				},
			})
		}
		events = append(events, AnthropicStreamEvent{
			Type:  "content_block_stop",
			Index: &idx,
		})
		state.ContentBlockIndex++
	}
	return events
}

func closeCurrentBlock(state *ResponsesEventToAnthropicState) []AnthropicStreamEvent {
	if !state.ContentBlockOpen {
		return nil
	}
	idx := state.ContentBlockIndex
	state.ContentBlockOpen = false
	state.ContentBlockIndex++
	state.CurrentToolName = ""
	state.CurrentToolArgs = ""
	state.CurrentToolHadDelta = false
	state.CurrentTextKeySet = false
	return []AnthropicStreamEvent{{
		Type:  "content_block_stop",
		Index: &idx,
	}}
}
