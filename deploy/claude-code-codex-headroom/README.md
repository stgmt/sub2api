# Claude Code + Headroom + sub2api

This profile runs a local Claude Code chain backed by a Codex/OpenAI subscription:

```text
Claude Code -> Headroom on 127.0.0.1:8787 -> sub2api on Docker DNS sub2api:8080 -> OpenAI/Codex OAuth
```

Headroom is the Claude Code-facing endpoint. sub2api still exposes `127.0.0.1:18081` for the admin UI, diagnostics, and non-Claude clients.

The Headroom image is deliberately more than a bare HTTP proxy. It installs the
full local optimization stack in Docker: `headroom-ai[proxy,code,relevance,html,spreadsheet,otel,reports,mcp]`,
RTK, lean-ctx, TokenSave, ast-grep, difft, and scc. Claude Code should not point
at stale host binaries for these tools; the setup script registers the
`headroom` MCP as a Docker-backed stdio command:

```text
wsl.exe -e docker exec -i headroom-sub2api headroom mcp serve --proxy-url http://127.0.0.1:8787
```

The image also applies downstream patches for `headroom-ai==0.31.0`:

- `patch-headroom-embedding-server.py` makes `headroom proxy
  --embedding-server` actually start a Unix-socket embedding sidecar. The
  published wheel exposes the flag but omits
  `headroom.memory.adapters.watchdog`; the local patch adds the watchdog and a
  socket embedder client used by Headroom memory workers.
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

## Skill-Assisted Setup

The Codex/Claude skill in `backend/docs/skills/sub2api-claude-code-codex` contains scripts and troubleshooting references for this profile:

```powershell
powershell -ExecutionPolicy Bypass -File backend\docs\skills\sub2api-claude-code-codex\scripts\setup-sub2api-claude-code.ps1
powershell -ExecutionPolicy Bypass -File backend\docs\skills\sub2api-claude-code-codex\scripts\verify-claude-code-sub2api.ps1
```

The setup script generates a local `.env`, starts the compose project as `sub2api-codex`, configures Claude Code to use `http://127.0.0.1:8787`, and installs a single Windows scheduled-task autostart named `Sub2API Codex Proxy Stack Autostart`.

The autostart task runs `start-sub2api-proxy-stack.ps1` with `RunLevel=Highest`, removes stale `headroom-proxy` task entries, disables Startup-folder proxy launchers, and can self-heal stale WSL `ext4.vhdx` attach locks before retrying Docker compose startup. Use `-SkipAutostart` only when you deliberately want a local/manual-only setup.

It also writes the full Headroom agent profile into `.env`:

```text
HEADROOM_SAVINGS_PROFILE=agent-90
HEADROOM_TARGET_RATIO=0.10
HEADROOM_CONTEXT_TOOL=rtk
HEADROOM_CODE_AWARE_ENABLED=1
HEADROOM_OUTPUT_SHAPER=1
HEADROOM_MID_TURN_STREAM_WAIT_MS=600000
--embedding-server
```

Use `headroom savings --json`, `headroom perf --format json`, and
`headroom tools doctor` inside the `headroom-sub2api` container to verify the
optimization layer, RTK/tool binaries, and savings ledger.
The verifier also checks persistent Headroom mounts and the `ccr_store.db`
memory store when it exists.
