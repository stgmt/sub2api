# Subagent Qwen High Profile

This is the current delegated-agent profile for the Claude Code + Headroom + sub2api Codex subscription chain. The old Terra-medium setup is preserved below as historical evidence only. For the full "why this must stay Qwen high" decision record, read `workflow-qwen-high-rationale.md`.

Use it when installing, repairing, or updating Claude Code agent overrides. The intent is simple: keep the lead session on full-power `gpt-5.6-sol`, pin Opus/Fable/Sonnet/Haiku picker slots to Qwen high, and run frequent delegated agents plus compact/small-fast on Qwen 3.8 Max High instead of inheriting parent Sol/max by accident.

## Current Canon

```text
Main Claude Code model: gpt-5.6-sol
Main effort: user/session controlled; do not persist CLAUDE_CODE_EFFORT_LEVEL
Small-fast / compact model: qwen3.8-max-preview
Compact effort: high
Picker Opus/Fable/Sonnet aliases: qwen3.8-max-preview
Picker Haiku alias: qwen3.8-max-preview, display name Qwen 3.8 Max
Delegated subagent model: qwen3.8-max-preview
Delegated subagent effort: high
Normal message fallback: none unless explicitly requested by the user
```

`qwen3.8-max-preview` is an Alibaba Token Plan model routed through the Anthropic-compatible Token Plan account. It should record `reasoning_effort=high` for delegated agents and compact requests.

## Why Qwen High

The 2026-07-22 Alibaba rebench proved `qwen3.8-max-preview` on `high` can handle near-1M summary input through the local sub2api path: 955,733 count-token preflight, 903,849 usage input tokens, 3,761 output tokens, 192.2s wall time, and 12/12 sentinels retained. The user then explicitly chose Qwen high for all subagents and compact.

Spark and Terra remain useful historical baselines. Spark was faster for short compact/small-fast work but has a 128k text-only window and no effort knob. Terra-medium was a quota-safer delegated profile, but it is no longer the installed default after the Qwen-high switch.

Do not add fallbacks silently. Provider/account failures should be debuggable unless the user explicitly asks for fallback behavior.

## Where To Set It

The setup script must write these values:

```powershell
ANTHROPIC_DEFAULT_HAIKU_MODEL=qwen3.8-max-preview
ANTHROPIC_DEFAULT_OPUS_MODEL=qwen3.8-max-preview
ANTHROPIC_DEFAULT_FABLE_MODEL=qwen3.8-max-preview
ANTHROPIC_DEFAULT_SONNET_MODEL=qwen3.8-max-preview
ANTHROPIC_SMALL_FAST_MODEL=qwen3.8-max-preview
CLAUDE_CODE_SUBAGENT_MODEL=qwen3.8-max-preview
```

Set them in:

- `%USERPROFILE%\.claude\settings.json` under `env`.
- Windows User environment variables.
- `%USERPROFILE%\.local\bin\claude.cmd` if that wrapper is managed by the install.

Do not require Machine/System environment variables. They are optional and often need admin rights. User env plus Claude settings plus the wrapper are the normal per-user global path.

Create or patch these global Claude Code agent overrides:

```text
%USERPROFILE%\.claude\agents\general-purpose.md
%USERPROFILE%\.claude\agents\Explore.md
%USERPROFILE%\.claude\agents\workflow-subagent.md
```

Each override frontmatter must contain:

```yaml
model: qwen3.8-max-preview
effort: high
```

Project-local heavy fan-out agents should get the same frontmatter when they exist and are actually used. Example:

```text
E:\repos\lm-saas\.claude\agents\agent-marketplace-agent.md
```

Do not invent project-specific agent bodies globally. If the file exists, patch its frontmatter. If it is missing, create it only when the project/task explicitly owns that agent.

In sub2api group config, keep normal `model_fallbacks` empty unless the user explicitly asks for fallback behavior. This keeps provider/entitlement bugs visible instead of hiding them behind Sol.

## If Overrides Are Missing

Installer behavior:

1. Create `%USERPROFILE%\.claude\agents` if it does not exist.
2. For `general-purpose`, `Explore`, and `workflow-subagent`, create a minimal override if missing.
3. If an override exists, patch only frontmatter `model` and `effort`; keep the existing body unless the user explicitly asks for prompt changes.
4. If a file has no frontmatter, prepend frontmatter with the canonical model and effort.
5. After writing, verify the file content and run a live probe.

The prompt body should be advisory only. It may ask workers to keep scope bounded and avoid huge fan-out, but it must not install blocking `PreToolUse`, `SubagentStart`, or `SubagentStop` hooks unless the user explicitly asks for hard caps.

## Verification

Use usage logs, not the Claude UI label alone.

Expected direct Explore proof:

```text
requested_model=qwen3.8-max-preview
upstream_model=qwen3.8-max-preview
reasoning_effort=high
```

Expected `workflow-subagent` proof is the same.

For `general-purpose`, direct `claude --agent general-purpose` may not prove the real Agent tool path in some Claude Code builds. Launch a real `Agent(...)` tool call from Claude Code and inspect `usage_logs` for `requested_model=qwen3.8-max-preview` and `reasoning_effort=high`.

## Future GPT-5.7 Migration

Do not blindly replace `5.6` with `5.7`.

When a new line appears:

1. Probe `/v1/models`, but treat it as a catalog hint only.
2. Send direct request probes for the candidate GPT/Codex and Alibaba Token Plan models.
3. Confirm `usage_logs.requested_model`, `usage_logs.upstream_model`, `usage_logs.model_mapping_chain`, and `usage_logs.reasoning_effort`.
4. Confirm context and output behavior with a real long-context probe before changing client compact targets.
5. Only after proof, update:
   - `scripts/setup-sub2api-claude-code.ps1`
   - `scripts/verify-claude-code-sub2api.ps1`
   - `references/fullpower-profile.json`
   - `references/group-and-compact-routing.md`
   - `references/profile-and-context.md`
   - `references/verification.md`
   - `references/troubleshooting.md`
   - `evals/evals.json`
6. Keep Qwen high as the delegated default unless the user explicitly chooses a new proven subagent model.

After migration, re-run live agent probes and inspect logs. The migration is not complete until real Claude Code Agent traffic records the new requested model and expected reasoning effort.
