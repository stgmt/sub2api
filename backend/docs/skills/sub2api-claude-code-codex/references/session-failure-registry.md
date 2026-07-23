# Session Failure Registry

Use this registry before changing the stack when a failure resembles a prior
incident. It records failure classes observed during the July 2026 Claude Code,
Headroom, sub2api, WSL, Hyper-V, RTK, compact, and delegated-agent work.

## How To Use It

1. Locate the Claude session JSONL and exact failing request timestamp.
2. Follow one request across Claude Code, Headroom, sub2api, and the selected
   provider/account. Do not infer the failing layer from the terminal message.
3. Match the symptom to one or more IDs below.
4. Apply the stated guardrail and produce the required proof.
5. If the mechanism is new, add a new ID, a focused regression test or eval,
   and live runtime evidence before calling the repair complete.

Minimum trace packet:

- Claude session ID, agent ID when present, timestamp, model, and effort;
- Headroom request ID, transform markers, handler outcome, and upstream URL;
- sub2api usage or error row with requested model, mapped/upstream model,
  account, reasoning effort, status, and provider error;
- running container image revision, effective env, compose files, mounts, and
  health state when runtime behavior is involved.

## Routing And Context

| ID | Observed failure | Mechanism and guardrail | Required proof |
|---|---|---|---|
| `F01` | A popular proxy was selected, then current Claude models or protocol features failed. | Repository popularity was treated as compatibility evidence. Compare protocol coverage, auth paths, model mapping, streaming, tests, and maintenance activity before installation. | Feature matrix plus live request probes for the required Claude Code flows. |
| `F02` | Source or settings looked fixed while Claude Code still used old behavior. | The image/container or long-lived Claude process was stale. A file diff is never runtime proof. Rebuild, recreate, restart the client when needed, and inspect the running revision. | Image labels/SHA, container create time, effective env, and a fresh request trace. |
| `F03` | `/v1/models` looked correct but a real request routed to the wrong provider. | Catalog publication and request dispatch are separate paths. Treat the catalog as discovery only. | `/v1/messages` plus `usage_logs` account, provider, mapping chain, and upstream model. |
| `F04` | Claude displayed 200k, 370k, 400k, or 1M and that number was called the upstream model limit. | Claude Code client display/compact targets were confused with provider context capacity. Never derive upstream capacity from the status bar. | Effective Claude env plus a bounded direct request experiment or current primary provider documentation. |
| `F05` | `/compact` showed progress but Sol handled the request instead of the compact model. | Headroom transformed away the native compact marker or sub2api classified the provider before compact remapping. Preserve the final compact message, add `x-sub2api-claude-compact: 1`, skip output shaping, then remap before provider selection. | Real `/compact` Headroom marker and matching sub2api row for the configured compact model/account/effort. |
| `F06` | Claude printed `Compacted`, then immediately refilled, thrashed, or still hit context overflow. | Success text proved only that a summary response was accepted; rehydrated rules, hooks, skills, tool output, or an oversized follow-up could refill the window. Do not claim a failed compact without comparing pre/post transcript state. | Pre/post `/context`, compact summary size, first post-compact request size, and attribution by content category/tool output. |
| `F07` | `/effort` changed in the UI but upstream effort did not change, or `/effort` said an env override won. | `CLAUDE_CODE_EFFORT_LEVEL` or Headroom effort routing overrode the session. Do not persist the hard override; keep `HEADROOM_EFFORT_ROUTER=0`. | Pre-Headroom request body and matching `usage_logs.reasoning_effort`; UI text alone is insufficient. |
| `F08` | Spark compact/subagent traffic carried a fabricated reasoning effort. | A model capability was assumed from another family. Omit unsupported effort fields instead of coercing them. | Captured upstream request for Spark without a reasoning-effort field and a successful response. |

## Accounts, Limits, And Errors

