// Package openai provides helpers and types for OpenAI API integration.
package openai

import (
	_ "embed"
	"strings"
)

// Model represents an OpenAI model
type Model struct {
	ID              string `json:"id"`
	Object          string `json:"object"`
	Created         int64  `json:"created"`
	OwnedBy         string `json:"owned_by"`
	Type            string `json:"type"`
	DisplayName     string `json:"display_name"`
	ContextLength   int    `json:"context_length,omitempty"`
	MaxInputTokens  int    `json:"max_input_tokens,omitempty"`
	MaxOutputTokens int    `json:"max_output_tokens,omitempty"`
}

// ModelContextLimits is the context contract exposed to OpenAI-compatible
// clients. The canonical source uses max_input_tokens; context_length is
// emitted as the de facto OpenAI-compatible alias used by proxy clients.
type ModelContextLimits struct {
	ContextLength   int
	MaxInputTokens  int
	MaxOutputTokens int
}

const (
	gpt56ContextWindow = 1_050_000
	gpt55ContextWindow = 1_050_000
	gpt54ContextWindow = 1_050_000
	codexContextWindow = 272_000
	maxOutputTokens    = 128_000
)

// ContextLimitsForModel returns the known limits for a published model ID.
// Fast IDs are service-tier aliases and therefore share the base model
// context window. Unknown IDs deliberately return false instead of inventing
// a limit that could make a client send an oversized request.
func ContextLimitsForModel(modelID string) (ModelContextLimits, bool) {
	id := strings.ToLower(strings.TrimSpace(modelID))
	id = strings.TrimSuffix(id, "-fast")

	var contextWindow int
	switch {
	case strings.HasPrefix(id, "gpt-5.6"):
		contextWindow = gpt56ContextWindow
	case id == "gpt-5.5":
		contextWindow = gpt55ContextWindow
	case id == "gpt-5.4":
		contextWindow = gpt54ContextWindow
	case id == "gpt-5.4-mini":
		contextWindow = codexContextWindow
	case strings.HasPrefix(id, "gpt-5.3-codex"):
		contextWindow = codexContextWindow
	case id == "gpt-5.2":
		contextWindow = codexContextWindow
	default:
		return ModelContextLimits{}, false
	}

	return ModelContextLimits{
		ContextLength:   contextWindow,
		MaxInputTokens:  contextWindow,
		MaxOutputTokens: maxOutputTokens,
	}, true
}

// ApplyContextLimits enriches a model without changing the standard fields.
func ApplyContextLimits(model *Model) {
	if model == nil {
		return
	}
	limits, ok := ContextLimitsForModel(model.ID)
	if !ok {
		return
	}
	model.ContextLength = limits.ContextLength
	model.MaxInputTokens = limits.MaxInputTokens
	model.MaxOutputTokens = limits.MaxOutputTokens
}

// ModelsWithContextLimits returns a copy so the package-level model catalog
// remains immutable for callers that reuse it across requests.
func ModelsWithContextLimits(models []Model) []Model {
	out := make([]Model, len(models))
	copy(out, models)
	for i := range out {
		ApplyContextLimits(&out[i])
	}
	return out
}

