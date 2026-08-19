---
name: sub2api-headroom-change-safety
description: Safely diagnose, change, deploy, or review the stgmt/sub2api and stgmt/headroom proxy stack. Use before touching proxy source, runtime profiles, Docker, WSL, Hyper-V routing, or autostart recovery.
---

# Sub2API and Headroom Change Safety

Use this skill before any mutation to `stgmt/sub2api`, `stgmt/headroom`, a deployed Headroom image, or their Windows/WSL/Hyper-V runtime.

## Required gate

1. Run `scripts/preflight.ps1 -RepoRoot <sub2api checkout>` before editing. Add `-RuntimeProfile <profile path> -RequireLive` for a live-incident fix.
2. State the exact failed path as `client -> Headroom -> sub2api -> provider`; do not infer it from container health alone.
3. Change source only. Never copy a file from a runtime profile, mounted container, cache, or generated deployment directory into the source checkout.
4. Keep the diff minimal. Do not add launchers, scheduled tasks, hooks, profiles, or retries unless the user explicitly requested that mechanism.
5. Preserve the recovery invariants: normal ticks use `--no-recreate`; WSL restart requires explicit opt-in; CUDA requirements fail closed; Hyper-V bridge policy remains explicit; a paused container is repaired with `docker unpause` before Compose starts.
6. Add a regression test for the demonstrated failure. A static source assertion alone is not enough when the bug is in transport or a running image.
7. After a deploy-affecting change, run the applicable source test, rebuild/recreate only the affected service at a proven idle point, then prove the original client route with a fresh request and correlate the request log.

## Stop conditions

Stop and report instead of changing state when any of these are unknown: source checkout, deployed image, runtime profile, active request count, or original client route. Do not use a new "helper" to mask an unexplained failure.

## Completion

Run `scripts/test-change-safety-contract.ps1` and the preflight again. Report source SHA, runtime/image identity, the exact regression test, and the live route evidence. Do not claim success from `/health` alone.