| ID | Observed failure | Mechanism and guardrail | Required proof |
|---|---|---|---|
| `F09` | A Spark or one-model cooldown made GPT-5.5/5.6 and unrelated chats report the same future 429. | Persisted `model_rate_limits` or scheduler state leaked across model/account scope. Cooldowns must be keyed by account and model; successful same-model reprobe clears only the matching stale entry. | Before/after account JSON, scheduler state, fresh upstream probe, and unaffected-model control. |
| `F10` | One OAuth 403 or `refresh_token_reused` produced `no available accounts`/503 everywhere. | Auth failure was converted into broad unschedulability. Use bounded adaptive cooldown for transient 403; import a newer valid host Codex auth file for refresh-token reuse; restore both active status and `schedulable=true`. | Provider error, account state transition, auth-file freshness without secret disclosure, bounded retry, and live recovery request. |
| `F11` | Claude received generic 503 although the cause was quota, auth, context, or model-not-found. | Error classification was lost at the gateway. Preserve the provider class and safe message; do not use 503 as a universal wrapper. | Correlated `ops_error_logs`, response status/body, and a contract test for the exact error class. |
| `F12` | `429 {"detail":"Rate limited. Retry after ..."}` appeared during healthy local fan-out. | Headroom's default local token bucket, not the subscription, limited all windows sharing one key/IP. The loopback profile uses high local RPM/TPM; provider limits remain separate. | `/stats.rate_limiter`, parallel burst probe, and sub2api logs showing whether traffic reached the provider. |
| `F13` | `Stream ended without receiving any events`, `incomplete chunked read`, empty 200 SSE, or 0/0 usage stopped an agent. | The transport emitted an invalid or incomplete Anthropic stream. Never "fix" parsing by blind retry alone: validate the first event, preserve replay safety, classify pre-event versus mid-stream failure, and retry only replay-safe pre-event requests inside the proxy. | Raw SSE capture, event count/order, upstream status, proxy request ID, retry count, and a completed Claude Code continuation. |
| `F14` | A Headroom request was silent for tens of minutes or returned a 504 that killed autonomy. | Timeout covered command execution but not the whole handler, or partial compression work was discarded. Use a whole-handler watchdog, cancel the primary task, retry once through safe bypass where size permits, and never fail open with an oversized prompt. | Watchdog start/cancel/retry markers, bounded wall time, no leaked task, and successful or truthful bounded response. |

## Tools, Agents, And Hooks

| ID | Observed failure | Mechanism and guardrail | Required proof |
|---|---|---|---|
| `F15` | `context-mode` `ctx_execute`/`ctx_batch_execute` remained on one tool call for hours. | The advertised command timeout did not cover post-command indexing/search/formatting; giant markdown paragraphs also became huge FTS chunks. Keep a whole-handler watchdog and bounded chunks. Treat this as MCP/plugin failure until proxy traffic proves otherwise. | MCP call start/end timestamps, watchdog kill marker, process exit, chunk-size bound, and a control request through Headroom. |
| `F16` | A fresh VM prompt failed with `No tool output found for function call call_*`. | Headroom replayed a mixed server-memory/client-tool turn without matching results. Defer client-owned calls, replay only result-backed memory calls, and remove private memory tools from the continuation. | Claude JSONL call ID, Headroom deferred-call marker, and sub2api 200 continuation. |
| `F17` | One delegated workflow produced dozens or hundreds of descendants and exhausted provider concurrency/quota. | `workflowSizeGuideline=small` and prompt wording are advisory, not a hard Claude Code depth/concurrency limit. Do not claim a built-in cap. Keep configured agent model/effort explicit, inspect the agent tree, and add a blocking hook only when the user explicitly requests one. | Parent/child agent graph, launch timestamps, model/effort per agent, peak concurrency, terminal state, and provider response distribution. |
| `F18` | RTK was installed and manual probes showed savings, but live dashboards stayed at zero. | RTK existed only in the Headroom container or the wrong OS/user. Install it where Claude Code executes Bash and keep exactly one hook. | Fresh Claude Bash debug hook success, modified tool input, host history increment, and shared container totals only when the same state is mounted. |
| `F19` | Linux hooks failed with `node`/`python` missing, or fixes worked only in a devcontainer. | Claude Code ran on the outer Ubuntu/Hyper-V host while dependencies were installed elsewhere. Determine the actual Claude binary, user, shell, and hook registry first. | Same-user `command -v`, fresh Claude process debug log, and successful real hook call. |

## Runtime, Persistence, And Verification

