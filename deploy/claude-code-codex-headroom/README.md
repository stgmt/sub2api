# Claude Code + Headroom + sub2api

This profile runs a local Claude Code chain backed by a Codex/OpenAI subscription:

```text
Claude Code -> Headroom on 127.0.0.1:8787 -> sub2api on Docker DNS sub2api:8080 -> OpenAI/Codex OAuth
```

Headroom is the Claude Code-facing endpoint. sub2api still exposes `127.0.0.1:18081` for the admin UI, diagnostics, and non-Claude clients.

The Headroom image is deliberately more than a bare HTTP proxy. It builds
`headroom-ai[proxy,code,relevance,html,spreadsheet,otel,reports,mcp]` from the
controlled `stgmt/headroom` fork and pinned `HEADROOM_GIT_REF`, then installs
RTK, lean-ctx, TokenSave, ast-grep, difft, and scc. Headroom and TokenSave stay
Docker-backed. RTK is also installed on Windows and WSL because Claude Code
executes Bash before Headroom sees the output; container-only RTK cannot rewrite
host commands. The setup script registers the `headroom` MCP as Docker-backed:

The Dockerfile installs pinned Rust `HEADROOM_RUST_TOOLCHAIN=1.88.0` via rustup
because the fork source builds through `maturin` and ships Headroom's Rust
extension in the Python wheel. Debian's older distro Rust may fail this build.

```text
wsl.exe -e docker exec -i headroom-sub2api headroom mcp serve --proxy-url http://127.0.0.1:8787
```

The fork already carries our Claude Code recovery fixes. The image still applies
the local patch scripts as idempotent guardrails so an overridden older ref does
not silently regress:

- `patch-headroom-embedding-server.py` makes `headroom proxy
  --embedding-server` start a Unix-socket embedding sidecar and keep memory
  workers on the sidecar-backed `SocketEmbedderClient`.
- `patch-headroom-claude-code-streaming.py` makes the Anthropic streaming path
  Claude Code-safe. The upstream wheel can return private HTTP 202
  `headroom_queued` responses during mid-turn overlap; Claude Code expects
  Anthropic SSE events and reports `Stream ended without receiving any events`.
  The patch keys active streams by Claude session plus agent id and waits for
  overlap drain instead of returning 202.

All service state is persisted on the Docker host under
`${SUB2API_STATE_ROOT:-./data}`. The compose profile bind-mounts host
directories for Headroom memory, embedding/model caches, sub2api app data,
Postgres, and Redis. It intentionally does not use Docker named volumes for
state. Do not delete the state root unless you intend to wipe memory,
embeddings, accounts, database state, and warmed caches.

The image entrypoint is `/usr/local/bin/start-headroom-proxy`, not `headroom`
directly. It seeds fresh persistent mounts from `/opt/headroom-seed` before
launching `headroom proxy`, which keeps first-run volumes from hiding bundled
RTK/lean-ctx/difft/scc assets.

## Quick Start

From the repository root:

```powershell
Copy-Item deploy\claude-code-codex-headroom\.env.example deploy\claude-code-codex-headroom\.env
# Edit deploy\claude-code-codex-headroom\.env and replace every change_this_* value.
docker compose --env-file deploy\claude-code-codex-headroom\.env -f deploy\claude-code-codex-headroom\docker-compose.yml -p sub2api-codex up -d --build
```

Then open the sub2api admin UI at `http://127.0.0.1:18081`, add the Codex/OpenAI account, create a sub2api API key, and point Claude Code at Headroom:

```powershell
[Environment]::SetEnvironmentVariable("ANTHROPIC_BASE_URL", "http://127.0.0.1:8787", "User")
[Environment]::SetEnvironmentVariable("ANTHROPIC_AUTH_TOKEN", "<sub2api-api-key>", "User")
```

Verify the chain:

```powershell
Invoke-RestMethod http://127.0.0.1:8787/health
Invoke-RestMethod http://127.0.0.1:18081/health
```

The Headroom health response should report `ready: true`, version `0.31.0`, and upstream `http://sub2api:8080`.

## CUDA Acceleration

The default image target remains CPU-compatible. On an NVIDIA host, select the
CUDA profile in `.env` and include the GPU overlay:

