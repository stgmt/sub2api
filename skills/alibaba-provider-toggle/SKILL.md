---
name: alibaba-provider-toggle
description: Switch the managed Claude Code fleet to the Alibaba Token Plan profile with a Moscow-time Qwen discount window and DeepSeek V4 Flash outside it.
---

# Alibaba Provider Toggle

Use the canonical controller from the sub2api-claude-code-codex skill:

    powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME/.codex/skills/sub2api-claude-code-codex/scripts/claude-route.ps1" alibaba

## Contract

- This toggle is opt-in. Do not change the active provider when merely
  inspecting the schedule.
- During 17:00 <= Europe/Moscow < 03:00, main and Plan route to
  qwen3.8-max-preview with high.
- Compact and delegated subagents route to deepseek-v4-flash-0731 with high.
- Outside the window, every request is forced to deepseek-v4-flash-0731 with high,
  independently of the requested client model.
- deepseek-v4-pro is forbidden as an upstream target. The managed mapping
  redirects the legacy name to Flash.
- Fallback groups and model fallbacks remain empty. A Qwen quota or transport
  failure must be diagnosed from the returned provider error, not silently
  converted to GPT or Claude traffic.

## Verification

Run:

    powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME/.codex/skills/sub2api-claude-code-codex/scripts/claude-route.ps1" status

Then verify the active group has
messages_dispatch_model_config.alibaba_time_window and inspect the matching
usage_logs row for requested_model, model, upstream_model,
model_mapping_chain, reasoning_effort, and the Alibaba account name.
