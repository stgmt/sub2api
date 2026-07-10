# Profile And Context Windows

Source-of-truth profile, GPT-5.6 defaults, compact profile, and context-window caveats extracted from the previous monolithic skill.

## Source Of Truth

Prefer this profile unless the user explicitly asks for a different model or port:

```text
Proxy: sub2api
Source fork: https://github.com/stgmt/sub2api
Source branch: main
Verified fork commit: 8049675b fix: fall back on Anthropic messages model-not-found
Fixed issue: https://github.com/stgmt/sub2api/issues/1
Proxy image: sub2api-codex:local-token-usage
Docker bind: 0.0.0.0:18081 -> container 8080 for Docker-in-WSL when Windows `wslrelay.exe` is unreliable
Claude base URL: http://<wsl-primary-ip>:18081 in that Docker-in-WSL profile
Upstream platform: OpenAI/Codex OAuth
Claude Code model: gpt-5.6-sol
Claude Code small-fast model: gpt-5.3-codex-spark with normal model_fallbacks to gpt-5.6-luna, then gpt-5.4-mini
Upstream main model: gpt-5.6-sol
Claude Opus mapping: gpt-5.6-sol
Claude Sonnet mapping: gpt-5.6-terra
Claude Haiku mapping: gpt-5.3-codex-spark with normal model_fallbacks to gpt-5.6-luna, then gpt-5.4-mini
Upstream compact model: gpt-5.3-codex-spark via account compact_model_mapping
Compact model fallback: gpt-5.6-luna first, then gpt-5.4-mini via account compact_model_fallbacks when Spark is rate-limited, unavailable, unknown/unsupported, or returns a service-unavailable class error
Manual /compact routing: patched sub2api detects Claude Code compact prompts on /v1/messages and applies account compact_model_mapping
Large compact fallback: if the mapped compact model returns context_length_exceeded, patched sub2api summarizes transcript chunks with the compact model, recursively merges the chunk summaries, splits oversized intermediate summaries again when merge overflows, and returns one Anthropic-compatible compact response
Compact quality guard: final compact prompt requires a `# Compact Capsule` with Current State, Active User Intent, Files Touched, Commands And Evidence, Errors And Blockers, Decisions And Config, and Next Command
Compact meta-intent sanitizer: before final merge, patched sub2api strips intermediate summary lines that misclassify compact maintenance as the active task, such as "produce a merged/detailed compact summary", "prior chunking", "context compaction", or "merge chunk summaries"
Compact recovery hook: optional Claude Code PreCompact/PostCompact/UserPromptSubmit hook writes a small recovery state and injects it once after compaction so the agent does not treat the compact request as the real user task
Reasoning: max in Claude Code, xhigh in sub2api logs
Official GPT-5.6 context window: 1,050,000 tokens with 128,000 max output for Sol/Terra/Luna.
Official Claude context windows: Fable 5, Opus 4.8, and Sonnet 5 are 1M; Haiku 4.5 is 200k.
Official context docs checked on 2026-07-10: OpenAI https://developers.openai.com/api/docs/models and Anthropic https://platform.claude.com/docs/en/about-claude/models/overview
Default Claude Code client compact/display target for this local proxy: CLAUDE_CODE_MAX_CONTEXT_TOKENS=400000
Default Claude Code auto compact target for this local proxy: CLAUDE_CODE_AUTO_COMPACT_WINDOW=400000
Important: the 400k values are not the model context window and not proof of the upstream OAuth-route ceiling. They only control Claude Code's local display/planning/auto-compact behavior.
Output guard: CLAUDE_CODE_MAX_OUTPUT_TOKENS=64000
Thinking guard: MAX_THINKING_TOKENS=8000
Non-streaming fallback: CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK=1
Account concurrency: 32 for one local Codex OAuth account with multiple Claude Code windows/subagents
Dynamic workflow size: workflowSizeGuideline=small in ~/.claude.json
Rate-limit scope: upstream 429 for a specific OpenAI/Codex model must be stored in `accounts.extra.model_rate_limits`, not in global `accounts.rate_limited_at/rate_limit_reset_at`. A Spark/Codex 5.3 cooldown must not block normal `gpt-5.6-sol` or `gpt-5.6-terra` work.
Stale fake limit recovery: issue #1 is fixed in the fork. When fresh Codex usage snapshots show quota headroom, the proxy clears only quota-origin `openai_model_rate_limited` entries from `accounts.extra.model_rate_limits` and preserves non-quota reasons such as `upstream_404_model_not_found`.
OpenAI OAuth 403 scope: the patched image treats OpenAI/Codex OAuth `403 Access forbidden` as a temporary cooldown, including repeated/threshold 403s. It must not set `accounts.status='error'` or `schedulable=false` for OAuth 403 HTML/Cloudflare edge blocks.
Model availability: trust request-time probes over `/v1/models`. On 2026-07-10, the local proxy returned 200 for `gpt-5.6-sol` and `gpt-5.6-terra`. The current small-fast/Haiku chain is `gpt-5.3-codex-spark -> gpt-5.6-luna -> gpt-5.4-mini`; direct `gpt-5.6-luna` requests fall back to `gpt-5.3-codex-spark`, then `gpt-5.4-mini` when Luna is unavailable.
```

Fast compact profile:

- Keep the main Claude Code model on `gpt-5.6-sol` for full-power work.
- Keep `ANTHROPIC_DEFAULT_HAIKU_MODEL=gpt-5.3-codex-spark` and `ANTHROPIC_SMALL_FAST_MODEL=gpt-5.3-codex-spark` for normal Claude Code small-fast/Haiku work, with group `model_fallbacks` from `gpt-5.3-codex-spark` to `gpt-5.6-luna`, then `gpt-5.4-mini`. Do not route main Opus/Sonnet/full-power work to Spark.
- In Claude Code 2.1.202, manual `/compact` still uses the session main model (`context.options.mainLoopModel`) and ignores `ANTHROPIC_SMALL_FAST_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL`, `CLAUDE_CODE_SUBAGENT_MODEL`, and the reverse-engineered `CLAUDE_CONTEXT_COLLAPSE_MODEL` for the legacy compact path.
- Use the patched local sub2api image plus the OpenAI account `compact_model_mapping` to reroute Claude Code compact prompts server-side. The verified 5.5-era live result was `requested_model=gpt-5.5`, `upstream_model=gpt-5.3-codex-spark`, `input_tokens=105453`, `output_tokens=4876`, `duration_ms=9427`; before the patch the same controlled compact used the main model for about `141652 ms`. For the 5.6 profile, add `gpt-5.6-sol` and `gpt-5.6-terra` to the compact mapping as aliases to Spark.
- Current fork behavior for oversized compacts: first try the compact prompt as one request on the mapped compact model. If upstream returns `response.failed` with `context_length_exceeded`, the proxy logs `openai_messages.compact_context_length_fallback`, splits the transcript into large chunks, summarizes each chunk with `gpt-5.3-codex-spark`, recursively merges the summaries, strips compact-maintenance meta-intent before final merge, retries with smaller merge groups when merge overflows, splits a single oversized intermediate summary if needed, and emits a normal Anthropic Messages response. If Spark is rate-limited/unavailable/unknown/unsupported, either before chunking or during chunk/merge fallback, the proxy logs `openai_messages.compact_model_unavailable_fallback` or `openai_messages.compact_chunk_model_unavailable_switching` and continues compacting on `gpt-5.6-luna`, then `gpt-5.4-mini`. If the upstream still refuses the final merge at the minimum safe group size, it emits a deterministic emergency `# Compact Capsule` instead of surfacing a 502. Live verification on 2026-07-08: usage row `4646` had `requested_model=gpt-5.5`, `upstream_model=gpt-5.3-codex-spark`, `input_tokens=225195`, `output_tokens=12864`, `duration_ms=42177`, `model_mapping_chain=gpt-5.5→gpt-5.3-codex-spark`; later row `4996` after recursive fallback had `requested_model=gpt-5.5`, `upstream_model=gpt-5.3-codex-spark`, `input_tokens=206778`, `output_tokens=8819`, `duration_ms=18792`.
- Claude Code CLI JSON may still show the requested model after the proxy reroute because the proxy preserves the original Anthropic model for client compatibility. Treat `usage_logs.upstream_model` and `model_mapping_chain` as the source of truth.
- In local paired `/compact` tests on two large sessions around 195k-206k context, `gpt-5.3-codex-spark` compacted in about 12 seconds API time while `gpt-5.4` took about 113-177 seconds. Spark produced shorter resulting contexts and comparable fact coverage.
- Compact summary quality eval on the local fork is enforced by focused Go tests: `TestAnthropicCompactQualityContractEval`, `TestRetryAnthropicCompactFallbackSummariesSplitsSingleOversizedSummary`, `TestSanitizeAnthropicCompactSummaryForMergeDropsMetaIntentBlock`, `TestBuildAnthropicCompactMergePromptSanitizesMetaIntent`, and `TestForwardAsAnthropic_ClaudeCodeCompactRecursivelyMergesWhenMergeContextExceeded`. Micro-benchmark on a synthetic 24-summary merge was about `10.1ms/op` for grouping/sanitizer/emergency cap on Windows/AMD Ryzen 9 7845HX.

