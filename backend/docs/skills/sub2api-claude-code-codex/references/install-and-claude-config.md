# Install And Claude Code Config

Docker/WSL install, OAuth import, Claude Code config, dynamic MCP loading, and project memory/rules guidance.

## Workflow

1. Confirm the user has Docker available. The default Claude Code endpoint is Headroom at `http://127.0.0.1:8787`; sub2api's direct `http://127.0.0.1:18081` port is for the admin UI and diagnostics.
2. Install or repair the Headroom + sub2api compose profile and host/WSL RTK hook using `scripts/setup-sub2api-claude-code.ps1`.
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

The script writes `deploy/claude-code-codex-headroom/.env`, starts the compose project `sub2api-codex`, configures Claude Code environment values, registers the Docker-backed Headroom MCP server, and installs RTK on Windows plus WSL unless `-SkipRtk` is passed. It intentionally does not embed anyone's real OAuth refresh token or sub2api API key.

Run it from a cloned `stgmt/sub2api` checkout, or pass `-RepoRoot` so it can find `deploy/claude-code-codex-headroom/docker-compose.yml`.

The Headroom image is the full local optimization stack, not a bare proxy. It
builds Headroom from the controlled fork by default:

```text
HEADROOM_GIT_REPO=https://github.com/stgmt/headroom.git
HEADROOM_GIT_REF=<pinned stgmt/headroom commit>
```

Then it installs:

```text
headroom-ai[proxy,code,relevance,html,spreadsheet,otel,reports,mcp]
rtk
lean-ctx
tokensave
ast-grep
difft
scc
```

The Dockerfile installs pinned Rust `HEADROOM_RUST_TOOLCHAIN=1.88.0` via rustup
during image construction because the fork source builds through `maturin` and
includes Headroom's Rust extension in the generated Python wheel. Debian's
older distro Rust may fail with `rustc ... is not supported`.

It also applies `deploy/claude-code-codex-headroom/patch-headroom-embedding-server.py`
and `patch-headroom-claude-code-streaming.py` as idempotent guardrails. The
fork should already contain these fixes; the scripts exist so a deliberately
overridden older ref does not silently regress into per-worker embedding fallback
or private `headroom_queued` 202 responses.

It also applies `deploy/claude-code-codex-headroom/patch-headroom-claude-code-streaming.py`.
This downstream patch is required for Claude Code streaming stability with
Headroom 0.31.0: the upstream wheel has a private mid-turn queue path that can
return HTTP 202 `headroom_queued` for a `stream:true` Anthropic Messages request.
Claude Code expects Anthropic SSE events, so that private 202 appears as
`API Error: Stream ended without receiving any events`. The patch derives
active-stream keys from Claude Code session plus agent id, waits for the
previous stream to drain, and uses `HEADROOM_MID_TURN_STREAM_WAIT_MS=600000` by
default.

The default `.env` profile is `HEADROOM_SAVINGS_PROFILE=agent-90`, `HEADROOM_TARGET_RATIO=0.10`, `HEADROOM_CONTEXT_TOOL=rtk`, `HEADROOM_CODE_AWARE_ENABLED=1`, `HEADROOM_OUTPUT_SHAPER=1`, and `HEADROOM_MID_TURN_STREAM_WAIT_MS=600000`.

Host persistence is part of the profile. The compose stack writes state under `${SUB2API_STATE_ROOT:-./data}` on the Docker host. The default is `deploy/claude-code-codex-headroom/data` when running from the deploy profile. These are host bind mounts, not Docker named volumes:

- `/root/.headroom`: Headroom `ccr_store.db`, savings events, logs, and subscription state.
- `/root/.cache/headroom`: warmed Headroom tool/model cache.
- `/root/.cache/huggingface`: warmed HuggingFace/ONNX embedding model cache.
- `/root/.local/share/rtk`: the same persistent RTK history used by host Claude Code, mounted from `HEADROOM_RTK_STATE_ROOT` so Headroom perf/dashboard can report CLI savings.
- `/app/data`: sub2api local app data.
- `/var/lib/postgresql`: Postgres parent directory. Keep `PGDATA=/var/lib/postgresql/data`; do not bind the host directory directly to `/var/lib/postgresql/data` because `postgres:18-alpine` declares `/var/lib/postgresql` as a volume and the nested bind can make `initdb` loop on a non-empty data dir.
- `/data`: Redis appendonly data.

