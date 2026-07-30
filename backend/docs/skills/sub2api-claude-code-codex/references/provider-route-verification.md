# Verification And Rollback

## Per-Switch Proof

Capture a switch timestamp and request correlation IDs. Verify through Headroom, not the direct sub2api port:

1. tiny interactive main request;
2. picker/default model resolution;
3. selected `/effort` preservation where the target model supports it;
4. manual compact or compact-marker probe carrying `thinking.type=adaptive` and deliberately conflicting `output_config.effort=max`; under `anthropic-only` v4 it must reach Sonnet 5, return 200, and log `reasoning_effort=low`, never Haiku's unsupported-effort 400 or inherited `max`;
5. `claude -p` request;
6. ordinary named subagent;
7. nested subagent;
8. resumed request containing an explicit stale provider model ID.

For every row, record requested model, mapped model, provider account ID/platform, reasoning effort, status, and duration from sub2api usage/error logs.

Run `claude-route verify` for the reproducible first pass. It uses a unique User-Agent correlation ID so concurrent user sessions cannot pollute its proof. Follow with a real parent turn that invokes built-in `Explore`; require the child JSONL model and correlated `(external, sdk-cli)` usage row to match the profile. `claude --agent Explore` is not sufficient because it promotes the definition to the main session and does not prove child routing.

## Negative Proof

- `anthropic-only`: after the switch timestamp, no new OpenAI/Codex or Alibaba account usage may appear for the stable key.
- `chatgpt-only`: every row must use the OpenAI OAuth account `codex-chatgpt-subscription`; no Anthropic/Alibaba account may appear. The six-probe verifier expects Sol for main, Terra-medium for stale foreign IDs, Terra-medium/medium for trusted-header compact and verified Agent SDK traffic, Sol/high for the built-in Plan composite, and clamps an explicit raw-Terra/xhigh request to Terra-medium/medium. The published catalog and observed target/upstream routes must contain neither Luna nor raw Terra.
- `hybrid-current`: main must use OpenAI/Codex; delegated/compact/SDK traffic must use Alibaba while healthy; native Anthropic must receive no traffic unless the profile version explicitly allows it.

Catalog output and UI labels are supporting evidence only.

## Fleet Matrix

Run main, compact, `claude -p`, ordinary subagent, named subagent, nested subagent, and stale-session probes on every reachable node. Also inspect project-local settings that may override user config. For `anthropic-only` v4, require Claude Code 2.1.219 or later, `claude-opus-5[1m]`/`claude-sonnet-5[1m]` in client-facing config, and both context env values at `1000000`. A server-side model rewrite or an env-only edit is insufficient: a fresh JSON `modelUsage.contextWindow` probe must report `1000000`, while sub2api usage logs must show the stripped raw model ID.

For `chatgpt-only`, require a host/WSL Codex auth SHA-256 match, an active schedulable OpenAI OAuth account, a GPT-only `/v1/models` catalog without Luna or raw Terra, empty fallbacks, clean profile check-only output, correlated delegated-child rows on Terra-medium/medium, trusted-header compact on Terra-medium/medium, a stale raw-Terra/xhigh negative probe clamped to Terra-medium/medium, and a structurally verified Plan row on Sol/high. Treat standalone `claude -p` as a main CLI request on Claude Code 2.1.219. The child route requires generic `sdk-cli` provenance plus structured `cc_entrypoint=sdk-cli; cc_is_subagent=true` and a session id; neither the User-Agent alone nor a user-message substring is sufficient. Read `plan-agent-premium-routing.md` before changing the Plan signature.

## Rollback

Rollback the stable key binding when the target group cannot pass the first Headroom main probe, cache invalidation fails, or the target account is invalid. Do not roll back merely because a VM is offline or its display config is stale.

After rollback, prove one request on the previous provider and retain the failed generation with error evidence for diagnosis.

A target-provider 429/503 is a failed switch, not a reason to commit the target profile. The stable key must remain on the last verified group.