Compact quality and recovery pattern:

- Treat GitHub compact helpers as patterns, not drop-in truth. `compact-plus` is the strongest public pattern found: precompact state capture, transcript backup, postcompact marker, and next-prompt recovery. The local setup implements the same shape with a lightweight `compact-recovery.mjs` hook and keeps the heavy summarization in sub2api.
- Install the hook with `scripts/install-claude-compact-recovery.ps1` from this skill. It adds:
  - `PreCompact manual|auto` -> save cwd/transcript/git snapshot.
  - `PostCompact manual|auto` -> mark recovery needed.
  - `UserPromptSubmit` -> inject one small `<post-compact-recovery>` context block, then clear the flag.
  - `SessionStart` matcher `compact` -> same recovery path when Claude starts/resumes after compaction.
- The recovery context must stay small. It should remind the agent that the active task is the latest non-`/compact` user request, prefer `# Compact Capsule`, and verify files/logs/tests before claiming done.

Compact success vs immediate refill:

- Do not assume `/compact` failed only because Claude Code still shows a high `Ctx` value afterward. First inspect the session JSONL for the compact boundary: a `Compacted` tool/result line followed by a compact summary line means the compact itself completed.
- A proven failure pattern on this machine: `/compact` succeeded, then Claude Code immediately rehydrated large rules/skills/memory attachments and the next prompt ran a broad tool such as `git status --short`, producing hundreds of output lines. The visible symptom was `Ctx` returning to about `230k` and `Context limit reached` within a few turns. That is post-compact refill/thrash, not a proxy compact failure.
- In that case, separate the two fixes: keep sub2api compact fallback healthy, but also reduce immediate post-compact context reload and avoid large raw tool outputs. Use focused commands or RTK/context-mode for status/logs instead of dumping a whole dirty worktree.
- Do not say the user interrupted unless the session transcript has an explicit user interrupt action. Claude Code UI text such as `Interrupted · What should Claude do instead?` can be produced by task/workflow state or tool lifecycle and is not proof of a manual user interrupt.
- For evidence, check the compact timestamp, summary size, and the first 20 post-compact entries in the JSONL. If large `Read ...` attachments or tool outputs appear after the compact boundary, report it as rehydration/refill with exact files or command outputs.

