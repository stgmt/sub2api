# Subagent Terra Medium Profile

This is the current delegated-agent profile for the Claude Code + Headroom + sub2api Codex subscription chain.

Use it when installing, repairing, or updating Claude Code agent overrides. The intent is simple: keep the lead session on full-power `gpt-5.6-sol`, keep compact/small-fast routing on Spark fallback logic, but run frequent delegated agents on `gpt-5.6-terra-medium` so they do not inherit parent Sol/max and do not spend minutes on default high/max reasoning.

## Current Canon

```text
Main Claude Code model: gpt-5.6-sol
Main effort: user/session controlled; do not persist CLAUDE_CODE_EFFORT_LEVEL
Small-fast / compact first hop: gpt-5.3-codex-spark
Small-fast fallback: gpt-5.6-luna, then gpt-5.4-mini
Default Haiku model while Spark is quota-limited: gpt-5.6-terra-medium
Delegated subagent model: gpt-5.6-terra-medium
Delegated subagent effort: medium
Delegated fallback: gpt-5.6-terra-medium -> gpt-5.6-sol-medium
```

`gpt-5.6-terra-medium` is an intentional model-effort alias. Patched sub2api normalizes it to upstream `gpt-5.6-terra` and records `reasoning_effort=medium`. The alias is used to override inherited parent `max` without hard-blocking Agent calls.

## Why Medium

Local A/B on 2026-07-12 used the same Explore-style repository analysis prompt against the local Headroom/sub2api chain. `gpt-5.6-terra-medium` was the best default for frequent subagents: materially faster than Terra high while preserving the evidence quality needed for Explore/general-purpose work.

Keep `high` and `max` available for explicit user requests or narrow quality-critical tasks. Do not make them the default for broad delegated fan-out.

Do not use Spark as the default delegated agent while native Spark is quota-limited. Spark remains the compact/small-fast first hop, with Luna and then `gpt-5.4-mini` as fallback. Prior Explore-style probes showed Spark/Luna could fail or route away under repository-scale context, so Terra medium is the safer delegated-agent default.

## Where To Set It

The setup script must write these values:

```powershell
ANTHROPIC_DEFAULT_HAIKU_MODEL=gpt-5.6-terra-medium
CLAUDE_CODE_SUBAGENT_MODEL=gpt-5.6-terra-medium
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
model: gpt-5.6-terra-medium
effort: medium
```

Project-local heavy fan-out agents should get the same frontmatter when they exist and are actually used. Example:

```text
E:\repos\lm-saas\.claude\agents\agent-marketplace-agent.md
```

Do not invent project-specific agent bodies globally. If the file exists, patch its frontmatter. If it is missing, create it only when the project/task explicitly owns that agent.

In sub2api group config, preserve the effort alias in normal fallback config:

```json
{
  "model_fallbacks": {
    "gpt-5.6-terra-medium": ["gpt-5.6-sol-medium"]
  }
}
```

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
requested_model=gpt-5.6-terra-medium
upstream_model=gpt-5.6-terra
reasoning_effort=medium
```

Expected `workflow-subagent` proof is the same.

For `general-purpose`, direct `claude --agent general-purpose` may not prove the real Agent tool path in some Claude Code builds. Launch a real `Agent(...)` tool call from Claude Code and inspect `usage_logs` for `requested_model=gpt-5.6-terra-medium` and `reasoning_effort=medium`.

Fallback proof for an empty/unavailable Terra turn should show a chain containing `gpt-5.6-sol` while preserving medium effort:

```text
requested_model=gpt-5.6-terra-medium
model_mapping_chain includes gpt-5.6-sol
reasoning_effort=medium
```

## Future GPT-5.7 Migration

Do not blindly replace `5.6` with `5.7`.

When a new line appears:

1. Probe `/v1/models`, but treat it as a catalog hint only.
2. Send direct request probes for `gpt-5.7-sol`, `gpt-5.7-terra`, and the desired alias `gpt-5.7-terra-medium`.
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
6. Add `gpt-5.7-terra-medium -> gpt-5.7-sol-medium` only after the fallback alias is proven. Otherwise keep the last proven `gpt-5.6-terra-medium` delegated profile.

After migration, re-run live agent probes and inspect logs. The migration is not complete until real Claude Code Agent traffic records the new requested model and `reasoning_effort=medium`.