```text
HEADROOM_ACCELERATOR=cuda
HEADROOM_DOCKER_TARGET=gpu
HEADROOM_KOMPRESS_BACKEND=pytorch
```

```powershell
docker compose --env-file deploy\claude-code-codex-headroom\.env `
  -f deploy\claude-code-codex-headroom\docker-compose.yml `
  -f deploy\claude-code-codex-headroom\docker-compose.gpu.yml `
  -p sub2api-codex up -d --build
```

The GPU stage installs pinned CUDA 12.8 PyTorch, while the overlay requests all
Docker GPUs and selects Headroom's native batched PyTorch Kompress path. The
setup script auto-detects NVIDIA in WSL/Windows unless `-HeadroomAccelerator
cpu` is passed. The autostart script reads `HEADROOM_ACCELERATOR` from `.env`
and reapplies the overlay after reboot.

Verify the runtime and run the deterministic benchmark:

```powershell
docker exec headroom-sub2api python -c "import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0))"
docker exec headroom-sub2api benchmark-headroom-kompress --require-cuda
```

## Skill-Assisted Setup

The Codex/Claude skill in `backend/docs/skills/sub2api-claude-code-codex` contains scripts and troubleshooting references for this profile:

```powershell
powershell -ExecutionPolicy Bypass -File backend\docs\skills\sub2api-claude-code-codex\scripts\setup-sub2api-claude-code.ps1
powershell -ExecutionPolicy Bypass -File backend\docs\skills\sub2api-claude-code-codex\scripts\verify-claude-code-sub2api.ps1
```

The setup script generates a local `.env`, starts the compose project as `sub2api-codex`, configures Claude Code to use `http://127.0.0.1:8787`, and installs a single Windows scheduled-task autostart named `Sub2API Codex Proxy Stack Autostart`.

It also installs pinned RTK on Windows and WSL, adds one MSYS-safe global Claude Code `PreToolUse(Bash)` rewrite hook, configures exact-output exclusions, and bind-mounts the host RTK history into Headroom. Run the focused installer directly only when repairing that layer:

```powershell
powershell -ExecutionPolicy Bypass -File backend\docs\skills\sub2api-claude-code-codex\scripts\install-claude-rtk.ps1
```

The autostart task runs `start-sub2api-proxy-stack.ps1` with `RunLevel=Highest`, removes stale `headroom-proxy` task entries, disables Startup-folder proxy launchers, and can self-heal stale WSL `ext4.vhdx` attach locks before retrying Docker compose startup. Use `-SkipAutostart` only when you deliberately want a local/manual-only setup.

It also writes the full Headroom agent profile into `.env`:

```text
HEADROOM_GIT_REPO=https://github.com/stgmt/headroom.git
HEADROOM_GIT_REF=<pinned stgmt/headroom commit>
HEADROOM_ACCELERATOR=<auto|cpu|cuda>
HEADROOM_DOCKER_TARGET=<cpu|gpu>
HEADROOM_KOMPRESS_BACKEND=<auto|pytorch>
SUB2API_GIT_REPO=https://github.com/stgmt/sub2api.git
SUB2API_GIT_REF=<current stgmt/sub2api commit or local>
HEADROOM_SAVINGS_PROFILE=agent-90
HEADROOM_TARGET_RATIO=0.10
HEADROOM_CONTEXT_TOOL=rtk
HEADROOM_RTK_WIRING=enabled
HEADROOM_RTK_STATE_ROOT=<host RTK state path translated for the Docker host>
HEADROOM_CODE_AWARE_ENABLED=1
HEADROOM_OUTPUT_SHAPER=1
HEADROOM_MID_TURN_STREAM_WAIT_MS=600000
--embedding-server
```

Use `headroom savings --json`, `headroom perf --format json`, and
`headroom tools doctor` inside the `headroom-sub2api` container to verify the
optimization layer, RTK/tool binaries, and savings ledger.
The verifier also checks the Git Bash -> WSL RTK rewrite, matching host/container
RTK totals, persistent Headroom mounts, and the `ccr_store.db` memory store when
it exists. A manual `rtk` command inside the container is not proof that Claude
Code uses the hook.