Why both context variables matter:

- A custom alias such as `gpt-5.5[400k]` may still show `/200k` in Claude Code because third-party/custom models fall back to a built-in 200k client default. Prefer clean model IDs such as `gpt-5.6-sol` and set context window variables explicitly.
- `CLAUDE_CODE_MAX_CONTEXT_TOKENS` makes Claude Code report the chosen `contextWindow` in JSON output.
- `CLAUDE_CODE_AUTO_COMPACT_WINDOW` makes `/context` display the chosen denominator and decides when Claude Code compacts.
- Official GPT-5.6 API docs list a 1,050,000 token context window and 128,000 max output for Sol/Terra/Luna. Official Claude docs list Fable 5, Opus 4.8, and Sonnet 5 at 1M, and Haiku 4.5 at 200k.
- For the current 5.6 proxy profile, default Claude Code to `CLAUDE_CODE_MAX_CONTEXT_TOKENS=400000` and `CLAUDE_CODE_AUTO_COMPACT_WINDOW=400000` only as a conservative client target inherited from earlier 5.5 instability. Before raising toward 1.05M, run a live long-context probe through this exact Docker proxy and account.

Why output and thinking guards matter:

- Claude Code may still report `maxOutputTokens: 32000` for custom/proxy models even when `CLAUDE_CODE_MAX_OUTPUT_TOKENS=64000` is set.
- On the sub2api OpenAI/Codex route, `MAX_THINKING_TOKENS` is not the upstream Codex reasoning control. sub2api's Anthropic-to-Responses converter maps `output_config.effort` to OpenAI `reasoning.effort` and ignores `thinking.budget_tokens`.
- Keep `MAX_THINKING_TOKENS=8000` as the normal compatibility guard for Claude Code's Anthropic-compatible client behavior. Use `12000` or `16000` only for experiments. Avoid `24000+` unless explicitly testing.
- For Codex/GPT-5.6 capability, rely on `effortLevel=max` / `--effort max`, which sub2api maps to the strongest supported OpenAI reasoning effort on this route.
- `MAX_THINKING_TOKENS=0` disables or omits the thinking parameter depending on provider behavior; use it only when the proxy/upstream rejects thinking fields or for fast/simple work.
- Set `CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK=1` for this proxy profile. The streaming path is patched locally; leaving fallback enabled can make Claude Code retry a large turn through `stream=false` with about a 1 MB body and surface `API Error: Upstream service temporarily unavailable` from a proxy 502.
- Use the patched local image. The upstream image can turn an empty OpenAI Responses stream into a successful Anthropic `message_stop`; the local patch buffers stream start until real text/tool output and converts empty streams into retryable upstream failures.
- Keep Claude Code dynamic workflows small. `/deep-research` and generated workflows can fan out many subagents; on this proxy profile, that can surface as synthetic `API Error: Upstream service temporarily unavailable` even when sub2api is returning HTTP 200. Set `workflowSizeGuideline=small` in `~/.claude.json` so new workflows aim for fewer than 5 agents.
