package domain

// OpenAIMessagesDispatchModelConfig controls how Anthropic /v1/messages
// requests are mapped onto OpenAI/Codex models.
type OpenAIMessagesDispatchModelConfig struct {
	OpusMappedModel       string              `json:"opus_mapped_model,omitempty"`
	SonnetMappedModel     string              `json:"sonnet_mapped_model,omitempty"`
	HaikuMappedModel      string              `json:"haiku_mapped_model,omitempty"`
	CompactMappedModel    string              `json:"compact_mapped_model,omitempty"`
	SDKCLIMappedModel     string              `json:"sdk_cli_mapped_model,omitempty"`
	SDKCLIReasoningEffort string              `json:"sdk_cli_reasoning_effort,omitempty"`
	ExactModelMappings    map[string]string   `json:"exact_model_mappings,omitempty"`
	ModelFallbacks        map[string][]string `json:"model_fallbacks,omitempty"`
}
