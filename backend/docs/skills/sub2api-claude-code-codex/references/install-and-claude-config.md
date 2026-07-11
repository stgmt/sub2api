# Install And Claude Code Config

Docker/WSL install, OAuth import, Claude Code config, dynamic MCP loading, and project memory/rules guidance.

## Workflow

1. Confirm the user has Docker available. The default Claude Code endpoint is Headroom at `http://127.0.0.1:8787`; sub2api's direct `http://127.0.0.1:18081` port is for the admin UI and diagnostics.
2. Install or repair the Headroom + sub2api compose profile using `scripts/setup-sub2api-claude-code.ps1`.
3. Import an OpenAI/Codex OAuth account into sub2api.
4. Configure a sub2api OpenAI group for `/v1/messages` dispatch.
5. Create a sub2api API key for Claude Code.
6. Configure Claude Code env/settings.
7. Verify Headroom `/health`, sub2api `/health`, `/context`, a real Claude Code request through Headroom, and sub2api usage logs.

## Docker Install

Use the bundled setup script from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\setup-sub2api-claude-code.ps1
```

The script writes `deploy/claude-code-codex-headroom/.env`, starts the compose project `sub2api-codex`, configures Claude Code environment values, and registers the Docker-backed Headroom MCP server. It intentionally does not embed anyone's real OAuth refresh token or sub2api API key.

Run it from a cloned `stgmt/sub2api` checkout, or pass `-RepoRoot` so it can find `deploy/claude-code-codex-headroom/docker-compose.yml`.

The Headroom image is the full local optimization stack, not a bare proxy:

```text
headroom-ai[proxy,code,relevance,html,spreadsheet,otel,reports,mcp]
rtk
lean-ctx
tokensave
ast-grep
difft
scc
```

It also applies `deploy/claude-code-codex-headroom/patch-headroom-embedding-server.py`.
This downstream patch is required for `headroom-ai==0.31.0`: the upstream CLI
has `--embedding-server`, but the published wheel omits
`headroom.memory.adapters.watchdog`. The patch adds a Unix-socket watchdog and
socket embedder client so Headroom memory workers use `/tmp/headroom-embed-8787.sock`
instead of falling back to per-worker embedders.

The default `.env` profile is `HEADROOM_SAVINGS_PROFILE=agent-90`, `HEADROOM_TARGET_RATIO=0.10`, `HEADROOM_CONTEXT_TOOL=rtk`, `HEADROOM_CODE_AWARE_ENABLED=1`, and `HEADROOM_OUTPUT_SHAPER=1`.

Headroom persistence is part of the profile. The compose stack must persist:

- `/root/.headroom`: Headroom `ccr_store.db`, savings events, logs, and subscription state.
- `/root/.cache/headroom`: warmed Headroom tool/model cache.
- `/root/.cache/huggingface`: warmed HuggingFace/ONNX embedding model cache.

Do not run `docker compose down -v` unless the user explicitly wants to wipe Headroom memory/embeddings and sub2api state.

The image has a bootstrap entrypoint, `/usr/local/bin/start-headroom-proxy`.
It seeds fresh `/root/.headroom` and cache mounts from `/opt/headroom-seed`
without overwriting existing files, then launches `headroom proxy`. Keep this
wrapper; otherwise a clean persistent volume can hide bundled RTK/lean-ctx and
Headroom tool cache files from the image layer.

Claude Code should not point at stale host binaries for Headroom or TokenSave. If `claude mcp list` shows `C:\Users\...\headroom.exe` or `tokensave.exe` and those files are missing, remove those entries. The setup script re-adds only the `headroom` MCP through Docker:

```powershell
claude mcp remove headroom -s user
claude mcp remove tokensave -s user
claude mcp add headroom -s user -- wsl.exe -e docker exec -i headroom-sub2api headroom mcp serve --proxy-url http://127.0.0.1:8787
```

### WSL Docker Notes

On Windows, run Docker inside WSL when the user has that setup. Keep Postgres and Redis on Docker named volumes. Do not bind Postgres data to `/mnt/c`; Postgres can fail on Windows-mounted filesystems because chmod/ownership semantics are not Linux-native.

Use:

```powershell
wsl.exe -- bash -lc "docker ps"
```

If that works, use WSL Docker for `docker compose up -d`.

For Docker-in-WSL, verify Headroom first, then the direct sub2api diagnostic port:

```powershell
$wslIp = (wsl.exe -- bash -lc "ip -4 addr show eth0 | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -n1").Trim()
wsl.exe -- bash -lc "curl -sS -m 5 http://127.0.0.1:8787/health"
curl.exe --max-time 5 "http://127.0.0.1:8787/health"
curl.exe --max-time 5 "http://127.0.0.1:18081/health"
```

If Windows cannot reach `127.0.0.1:8787` but WSL/Docker can, do not chase model mapping first. The Windows localhost relay or bind is the failing layer. Set `HEADROOM_BIND_HOST=0.0.0.0` in `deploy/claude-code-codex-headroom/.env`, recreate the `headroom` service, and set Claude Code `ANTHROPIC_BASE_URL` to `http://$wslIp:8787`. Keep `:18081` as a direct sub2api admin/diagnostic bypass only.