Do not delete the state root unless the user explicitly wants to wipe Headroom memory/embeddings, sub2api state, Postgres, Redis, and warmed caches.

## RTK Host Hook And Shared Metrics

RTK in the Headroom container is not enough for automatic Claude Code savings. Claude Code executes its Bash tool on the host before the resulting tool output reaches Headroom, so a container-only binary cannot rewrite the command.

The setup script calls:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-claude-rtk.ps1
```

That installer pins RTK `0.42.4` in `%USERPROFILE%\.local\bin\rtk.exe` and the selected WSL distro, runs `rtk init -g --auto-patch`, keeps `@RTK.md`, and replaces RTK's native-Windows hook with one global Bash bridge:

```text
MSYS2_ARG_CONV_EXCL='*' wsl.exe -d Ubuntu-24.04 -- env -i HOME=/home/devcontainers PATH=/home/devcontainers/.local/bin:/usr/bin:/bin /home/devcontainers/.local/bin/rtk hook claude
```

`MSYS2_ARG_CONV_EXCL='*'` is load-bearing. Claude Code executes hooks through Git Bash; without it, MSYS rewrites `/home/.../rtk` into `C:/Program Files/Git/home/.../rtk`, the hook fails, and Claude silently executes the original command. The installer and verifier both probe the bridge through Git Bash rather than invoking WSL directly from PowerShell.

The default accuracy profile excludes `cat`, `git diff`, `git show`, and `curl` from automatic rewriting because exact source, patch, and raw HTTP bytes may be needed. Set `RTK_DISABLED=1` for a one-off raw command.

On Windows, setup maps `%LOCALAPPDATA%\rtk` to `HEADROOM_RTK_STATE_ROOT` and compose bind-mounts it at `/root/.local/share/rtk`. Prove the full path with all three signals:

1. Claude debug log contains `Hook PreToolUse:Bash ... success` and `modified tool input keys`.
2. A fresh Claude Code Bash call creates a new `history.db` row such as `git log ... -> rtk git log ...`.
3. Host `rtk gain --format json`, container `rtk gain --format json`, and `headroom perf --format json` report matching nonzero RTK command/savings totals.

A high manual container benchmark is only a capability measurement. It is not evidence that normal Claude Code calls use RTK.

### Native Linux Claude Host

When Claude Code is installed on an Ubuntu/Linux host, including a Hyper-V VM host outside its devcontainers, install RTK in that same user account:

```bash
bash scripts/install-claude-rtk.sh
```

The Linux installer pins RTK `0.42.4` at `~/.local/bin/rtk`, backs up and preserves `~/.claude/settings.json`, retains non-RTK hooks, replaces duplicate RTK hooks with one absolute `PreToolUse(Bash)` command, configures the same `cat`/`git diff`/`git show`/`curl` exclusions, and runs synthetic rewrite probes before reporting success. Restart Claude Code after installation because an already-running process may have loaded the old hook registry.

Do not install only inside a devcontainer when Claude Code runs on the Ubuntu host. A container has a separate filesystem and cannot satisfy the host hook path. Conversely, if Claude Code itself runs inside a devcontainer, run the installer inside that container as its Claude user.

Verify the real path with a fresh Claude process and three signals: a Bash tool call in stream JSON, `Hook PreToolUse ... modified tool input keys` in `--debug hooks`, and an increment in `rtk gain --format json`. On the verified Ubuntu host, a real `git log -100 --stat` call reduced RTK-accounted output from `51,221` to `7,792` units (`84.8%`) and completed the Claude request successfully; treat this as a machine-specific proof, not a universal savings guarantee.

The image has a bootstrap entrypoint, `/usr/local/bin/start-headroom-proxy`.
It seeds fresh `/root/.headroom` and cache mounts from `/opt/headroom-seed`
without overwriting existing files, then launches `headroom proxy`. Keep this
wrapper; otherwise a clean persistent volume can hide bundled RTK/lean-ctx and
Headroom tool cache files from the image layer.

Claude Code should not point at stale host binaries for Headroom or TokenSave. RTK is separate from MCP and intentionally remains on host for Bash rewriting. If `claude mcp list` shows `C:\Users\...\headroom.exe` or `tokensave.exe` and those files are missing, remove those entries. The setup script re-adds only the `headroom` MCP through Docker:

```powershell
claude mcp remove headroom -s user
claude mcp remove tokensave -s user
claude mcp add headroom -s user -- wsl.exe -e docker exec -i headroom-sub2api headroom mcp serve --proxy-url http://127.0.0.1:8787
```

### WSL Docker Notes

On Windows, run Docker inside WSL when the user has that setup. Keep `SUB2API_STATE_ROOT` on the Docker host's Linux filesystem for Postgres/Redis, not on a fragile Windows bind path such as `/mnt/c`, unless the user accepts the filesystem semantics risk. The default `./data` is interpreted relative to the compose profile on the Docker host.

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

### Windows Autostart

Use a single autostart owner for the whole stack:

```text
Scheduled task: Sub2API Codex Proxy Stack Autostart
Action: powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<skill-or-profile>\scripts\start-sub2api-proxy-stack.ps1" -RepoRoot "<sub2api>" -ProfileDir "<sub2api>\deploy\claude-code-codex-headroom" -Distro "Ubuntu-24.04"
RunLevel: Highest
Compose project: sub2api-codex
```

Do not keep a second `headroom-proxy` task or a Startup-folder `.cmd` launcher. A separate host `headroom.exe proxy` launcher commonly goes stale when the host binary is removed, while a second compose launcher can race WSL startup and create confusing duplicate logs. Leave only the scheduled task that starts the Docker compose stack.

The setup script installs this task by default. Use `-SkipAutostart` only for a one-off/local-only setup. The task target, `scripts/start-sub2api-proxy-stack.ps1`, is idempotent: it has a named mutex, runs `docker compose --env-file .env -p sub2api-codex up -d --remove-orphans`, refreshes Claude Code `ANTHROPIC_BASE_URL` from the current WSL `eth0` IP when localhost relay is unreliable, then verifies Headroom and sub2api health.

If WSL fails with:

```text
Wsl/Service/CreateInstance/MountDisk/HCS/ERROR_SHARING_VIOLATION
Failed to attach disk ... ext4.vhdx
```

the task needs `RunLevel=Highest` so the start script can self-heal: `wsl --terminate <distro>`, `wsl --shutdown`, inspect `%LOCALAPPDATA%\wsl\*\ext4.vhdx` with `Get-DiskImage`, `Dismount-DiskImage` only attached stale images, then retry WSL. If `Get-DiskImage` shows `Attached=False` and WSL still reports sharing violation, the lock is below normal user-mode handles; collect `hcsdiag list`, `handle64 <ext4.vhdx>`, and Windows may need a full reboot.

Verification:

```powershell
Get-ScheduledTask -TaskName "Sub2API Codex Proxy Stack Autostart" |
  Select-Object TaskName,State,@{n="RunLevel";e={$_.Principal.RunLevel}},@{n="Action";e={$_.Actions.Arguments}}

Get-ScheduledTask |
  Where-Object { $_.TaskName -match "sub2api|headroom|proxy" -or $_.Actions.Arguments -match "sub2api|headroom|proxy" }

Start-ScheduledTask -TaskName "Sub2API Codex Proxy Stack Autostart"
Start-Sleep -Seconds 10
Get-ScheduledTaskInfo -TaskName "Sub2API Codex Proxy Stack Autostart"
curl.exe --max-time 5 "http://127.0.0.1:8787/health"
curl.exe --max-time 5 "http://127.0.0.1:18081/health"
wsl.exe -d Ubuntu-24.04 -- bash -lc 'docker ps --filter label=com.docker.compose.project=sub2api-codex --format "{{.Names}}|{{.Status}}|{{.Ports}}"'
```