| ID | Observed failure | Mechanism and guardrail | Required proof |
|---|---|---|---|
| `F20` | Kompress was reported as GPU-enabled while savings were zero or CPU ONNX was active. | Host `nvidia-smi`, a GPU image, or `gpus: all` was treated as end-to-end proof. Require CUDA PyTorch and the Kompress backend itself on `cuda`; otherwise disable CPU Kompress on the hot path. | Docker `DeviceRequests`, Torch CUDA/device, `preload=pytorch`, identical-payload benchmark, sentinel retention, and a live request metric. |
| `F21` | GPU worked once, then disappeared after setup, restart, or reboot. | A bare base compose or transient WSL probe rewrote sticky CUDA state to CPU/disabled. One canonical launcher must always include the GPU overlay for a proven CUDA host; verifier probe failure must fail closed. | Effective compose file list/env after autostart, selected target, GPU inspect, CUDA preload, and scheduled-task result. |
| `F22` | Services or memory vanished, or multiple tasks raced after login. | Separate Headroom/sub2api launchers and named volumes created split ownership/state. Use one stack owner and host bind mounts for every stateful path. | Exactly one autostart owner, `LastTaskResult=0`, bind mounts for all state, nonzero persisted files, and reboot recovery. |
| `F23` | Docker health was green but Windows or a Hyper-V VM got `ConnectionRefused`. | Same-host health, WSL localhost relay, Windows portproxy, firewall, and VM routing are distinct hops. Repair only the broken hop and keep direct sub2api as diagnostic bypass. | Health from container, WSL, Windows, and VM as applicable, current WSL/VM IPs, portproxy/firewall state, and Claude-host request. |
| `F24` | Tests passed while the user-visible failure remained, or broad tests ran during an analysis-only request. | Verification scope did not match the requested operation or live failure. Respect `analysis/report only`; for fixes, use focused tests plus mutation/negative proof and live runtime trace. Never treat source assertions as service behavior. | Stated task mode, focused test names, negative control, rebuilt runtime revision, and reproduction from the original client. |
| `F25` | `/stats` showed only the current process after restart although saved request logs still existed. | Runtime counters were mistaken for lifetime analytics and `RequestLogger` never hydrated its persisted JSONL. Keep runtime scope explicit, rebuild `request_history` from unique completed request IDs, skip malformed lines, and never let `/stats/reset` truncate history. | Bind-mounted log path, stable totals/range across restart, exact +1 after fresh traffic, and the same value after a second restart. |
| `F26` | A stale Claude host emitted `claude-haiku-*`; sub2api returned fast `404 no available accounts` although Qwen was healthy. | Mixed-provider routing classified Claude aliases as native Anthropic before applying explicit group mappings. Apply explicit family/exact aliases before provider classification, keep them hidden from `/v1/models`, and route the compatibility inputs to the configured Qwen model. | Original alias in the inbound trace, focused rewrite/classification tests, rebuilt image, response model Qwen, and `usage_logs` on the Alibaba account with the requested effort. |
| `F27` | A Hyper-V Windows Claude host intermittently got `ECONNRESET` while containers were healthy. | The guest used the ephemeral WSL `eth0` address and the scheduled task retained a removed VM name; its sidecar env could not override the stale task argument. Make the Default Switch bridge required, let `hyperv-bridge.env` override embedded task values, and use bridge-only mode for Windows guests without SSH. | Current VM/switch/WSL addresses, one `v4tov4` entry targeting current WSL, VM-scoped firewall, bridge `/health=200`, and a fresh request from the guest after one-time base-URL update. |

## Non-Negotiable Delivery Rules

- Diagnose the failing layer before mutating state. Health endpoints alone do
  not identify the layer.
- Do not add a fallback, lower effort, disable agents, install a blocking hook,
  clear account state, or delete persistent data unless the user requested that
  policy or evidence makes it the only safe recovery.
- Preserve unrelated worktree changes and secrets. Report secret presence, not
  secret values.
- When code, docs, skill, and installed runtime all change, finish all four:
  focused tests, rebuild/recreate, live proof, then skill sync and push.
- A claim is only as strong as its weakest proof. UI labels, model catalogs,
  source diffs, health checks, and synthetic probes each prove one narrow fact;
  none proves the full request path by itself.
