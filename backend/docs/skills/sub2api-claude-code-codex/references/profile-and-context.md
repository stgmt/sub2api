# Profile And Context Windows

Source-of-truth profile, GPT-5.6 defaults, compact profile, and context-window caveats extracted from the previous monolithic skill.

## Source Of Truth

Prefer this profile unless the user explicitly asks for a different model or port:

```text
Proxy chain: Headroom -> sub2api
Source fork: https://github.com/stgmt/sub2api
Source branch: main
Verified fork baseline: main; embedding-server patch landed in 84917aec fix: enable headroom embedding sidecar
Fixed issue: https://github.com/stgmt/sub2api/issues/1
Headroom image: headroom-sub2api:0.31.0 built from `HEADROOM_GIT_REPO=https://github.com/stgmt/headroom.git` at pinned `HEADROOM_GIT_REF` with `HEADROOM_RUST_TOOLCHAIN=1.88.0`, plus RTK, lean-ctx, TokenSave, ast-grep, difft, scc, and idempotent downstream embedding-server plus Claude Code streaming-overlap patch guardrails
Headroom profile: agent-90, target ratio 0.10, context tool RTK, code-aware compression enabled, output shaper enabled
Headroom embedding server: enabled via `--embedding-server`; Dockerfile applies `deploy/claude-code-codex-headroom/patch-headroom-embedding-server.py`, adding `headroom.memory.adapters.watchdog`, `EmbeddingServerWatchdog`, and `SocketEmbedderClient` so memory workers use `/tmp/headroom-embed-8787.sock` instead of per-worker embedders
Headroom Claude Code stream safety: Dockerfile also applies `deploy/claude-code-codex-headroom/patch-headroom-claude-code-streaming.py`; this prevents Headroom from returning private HTTP 202 `headroom_queued` responses to Claude Code streaming `/v1/messages` requests, keys active streams by Claude session plus agent id, and waits up to `HEADROOM_MID_TURN_STREAM_WAIT_MS=600000` for overlap drain
Host state root: `${SUB2API_STATE_ROOT:-./data}`. The deploy profile must bind-mount all state to host directories under this root, not Docker named volumes.
Headroom persistent storage: `/root/.headroom` stores `ccr_store.db`, savings, logs, and subscription state; `/root/.cache/headroom` and `/root/.cache/huggingface` store warmed local Headroom/HuggingFace model and embedding caches. The deploy profile bind-mounts all three from the host so container recreate does not wipe memory/embeddings/caches.
Headroom bootstrap: image entrypoint `/usr/local/bin/start-headroom-proxy` seeds fresh persistent mounts from `/opt/headroom-seed` before starting `headroom proxy`, without overwriting existing files. This prevents empty first-run volumes from hiding bundled RTK/lean-ctx/difft/scc assets.
Headroom MCP: user-level Claude MCP named headroom, launched through Docker with `wsl.exe -e docker exec -i headroom-sub2api headroom mcp serve --proxy-url http://127.0.0.1:8787`
sub2api image: sub2api-codex:local-token-usage
Deploy profile: deploy/claude-code-codex-headroom
Claude base URL: http://127.0.0.1:8787
Headroom upstream: http://sub2api:8080 inside the Docker network
Direct sub2api URL: http://127.0.0.1:18081 for admin UI, diagnostics, and non-Claude clients only
Docker-in-WSL fallback: if Windows cannot reach 127.0.0.1:8787 but WSL/Docker can, publish Headroom on 0.0.0.0 and point Claude Code to http://<wsl-primary-ip>:8787; do not use :18081 as the normal Claude Code endpoint
Upstream platforms: OpenAI/Codex OAuth for GPT/Codex models and Alibaba Token Plan through its Anthropic-compatible endpoint for qwen*/glm*/deepseek-v4-pro
Claude Code model: gpt-5.6-sol
Claude Code small-fast model: qwen3.8-max-preview with effort high
Claude Code picker category defaults: Opus/Fable/Sonnet/Haiku are pinned to Qwen high (`qwen3.8-max-preview`, display name `Qwen 3.8 Max`)
Claude Code subagent overrides: qwen3.8-max-preview with effort high for all user-level subagents
Upstream main model: gpt-5.6-sol
Alibaba Token Plan aliases: qwen3.8-max-preview, qwen3.7-max, qwen3.7-plus, qwen3.6-flash, glm-5.2, deepseek-v4-pro
Upstream compact model: qwen3.8-max-preview via group messages_dispatch_model_config.compact_mapped_model
Compact fallback: none by default; do not add normal or compact fallbacks unless the user explicitly asks
Manual /compact routing: patched sub2api detects Claude Code compact prompts on /v1/messages and rewrites the model before provider classification so GPT/Codex sessions compact through the Alibaba Token Plan Anthropic-compatible route
Large compact fallback: if the mapped compact model returns context_length_exceeded, patched sub2api summarizes transcript chunks with the compact model, recursively merges the chunk summaries, splits oversized intermediate summaries again when merge overflows, and returns one Anthropic-compatible compact response
Compact quality guard: final compact prompt requires a `# Compact Capsule` with Current State, Active User Intent, Files Touched, Commands And Evidence, Errors And Blockers, Decisions And Config, and Next Command
Compact meta-intent sanitizer: before final merge, patched sub2api strips intermediate summary lines that misclassify compact maintenance as the active task, such as "produce a merged/detailed compact summary", "prior chunking", "context compaction", or "merge chunk summaries"
Compact recovery hook: optional Claude Code PreCompact/PostCompact/UserPromptSubmit hook writes a small recovery state and injects it once after compaction so the agent does not treat the compact request as the real user task
Reasoning: main GPT-5.6 max should reach upstream/usage as max; delegated Qwen subagents and compact use high by frontmatter/env/group compact mapping
Official GPT-5.6 context window: 1,050,000 tokens with 128,000 max output for Sol/Terra/Luna.
Official GPT-5.3-Codex-Spark context window: 128,000 tokens and text-only during the research preview; official OpenAI launch notes also describe separate rate limits and possible temporary queuing under high demand.
Official Claude context windows: Fable 5, Opus 4.8, and Sonnet 5 are 1M; Haiku 4.5 is 200k.
Official context docs checked on 2026-07-10: OpenAI https://developers.openai.com/api/docs/models and Anthropic https://platform.claude.com/docs/en/about-claude/models/overview
Official Alibaba docs checked on 2026-07-22: Token Plan lists Qwen3.8-Max-Preview, GLM-5.2, and DeepSeek-V4-Pro (https://www.alibabacloud.com/en/campaign/ai-landing-page-token); Model Studio text-generation docs recommend qwen3.7-plus for balanced coding, qwen3.7-max for strongest reasoning, list qwen3.7-plus/qwen3.6-flash/deepseek-v4-pro at 1M context, and list glm-5.2 at 198k context (https://www.alibabacloud.com/help/en/model-studio/text-generation-model). Treat live Headroom/sub2api probes as authoritative for this local account because Token Plan availability can vary by region/account.
Default Claude Code client compact/display target for this local proxy: CLAUDE_CODE_MAX_CONTEXT_TOKENS=370000
Default Claude Code auto compact target for this local proxy: CLAUDE_CODE_AUTO_COMPACT_WINDOW=340000
Important: these values are Claude Code local display/planning/auto-compact behavior. The upstream proxy/model is still authoritative; verify real failures in sub2api logs and `ops_error_logs`.
Output guard: CLAUDE_CODE_MAX_OUTPUT_TOKENS=64000
Thinking guard: MAX_THINKING_TOKENS=8000
Non-streaming fallback: CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK=1
Account concurrency: 32 for one local Codex OAuth account with multiple Claude Code windows/subagents
Dynamic workflow size: workflowSizeGuideline=small in ~/.claude.json; this is advisory, not a hard cap
Rate-limit scope: upstream 429 for a specific OpenAI/Codex model must be stored in `accounts.extra.model_rate_limits`, not in global `accounts.rate_limited_at/rate_limit_reset_at`. A Spark/Codex 5.3 cooldown must not block normal `gpt-5.6-sol` or `gpt-5.6-terra` work.
Stale fake limit recovery: issue #1 is fixed in the fork. When fresh Codex usage snapshots show quota headroom, the proxy clears only quota-origin `openai_model_rate_limited` entries from `accounts.extra.model_rate_limits` and preserves non-quota reasons such as `upstream_404_model_not_found`.
OpenAI OAuth 403 scope: the patched image uses adaptive consecutive-failure cooldowns `2s -> 15s -> 1m -> 5m`, gives `/v1/messages` one bounded same-request retry after the first cooldown, and clears only the OAuth 403 counter/temp state after a successful OpenAI response. It must not set `accounts.status='error'` or `schedulable=false`, and must not clear unrelated model/quota rate limits.
OpenAI OAuth 401 recovery: refreshed credentials must restore both `status='active'` and `schedulable=true`. The fork patches `ClearAccountError` so `apply-oauth-credentials` does not leave a recovered Codex account invisible to scheduling.
Persistence warning: do not delete `${SUB2API_STATE_ROOT:-./data}` unless the user explicitly asks to wipe Headroom memory/embeddings and sub2api state. Use `docker compose up -d --build` or recreate individual services without deleting the host state root.
Model availability: trust request-time probes over source edits. On 2026-07-22 after the Qwen-high picker correction, direct sub2api and restarted Headroom `/v1/models` both returned 23 models: GPT/Codex plus Alibaba Token Plan only, with no raw `opus`, `fable`, `sonnet`, `haiku`, or `claude-*` provider aliases. Live probes showed Qwen/GLM/DeepSeek requests using the Alibaba Token Plan account and GPT/Spark/Terra using the OpenAI/Codex account.
```

Subagent fan-out profile:

- User-level override paths: `%USERPROFILE%\.claude\agents\general-purpose.md`, `Explore.md`, and `workflow-subagent.md`.
- Current override: `model: qwen3.8-max-preview` plus `effort: high` for all user-level subagents. Keep normal message fallbacks empty unless the user explicitly asks for fallback behavior.
- Current User env pairing: `ANTHROPIC_SMALL_FAST_MODEL=qwen3.8-max-preview`, picker category defaults `ANTHROPIC_DEFAULT_OPUS_MODEL=qwen3.8-max-preview`, `ANTHROPIC_DEFAULT_FABLE_MODEL=qwen3.8-max-preview`, `ANTHROPIC_DEFAULT_SONNET_MODEL=qwen3.8-max-preview`, `ANTHROPIC_DEFAULT_HAIKU_MODEL=qwen3.8-max-preview`, display names `Qwen 3.8 Max`, and `CLAUDE_CODE_SUBAGENT_MODEL=qwen3.8-max-preview`. This makes compact/small-fast/subagents practical Qwen-high paths while the lead session can remain on `gpt-5.6-sol`.
- Advisory prompt guardrails in that file: no more than 10 sibling subagents for one task, and no agent chains deeper than two subagent levels below the lead session.
- Do not install a global `PreToolUse` / `SubagentStart` / `SubagentStop` hook that blocks Agent calls unless the user explicitly asks for a hard guard. The current machine policy is non-blocking/advisory.
- Official Claude Code dynamic workflows still have their own runtime limits: up to 16 concurrent agents and 1000 total agents per workflow run. `workflowSizeGuideline=small` only tells Claude to aim smaller; it is not an enforced concurrency or depth limit. Do not rely on any claimed built-in depth cap as protection against runaway fan-out: local sessions have shown one parent task line reaching hundreds of spawned descendants.
- Live Terra c10 replay on 2026-07-10 through Headroom/sub2api: 10 historical `general-purpose` prompts launched at concurrency 10, 9 completed successfully, 1 hit the local 900s timeout, and there were 0 Terra API errors. Postgres evidence for the run: 238 `gpt-5.6-terra -> gpt-5.6-terra` rows, about 2.26M input tokens and 108.4k output tokens, with aggregate per-request output throughput about 41 tok/s and wall-effective output throughput about 120 tok/s.
- Alibaba role bench on 2026-07-22 through Headroom/sub2api used exact-JSON, compact-sentinel, and subagent-review prompts. That small role bench is not a large-session compact proof. Spark baseline was strongest for short small-fast/compact (`avg_s=3.8`, `avg_score=100`). Among Alibaba models, `qwen3.8-max-preview` was the best short quality pick (`avg_s=14.4`, `avg_score=100`), while `qwen3.7-plus`, `qwen3.6-flash`, `glm-5.2`, and `deepseek-v4-pro` had quality or visible-output caveats on those short role/review probes.
- Large summary rebench on 2026-07-22 used direct sub2api `/v1/messages` with `output_config.effort=high`, a synthetic Claude Code transcript, required sentinel retention, and no Headroom pre-compression. At about 225k-237k input tokens, these all returned HTTP 200 and scored 12/12 sentinels: `deepseek-v4-pro` 29.2s/234k in/1508 out, `glm-5.2` 35.3s/225k in/965 out, `qwen3.7-plus` 39.7s/237k in/1567 out, `qwen3.7-max` 52.5s/237k in/2118 out, and `qwen3.8-max-preview` 53.5s/237k in/1530 out. `qwen3.6-flash` failed the same 237k class with HTTP 502 but passed a smaller 106k input summary in 19.8s. `gpt-5.3-codex-spark` has no effort knob, passed a 101k input summary in 4.8s with 12/12 sentinels, and failed the 237k class with empty-output 502. Near-1M proof: `qwen3.8-max-preview` high passed a 955,733 count-token / 903,849 usage-token summary in 192.2s with 12/12 sentinels. Treat this as proof for near-1M Qwen summary, not as proof that Qwen should replace Spark for short small-fast or Terra-medium for subagents.
- A failed earlier "Terra" attempt was invalid because the worker still hardcoded `gpt-5.3-codex-spark`. The bench harness was patched to pass `-Model` into every worker and to read worker status files before computing ok/error totals.
- Fresh Luna probe after the prior cooldown reset on 2026-07-10 returned HTTP 200 but did not prove native Luna; `ops_error_logs` recorded a recovered upstream 429 "The usage limit has been reached" for Luna. Treat Luna as unavailable until a request-time probe shows `model_mapping_chain` ending in `gpt-5.6-luna`.

Fast compact profile:

- Keep the main Claude Code model on `gpt-5.6-sol` for full-power work.
- Keep `ANTHROPIC_SMALL_FAST_MODEL=qwen3.8-max-preview` for compact/small-fast work in the current Qwen-high profile. Qwen3.8 Max is the proven near-1M Alibaba summary candidate; the live 2026-07-22 proof used high effort and retained 12/12 sentinels at about 904k usage input tokens.
- In Claude Code 2.1.202, manual `/compact` still uses the session main model (`context.options.mainLoopModel`) and ignores `ANTHROPIC_SMALL_FAST_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL`, `CLAUDE_CODE_SUBAGENT_MODEL`, and the reverse-engineered `CLAUDE_CONTEXT_COLLAPSE_MODEL` for the legacy compact path.
- Use the patched local sub2api image plus group `messages_dispatch_model_config.compact_mapped_model=qwen3.8-max-preview` to reroute Claude Code compact prompts server-side before provider classification. This is required because account `compact_model_mapping` runs inside the OpenAI/Codex path and cannot safely cross-route to Alibaba/Qwen.
- Legacy OpenAI-only oversized compact behavior: first try the compact prompt as one request on the mapped OpenAI compact model. If upstream returns `response.failed` with `context_length_exceeded`, the proxy logs `openai_messages.compact_context_length_fallback`, splits the transcript into chunks, recursively merges summaries, strips compact-maintenance meta-intent before final merge, and can fall back from Spark to Luna. Live verification on 2026-07-08: usage row `4646` had `requested_model=gpt-5.5`, `upstream_model=gpt-5.3-codex-spark`, `input_tokens=225195`, `output_tokens=12864`, `duration_ms=42177`, `model_mapping_chain=gpt-5.5→gpt-5.3-codex-spark`; later row `4996` after recursive fallback had `requested_model=gpt-5.5`, `upstream_model=gpt-5.3-codex-spark`, `input_tokens=206778`, `output_tokens=8819`. Current Qwen-high compact is a cross-provider `/v1/messages` rewrite before classification; prove it with `requested_model/upstream_model=qwen3.8-max-preview` and `reasoning_effort=high`.
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
- For the current 5.6 proxy profile, default Claude Code to `CLAUDE_CODE_MAX_CONTEXT_TOKENS=370000` and `CLAUDE_CODE_AUTO_COMPACT_WINDOW=340000`. This fixes Claude Code's `/200k` fallback for custom/proxy models while forcing compaction before the local route's observed long-context danger zone. Do not call 370k or 340k the upstream model limit; they are client safety thresholds.

Why output and thinking guards matter:

- Claude Code may still report `maxOutputTokens: 32000` for custom/proxy models even when `CLAUDE_CODE_MAX_OUTPUT_TOKENS=64000` is set.
- On the sub2api OpenAI/Codex route, `MAX_THINKING_TOKENS` is not the upstream Codex reasoning control. sub2api's Anthropic-to-Responses converter maps `output_config.effort` to OpenAI `reasoning.effort` and ignores `thinking.budget_tokens`.
- Keep `MAX_THINKING_TOKENS=8000` as the normal compatibility guard for Claude Code's Anthropic-compatible client behavior. Use `12000` or `16000` only for experiments. Avoid `24000+` unless explicitly testing.
- For Codex/GPT-5.6 capability, use `/effort max` or `--effort max` when a specific session needs the ceiling. Keep `effortLevel=xhigh` as the normal startup default so Claude Code users can change effort interactively. sub2api should preserve GPT-5.6 `reasoning.effort=max`; `requested_effort=max` with `upstream_effort=xhigh` means a stale image or legacy fallback path is still active.
- Never persist `CLAUDE_CODE_EFFORT_LEVEL=max` in Windows User/System env or `~/.claude/settings.json env`. That variable has higher priority than `/effort` and makes Claude Code print `CLAUDE_CODE_EFFORT_LEVEL=max overrides this session`. Clear it when repairing the profile.
- `MAX_THINKING_TOKENS=0` disables or omits the thinking parameter depending on provider behavior; use it only when the proxy/upstream rejects thinking fields or for fast/simple work.
- Set `CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK=1` for this proxy profile. The streaming path is patched locally; leaving fallback enabled can make Claude Code retry a large turn through `stream=false` with about a 1 MB body and surface `API Error: Upstream service temporarily unavailable` from a proxy 502.
- Use the patched local image. The upstream image can turn an empty OpenAI Responses stream into a successful Anthropic `message_stop`; the local patch buffers stream start until real text/tool output and converts empty streams into retryable upstream failures.
- Treat `workflowSizeGuideline=small` as a weak hint and warning-threshold tweak only. It did not prevent observed local fan-out into hundreds of descendants. `/deep-research` and generated workflows can still spawn very large agent trees; on this proxy profile, that can surface as synthetic `API Error: Upstream service temporarily unavailable` even when sub2api is returning HTTP 200. Without an explicit hard-blocking hook, real controls are: do not launch broad workflows, stop them from `/workflows`, disable workflows for a session/profile when needed, or ask for a narrow deterministic slice.