// DefaultModels OpenAI models list
var DefaultModels = []Model{
	{ID: "gpt-5.6-sol", Object: "model", Created: 1780876800, OwnedBy: "openai", Type: "model", DisplayName: "GPT-5.6 Sol"},
	{ID: "gpt-5.6-terra", Object: "model", Created: 1780876800, OwnedBy: "openai", Type: "model", DisplayName: "GPT-5.6 Terra"},
	{ID: "gpt-5.6-luna", Object: "model", Created: 1780876800, OwnedBy: "openai", Type: "model", DisplayName: "GPT-5.6 Luna"},
	{ID: "gpt-5.5", Object: "model", Created: 1776873600, OwnedBy: "openai", Type: "model", DisplayName: "GPT-5.5"},
	{ID: "gpt-5.4", Object: "model", Created: 1738368000, OwnedBy: "openai", Type: "model", DisplayName: "GPT-5.4"},
	{ID: "gpt-5.3-codex-spark", Object: "model", Created: 1735689600, OwnedBy: "openai", Type: "model", DisplayName: "GPT-5.3 Codex Spark"},
	{ID: "codex-auto-review", Object: "model", Created: 1776902400, OwnedBy: "openai", Type: "model", DisplayName: "Codex Auto Review"},
	{ID: "gpt-5.2", Object: "model", Created: 1733875200, OwnedBy: "openai", Type: "model", DisplayName: "GPT-5.2"},
	{ID: "gpt-image-1", Object: "model", Created: 1733875200, OwnedBy: "openai", Type: "model", DisplayName: "GPT Image 1"},
	{ID: "gpt-image-1.5", Object: "model", Created: 1735689600, OwnedBy: "openai", Type: "model", DisplayName: "GPT Image 1.5"},
	{ID: "gpt-image-2", Object: "model", Created: 1738368000, OwnedBy: "openai", Type: "model", DisplayName: "GPT Image 2"},
}

// DefaultModelIDs returns the default model ID list
func DefaultModelIDs() []string {
	ids := make([]string, len(DefaultModels))
	for i, m := range DefaultModels {
		ids[i] = m.ID
	}
	return ids
}

// DefaultTestModel default model for testing OpenAI accounts
const DefaultTestModel = "gpt-5.4"

// DefaultInstructions default instructions for non-Codex CLI requests.
// 内容为真实 Codex CLI 的 GPT-5-Codex base prompt（codex 系模型默认）。
//
//go:embed instructions.txt
var DefaultInstructions string

// instructionsGPT51 / instructionsGPT52 / instructionsGPT55 为 gpt-5.1 / gpt-5.2 / gpt-5.5
// 非 codex 模型对应的真实 Codex 编码 agent base prompt，用于模型感知的 instructions 选择。
// GPT-5.5 同时作为最新版本的 fallback（覆盖 5.3 / 5.4 等未单独维护 prompt 的版本）。
//
//go:embed instructions_gpt5_1.txt
var instructionsGPT51 string

//go:embed instructions_gpt5_2.txt
var instructionsGPT52 string

//go:embed instructions_gpt5_5.txt
var instructionsGPT55 string

// latestCodexInstructions 返回当前已知最新版本的 Codex base instructions，
// 当前为 GPT-5.5；若 5.5 prompt 意外为空则回退到 DefaultInstructions 保证非空。
func latestCodexInstructions() string {
	if v := strings.TrimSpace(instructionsGPT55); v != "" {
		return instructionsGPT55
	}
	return DefaultInstructions
}

// CodexBaseInstructionsForModel 按模型返回最匹配的真实 Codex base instructions：
//   - 含 "codex" 的模型（gpt-5-codex / gpt-5.x-codex / codex-max / spark 等）→ GPT-5-Codex prompt
//   - gpt-5.5 系非 codex 模型 → GPT-5.5 prompt
//   - gpt-5.2 系非 codex 模型 → GPT-5.2 prompt
//   - gpt-5.1 系非 codex 模型 → GPT-5.1 prompt
//   - 其它（含 gpt-5.3 / gpt-5.4 / 裸 gpt-5 / 未知模型）→ 回退到最新版本（当前 GPT-5.5）
//
// 任一专用 prompt 意外为空时回退链最终落到 DefaultInstructions，保证返回非空。
func CodexBaseInstructionsForModel(model string) string {
	m := strings.ToLower(strings.TrimSpace(model))
	switch {
	case strings.Contains(m, "codex"):
		return DefaultInstructions
	case strings.HasPrefix(m, "gpt-5.5"):
		return latestCodexInstructions()
	case strings.HasPrefix(m, "gpt-5.2"):
		if v := strings.TrimSpace(instructionsGPT52); v != "" {
			return instructionsGPT52
		}
	case strings.HasPrefix(m, "gpt-5.1"):
		if v := strings.TrimSpace(instructionsGPT51); v != "" {
			return instructionsGPT51
		}
	}
	return latestCodexInstructions()
}
