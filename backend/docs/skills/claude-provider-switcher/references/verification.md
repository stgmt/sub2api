# Verification And Rollback

## Per-Switch Proof

Capture a switch timestamp and request correlation IDs. Verify through Headroom, not the direct sub2api port:

1. tiny interactive main request;
2. picker/default model resolution;
3. selected `/effort` preservation where the target model supports it;
4. manual compact or compact-marker probe;
5. `claude -p` request;
6. ordinary named subagent;
7. nested subagent;
8. resumed request containing an explicit stale provider model ID.

For every row, record requested model, mapped model, provider account ID/platform, reasoning effort, status, and duration from sub2api usage/error logs.

Run `claude-route verify` for the reproducible first pass. It uses a unique User-Agent correlation ID so concurrent user sessions cannot pollute its four-row proof. Follow with a real `claude --print` and a named-agent probe when changing the profile implementation.

## Negative Proof

- `anthropic-only`: after the switch timestamp, no new OpenAI/Codex or Alibaba account usage may appear for the stable key.
- `hybrid-current`: main must use OpenAI/Codex; delegated/compact/SDK traffic must use Alibaba while healthy; native Anthropic must receive no traffic unless the profile version explicitly allows it.

Catalog output and UI labels are supporting evidence only.

## Fleet Matrix

Run main, compact, `claude -p`, ordinary subagent, named subagent, nested subagent, and stale-session probes on every reachable node. Also inspect project-local settings that may override user config.

## Rollback

Rollback the stable key binding when the target group cannot pass the first Headroom main probe, cache invalidation fails, or the target account is invalid. Do not roll back merely because a VM is offline or its display config is stale.

After rollback, prove one request on the previous provider and retain the failed generation with error evidence for diagnosis.

A target-provider 429/503 is a failed switch, not a reason to commit the target profile. The stable key must remain on the last verified group.
