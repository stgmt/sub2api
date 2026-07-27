# Plan Agent Premium Routing

## Contract

Under `chatgpt-only`, the parent session remains user-selectable, ordinary Agent
SDK children use `gpt-5.6-luna/xhigh`, and the built-in Plan agent uses
`gpt-5.6-sol/high`. Compact has higher precedence and remains
`gpt-5.6-luna/high`.

```json
{
  "plan_mapped_model": "gpt-5.6-sol",
  "plan_reasoning_effort": "high",
  "sdk_cli_mapped_model": "gpt-5.6-luna",
  "sdk_cli_reasoning_effort": "xhigh"
}
```

The group owns the policy. Do not add a Claude Code Plan override: server-side
routing covers every host and VM using the stable key.

## Classification

Classify only when all independent signals agree:

1. User-Agent starts with `claude-cli/` and contains `external, sdk-cli`.
2. `metadata.user_id` is non-empty.
3. Structured `system` contains `cc_entrypoint=sdk-cli`,
   `cc_is_subagent=true`, and all three current Plan anchors:
   - `You are a software architect and planning specialist for Claude Code.`
   - `=== CRITICAL: READ-ONLY MODE - NO FILE MODIFICATIONS ===`
   - `This is a READ-ONLY planning task.`
4. Tools contain `Bash`, `Glob`, `Grep`, and `Read`; `Edit` and `Write` are absent.

Never scan `messages` or the serialized whole body. User text can quote a Plan
prompt and must not escalate an ordinary worker to Sol.

The Claude Code 2.1.219 probe contained 5 Plan requests and 22 controls. UA-only
routing produced 22 false positives; whole-body anchor search produced 6; the
structured system-plus-UA-plus-tools classifier produced 5 true positives,
zero false positives, and zero false negatives in that dataset.

## Session Continuity

Later requests may have a shortened system prompt. Cache a positive role by
SHA-256 of `metadata.user_id` for 30 minutes, bound the cache to 4096 entries,
and never cache a negative role. Precedence is compact, direct composite,
positive sticky match, then generic SDK. The process-local cache contains no raw
session ID and fails closed to generic SDK after restart.

## Verification

Run detector mutation, prompt-injection, TTL, eviction, sticky-continuation, and
generic-fallback tests. Then run `scripts/test-provider-route-contract.ps1` and
`scripts/verify-claude-provider-route.ps1`.

The tagged live Plan request must correlate to `usage_logs` with OpenAI OAuth
account `codex-chatgpt-subscription`, model `gpt-5.6-sol`, and
`reasoning_effort=high`. The proxy log must contain
`claude_code.agent_role_route`, `agent_role=plan`, and source
`system_composite` or `session_cache`. The same run must prove generic SDK stays
Luna/xhigh and compact stays Luna/high.

If Claude Code changes an anchor or tool set, fail closed. Capture a new
positive/control dataset, update tests first, then change the classifier.
