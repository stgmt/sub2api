# Alibaba Qwen + DeepSeek V4 Flash profile

Enable with:

    powershell -File scripts/claude-route.ps1 alibaba

The schedule is evaluated inside sub2api in Europe/Moscow, not in the client
process. From 17:00 inclusive through 03:00 exclusive, main and Plan use Qwen;
outside that window every route is forced to DeepSeek V4 Flash. Compact and
delegated subagents use Flash even inside the discount window. The
messages_dispatch_model_config.alibaba_time_window field is the source of
truth, so a stale Claude Code process cannot bypass the schedule with another
picker alias.

The `claude-route alibaba` profile is the strict Alibaba route for the current
fleet. It is intentionally separate from the legacy `qwen-only` profile.

## Route contract

| Traffic class | Target | Effort |
| --- | --- | --- |
| Main interactive and picker aliases | `qwen3.8-max-preview` | `high` |
| Built-in Plan agent | `qwen3.8-max-preview` | `high` |
| Compact and autocompact | `deepseek-v4-flash-0731` | `high` |
| Small-fast, SDK CLI, Explore, general-purpose, workflow agents | `deepseek-v4-flash-0731` | `high` |

`deepseek-v4-pro` is never an upstream target. A stale explicit Pro request is
redirected to Flash and the live proof must show
`upstream_model=deepseek-v4-flash-0731`, never Pro. GPT, Claude, and automatic
cross-provider fallbacks are empty. The group must contain only the Alibaba
Token Plan account.

## Capability and rollout gate

The official DeepSeek API names the V4 models `deepseek-v4-pro` and
`deepseek-v4-flash-0731`; both support 1M context and Anthropic/OpenAI API access.
Alibaba's Model Studio matrix marks Flash as supporting thinking and function
calling, but not built-in tools or structured output. Claude Code's tools are
client-side custom tool calls, so the real gate is a live tool-call and stream
probe through Headroom and sub2api, not `/v1/models` alone.

Before switching the stable fleet key, verify that the Alibaba account actually
accepts the live exact ID `deepseek-v4-flash-0731` (the unsuffixed alias is rejected by the endpoint). The current live account has a persisted quota
reset and the previous group had no active fleet key, so a quota or catalog
failure must leave the old profile intact.

## Fleet proof

`claude-route alibaba` applies one generation to Windows, the Ubuntu Hyper-V
guest, and the Windows Hyper-V guest. Verify all three nodes, then correlate
`usage_logs.requested_model`, `upstream_model`, `model_mapping_chain`, and
`reasoning_effort` for main, Plan, compact, and at least one delegated child.
Negative proof: zero post-cutover rows with `upstream_model=deepseek-v4-pro`,
any GPT/Claude upstream, or a non-empty fallback route.
