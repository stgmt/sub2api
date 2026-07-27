import { describe, expect, it } from "vitest";

import {
  createDefaultMessagesDispatchFormState,
  messagesDispatchConfigToFormState,
  messagesDispatchFormStateToConfig,
  resetMessagesDispatchFormState,
} from "../groupsMessagesDispatch";

describe("groupsMessagesDispatch", () => {
  it("returns the expected default form state", () => {
    expect(createDefaultMessagesDispatchFormState()).toEqual({
      allow_messages_dispatch: false,
      opus_mapped_model: "gpt-5.4",
      sonnet_mapped_model: "gpt-5.3-codex",
      haiku_mapped_model: "gpt-5.3-codex-spark",
      compact_mapped_model: "",
      compact_reasoning_effort: "",
      plan_mapped_model: "",
      plan_reasoning_effort: "",
      sdk_cli_mapped_model: "",
      sdk_cli_reasoning_effort: "",
      exact_model_mappings: [],
      model_fallbacks: {},
      automatic_model_fallbacks: {},
    });
  });

  it("sanitizes exact model mapping rows when converting to config", () => {
    const config = messagesDispatchFormStateToConfig({
      allow_messages_dispatch: true,
      opus_mapped_model: " gpt-5.4 ",
      sonnet_mapped_model: "gpt-5.3-codex",
		haiku_mapped_model: " gpt-5.3-codex-spark ",
      compact_mapped_model: " qwen3.8-max-preview ",
      compact_reasoning_effort: " low ",
      plan_mapped_model: " gpt-5.6-sol ",
      plan_reasoning_effort: " high ",
      sdk_cli_mapped_model: " qwen3.8-max-preview ",
      sdk_cli_reasoning_effort: " high ",
      exact_model_mappings: [
        {
          claude_model: " claude-sonnet-4-5-20250929 ",
          target_model: " gpt-5.2 ",
        },
        { claude_model: "", target_model: "gpt-5.4" },
        { claude_model: "claude-opus-4-6", target_model: " " },
      ],
      model_fallbacks: {},
      automatic_model_fallbacks: {
        "gpt-5.6-luna": ["gpt-5.6-sol"],
      },
    });

    expect(config).toEqual({
      opus_mapped_model: "gpt-5.4",
      sonnet_mapped_model: "gpt-5.3-codex",
		haiku_mapped_model: "gpt-5.3-codex-spark",
      compact_mapped_model: "qwen3.8-max-preview",
      compact_reasoning_effort: "low",
      plan_mapped_model: "gpt-5.6-sol",
      plan_reasoning_effort: "high",
      sdk_cli_mapped_model: "qwen3.8-max-preview",
      sdk_cli_reasoning_effort: "high",
      exact_model_mappings: {
        "claude-sonnet-4-5-20250929": "gpt-5.2",
      },
      model_fallbacks: {},
      automatic_model_fallbacks: {
        "gpt-5.6-luna": ["gpt-5.6-sol"],
      },
    });
  });

  it("hydrates form state from api config", () => {
    expect(
      messagesDispatchConfigToFormState({
        opus_mapped_model: "gpt-5.4",
        sonnet_mapped_model: "gpt-5.2",
        haiku_mapped_model: "gpt-5.3-codex-spark",
        compact_mapped_model: "qwen3.8-max-preview",
        compact_reasoning_effort: "low",
        plan_mapped_model: "gpt-5.6-sol",
        plan_reasoning_effort: "high",
        sdk_cli_mapped_model: "qwen3.8-max-preview",
        sdk_cli_reasoning_effort: "high",
        exact_model_mappings: {
          "claude-opus-4-6": "gpt-5.4",
			"claude-haiku-4-5-20251001": "gpt-5.3-codex-spark",
        },
        model_fallbacks: {
          "qwen3.8-max-preview": ["qwen3.7-max"],
        },
        automatic_model_fallbacks: {
          "gpt-5.6-luna": ["gpt-5.6-sol"],
        },
      }),
    ).toEqual({
      allow_messages_dispatch: false,
      opus_mapped_model: "gpt-5.4",
      sonnet_mapped_model: "gpt-5.2",
		haiku_mapped_model: "gpt-5.3-codex-spark",
      compact_mapped_model: "qwen3.8-max-preview",
      compact_reasoning_effort: "low",
      plan_mapped_model: "gpt-5.6-sol",
      plan_reasoning_effort: "high",
      sdk_cli_mapped_model: "qwen3.8-max-preview",
      sdk_cli_reasoning_effort: "high",
      exact_model_mappings: [
        {
          claude_model: "claude-haiku-4-5-20251001",
			target_model: "gpt-5.3-codex-spark",
        },
        { claude_model: "claude-opus-4-6", target_model: "gpt-5.4" },
      ],
      model_fallbacks: {
        "qwen3.8-max-preview": ["qwen3.7-max"],
      },
      automatic_model_fallbacks: {
        "gpt-5.6-luna": ["gpt-5.6-sol"],
      },
    });
  });

  it("resets mutable form state when platform switches away from openai", () => {
    const state = {
      allow_messages_dispatch: true,
      opus_mapped_model: "gpt-5.2",
      sonnet_mapped_model: "gpt-5.4",
      haiku_mapped_model: "gpt-5.1",
      compact_mapped_model: "qwen3.7-max",
      compact_reasoning_effort: "low",
      plan_mapped_model: "gpt-5.6-sol",
      plan_reasoning_effort: "high",
      sdk_cli_mapped_model: "gpt-5.6-terra",
      sdk_cli_reasoning_effort: "medium",
      exact_model_mappings: [
        { claude_model: "claude-opus-4-6", target_model: "gpt-5.4" },
      ],
      model_fallbacks: { "gpt-5.6-terra": ["gpt-5.4"] },
      automatic_model_fallbacks: {
        "gpt-5.6-luna": ["gpt-5.6-sol"],
      },
    };

    resetMessagesDispatchFormState(state);

    expect(state).toEqual({
      allow_messages_dispatch: false,
      opus_mapped_model: "gpt-5.4",
      sonnet_mapped_model: "gpt-5.3-codex",
		haiku_mapped_model: "gpt-5.3-codex-spark",
      compact_mapped_model: "",
      compact_reasoning_effort: "",
      plan_mapped_model: "",
      plan_reasoning_effort: "",
      sdk_cli_mapped_model: "",
      sdk_cli_reasoning_effort: "",
      exact_model_mappings: [],
      model_fallbacks: {},
      automatic_model_fallbacks: {},
    });
  });
});
