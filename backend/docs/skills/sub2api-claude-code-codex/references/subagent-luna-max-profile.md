# ChatGPT-only v5: Luna Max Delegated Profile

## Policy

The `chatgpt-only` v5 profile keeps the interactive main session and the
built-in Plan agent on `gpt-5.6-sol/high`. Every route that previously used
`gpt-5.6-terra-medium/medium` uses `gpt-5.6-luna/max` instead:

- Fable, Sonnet, and Haiku picker slots;
- `ANTHROPIC_SMALL_FAST_MODEL`;
- native `/compact` and autocompact;
- `claude -p` / `--print` SDK traffic;
- generic, Explore, workflow, and named subagents;
- legacy Terra/Terra-medium and stale Claude/Qwen aliases.

Interactive `/effort` remains selectable for the main session. Do not persist
`CLAUDE_CODE_EFFORT_LEVEL`; the server-side Plan classifier is the only
exception to the generic Luna route. The server also owns the compatibility
redirect for already-running clients: an explicit Luna/Terra request is
rewritten at `/v1/messages` to Luna/max even if Claude Code sent `medium` or
`xhigh`. This does not require restarting Claude Code.

## Exact Contract

```json
{
  "agent_model": "gpt-5.6-luna",
  "agent_effort": "max",
  "compact_mapped_model": "gpt-5.6-luna",
  "compact_reasoning_effort": "max",
  "sdk_cli_mapped_model": "gpt-5.6-luna",
  "sdk_cli_reasoning_effort": "max",
  "exact_model_reasoning_efforts": {
    "gpt-5.6-terra": "max",
    "gpt-5.6-terra-medium": "max",
    "gpt-5.6-luna": "max"
  },
  "plan_mapped_model": "gpt-5.6-sol",
  "plan_reasoning_effort": "high",
  "model_fallbacks": {},
  "automatic_model_fallbacks": {}
}
```

The model catalog publishes `gpt-5.6-luna` and hides
`gpt-5.6-terra-medium`. A legacy `gpt-5.6-terra` request is an explicit
compatibility route to Luna, not a fallback. The client safety targets remain
`CLAUDE_CODE_MAX_CONTEXT_TOKENS=370000` and
`CLAUDE_CODE_AUTO_COMPACT_WINDOW=340000`.

## Proof

Do not trust the Claude status line or picker label. The required live proof is
correlated `usage_logs` plus the role-route log:

1. Main: `gpt-5.6-sol`, user-selected effort.
2. Plan: `gpt-5.6-sol/high`, `agent_role=plan`.
3. Generic Agent SDK child: `gpt-5.6-luna/max`.
4. Native compact: `gpt-5.6-luna/max` with the trusted compact header.
5. Legacy Terra probe: send `gpt-5.6-terra` with `effort=medium`; usage must
   show requested/model `gpt-5.6-luna`, effort `max`.
6. Direct Luna probe: send `gpt-5.6-luna` with `effort=xhigh`; usage must show
   requested/model `gpt-5.6-luna`, effort `max`.

After the cutover, no new request may record
`requested_model=gpt-5.6-terra-medium` or a non-Plan Luna route with
`reasoning_effort=medium`. Keep OpenAI/Codex account and provider assertions in
the verifier, and keep Anthropic/Alibaba forbidden for this profile.
