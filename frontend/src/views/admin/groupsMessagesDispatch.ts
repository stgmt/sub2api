import type { OpenAIMessagesDispatchModelConfig } from "@/types";

export interface MessagesDispatchMappingRow {
  claude_model: string;
  target_model: string;
}

export interface MessagesDispatchFormState {
  allow_messages_dispatch: boolean;
  opus_mapped_model: string;
  sonnet_mapped_model: string;
  haiku_mapped_model: string;
  compact_mapped_model: string;
  sdk_cli_mapped_model: string;
  sdk_cli_reasoning_effort: string;
  exact_model_mappings: MessagesDispatchMappingRow[];
  model_fallbacks: Record<string, string[]>;
}

export function createDefaultMessagesDispatchFormState(): MessagesDispatchFormState {
  return {
    allow_messages_dispatch: false,
    opus_mapped_model: "gpt-5.4",
    sonnet_mapped_model: "gpt-5.3-codex",
    haiku_mapped_model: "gpt-5.3-codex-spark",
    compact_mapped_model: "",
    sdk_cli_mapped_model: "",
    sdk_cli_reasoning_effort: "",
    exact_model_mappings: [],
    model_fallbacks: {},
  };
}

export function messagesDispatchConfigToFormState(
  config?: OpenAIMessagesDispatchModelConfig | null,
): MessagesDispatchFormState {
  const defaults = createDefaultMessagesDispatchFormState();
  const exactMappings = Object.entries(config?.exact_model_mappings || {})
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([claude_model, target_model]) => ({ claude_model, target_model }));

  return {
    allow_messages_dispatch: false,
    opus_mapped_model:
      config?.opus_mapped_model?.trim() || defaults.opus_mapped_model,
    sonnet_mapped_model:
      config?.sonnet_mapped_model?.trim() || defaults.sonnet_mapped_model,
    haiku_mapped_model:
      config?.haiku_mapped_model?.trim() || defaults.haiku_mapped_model,
    compact_mapped_model: config?.compact_mapped_model?.trim() || "",
    sdk_cli_mapped_model: config?.sdk_cli_mapped_model?.trim() || "",
    sdk_cli_reasoning_effort:
      config?.sdk_cli_reasoning_effort?.trim() || "",
    exact_model_mappings: exactMappings,
    model_fallbacks: structuredClone(config?.model_fallbacks || {}),
  };
}

export function messagesDispatchFormStateToConfig(
  state: MessagesDispatchFormState,
): OpenAIMessagesDispatchModelConfig {
  const exactModelMappings = Object.fromEntries(
    state.exact_model_mappings
      .map((row) => [row.claude_model.trim(), row.target_model.trim()] as const)
      .filter(([claudeModel, targetModel]) => claudeModel && targetModel),
  );

  return {
    opus_mapped_model: state.opus_mapped_model.trim(),
    sonnet_mapped_model: state.sonnet_mapped_model.trim(),
    haiku_mapped_model: state.haiku_mapped_model.trim(),
    compact_mapped_model: state.compact_mapped_model.trim(),
    sdk_cli_mapped_model: state.sdk_cli_mapped_model.trim(),
    sdk_cli_reasoning_effort: state.sdk_cli_reasoning_effort.trim(),
    exact_model_mappings: exactModelMappings,
    model_fallbacks: structuredClone(state.model_fallbacks),
  };
}

export function resetMessagesDispatchFormState(
  target: MessagesDispatchFormState,
): void {
  const defaults = createDefaultMessagesDispatchFormState();
  target.allow_messages_dispatch = defaults.allow_messages_dispatch;
  target.opus_mapped_model = defaults.opus_mapped_model;
  target.sonnet_mapped_model = defaults.sonnet_mapped_model;
  target.haiku_mapped_model = defaults.haiku_mapped_model;
  target.compact_mapped_model = defaults.compact_mapped_model;
  target.sdk_cli_mapped_model = defaults.sdk_cli_mapped_model;
  target.sdk_cli_reasoning_effort = defaults.sdk_cli_reasoning_effort;
  target.exact_model_mappings = [];
  target.model_fallbacks = {};
}
