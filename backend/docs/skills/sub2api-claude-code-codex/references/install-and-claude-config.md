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

The script writes `deploy/claude-code-codex-headroom/.env`, starts the compose project `sub2api-codex`, configures Claude Code environment values, registers the Docker-backed Headroom MCP server, syncs a validated host Codex auth file into the sub2api bind mount, and installs RTK on Windows plus WSL unless `-SkipRtk` is passed. It intentionally does not print or embed anyone's real OAuth refresh token or sub2api API key.

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

The default `.env` profile is `HEADROOM_SAVINGS_PROFILE=agent-90`, `HEADROOM_TARGET_RATIO=0.10`, `HEADROOM_CONTEXT_TOOL=rtk`, `HEADROOM_CODE_AWARE_ENABLED=1`, `HEADROOM_OUTPUT_SHAPER=1`, `HEADROOM_EFFORT_ROUTER=0`, and `HEADROOM_MID_TURN_STREAM_WAIT_MS=600000`. The output shaper still applies verbosity steering, but its effort router must stay off: when omitted, Headroom defaults it on and rewrites clean `tool_result` continuations from the client-selected `output_config.effort=max` to `low`.

Host persistence is part of the profile. The compose stack writes state under `${SUB2API_STATE_ROOT:-./data}` on the Docker host. The default is `deploy/claude-code-codex-headroom/data` when running from the deploy profile. These are host bind mounts, not Docker named volumes:

- `/root/.headroom`: Headroom `ccr_store.db`, savings events, logs, and subscription state.
- `/root/.cache/headroom`: warmed Headroom tool/model cache.
- `/root/.cache/huggingface`: warmed HuggingFace/ONNX embedding model cache.
- `/root/.local/share/rtk`: the same persistent RTK history used by host Claude Code, mounted from `HEADROOM_RTK_STATE_ROOT` so Headroom perf/dashboard can report CLI savings.
- `/app/data`: sub2api local app data.
- `/var/lib/postgresql`: Postgres parent directory. Keep `PGDATA=/var/lib/postgresql/data`; do not bind the host directory directly to `/var/lib/postgresql/data` because `postgres:18-alpine` declares `/var/lib/postgresql` as a volume and the nested bind can make `initdb` loop on a non-empty data dir.
- `/data`: Redis appendonly data.

Codex/OpenAI OAuth recovery uses the same state root. The installer and the repeating self-heal task validate `%USERPROFILE%\.codex\auth.json` for `tokens.access_token` plus `tokens.refresh_token`, then copy it to `${SUB2API_STATE_ROOT}/sub2api/codex-auth.json`. The container reads it through `SUB2API_OPENAI_CODEX_AUTH_FILE=/app/data/codex-auth.json`. Do not print that file or any token values. If a host `codex login` refreshes the file, the next self-heal pass syncs it; the backend can then recover `refresh_token_reused` / invalid-refresh-token failures without manual SQL.

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
Action: powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<skill-or-profile>\scripts\ensure-sub2api-proxy-stack.ps1" -RepoRoot "<sub2api>" -ProfileDir "<sub2api>\deploy\claude-code-codex-headroom" -Distro "Ubuntu-24.04"
RunLevel: Highest
Triggers: at logon plus every 1 minute for 10 years
Failure retry: 3 attempts, 1 minute apart
Compose project: sub2api-codex
```

Do not keep a second `headroom-proxy` task or a Startup-folder `.cmd` launcher. A separate host `headroom.exe proxy` launcher commonly goes stale when the host binary is removed, while a second compose launcher can race WSL startup and create confusing duplicate logs. Leave only the scheduled task that starts the Docker compose stack.

The setup script installs this task by default. Use `-SkipAutostart` only for a one-off/local-only setup. The task target, `scripts/ensure-sub2api-proxy-stack.ps1`, first syncs the host Codex auth file when present, then runs a cheap health-first path and does not touch healthy containers. Same-host Headroom health is enough for the normal Windows/WSL profile; Hyper-V bridge health is logged as diagnostic unless `HEADROOM_HYPERV_REQUIRE_BRIDGE=1` is set in `hyperv-bridge.env` or `-RequireHyperVBridge` is passed. On required route failure it invokes `scripts/start-sub2api-proxy-stack.ps1`, which wakes WSL, runs `docker compose --env-file .env -p sub2api-codex up -d --remove-orphans`, refreshes Claude Code `ANTHROPIC_BASE_URL` and the Hyper-V bridge from current addresses, then verifies recovery. The repeating trigger is required because a successful logon task is not re-fired when WSL later powers off.

Existing installations whose task still points directly at `start-sub2api-proxy-stack.ps1` self-migrate on their next elevated run: the start script detects a missing `PT1M` trigger/retry policy and invokes the installer. This is intentional because a normal non-elevated shell cannot replace a `RunLevel=Highest` task.

### Hyper-V Claude Host Bridge

When Claude Code runs in a Hyper-V VM while Headroom runs in WSL Docker, neither the WSL `eth0` address nor the Hyper-V Default Switch address is stable across host reboots. A one-time `netsh portproxy` entry therefore becomes stale even though every Docker container remains healthy. Enable the autostart-owned bridge with a non-secret `hyperv-bridge.env` beside the deploy profile `.env`:

```dotenv
HEADROOM_HYPERV_VM_NAME=devcontainer-ubuntu-2404
HEADROOM_HYPERV_VM_SSH_USER=migration
HEADROOM_HYPERV_VM_SSH_KEY=C:\Migration\devcontainer-vm-key
HEADROOM_HYPERV_SWITCH_NAME=Default Switch
# Optional. Set to 1 only when the Hyper-V VM is an active Claude host and bridge health must fail the watchdog.
HEADROOM_HYPERV_REQUIRE_BRIDGE=0
```

For a Windows guest without SSH, use bridge-only mode and make the bridge required:

```dotenv
HEADROOM_HYPERV_VM_NAME=win10-ltsc-docker
HEADROOM_HYPERV_REMOTE_CONFIG_MODE=none
HEADROOM_HYPERV_SWITCH_NAME=Default Switch
HEADROOM_HYPERV_REQUIRE_BRIDGE=1
```

`hyperv-bridge.env` is authoritative over VM values embedded in an older scheduled-task action. In `none` mode the elevated owner still discovers the current VM, Default Switch, and WSL addresses, replaces stale portproxy entries, restricts the firewall rule to the current VM IP, and proves the bridge from the host. It deliberately skips SSH and guest settings changes. Update the Windows guest once to the stable switch address, for example `http://<Default-Switch-IP>:8787`, then restart Claude Code. Do not leave the guest on the WSL `eth0` address.

On a healthy minute the elevated task probes the same-host route and, when `hyperv-bridge.env` exists, also records the Default Switch route. With `HEADROOM_HYPERV_REQUIRE_BRIDGE=0`, a down VM bridge is `bridge_required=false` diagnostic state and must not restart a healthy local stack. With `HEADROOM_HYPERV_REQUIRE_BRIDGE=1`, failure resolves the current VM, Default Switch, and WSL addresses; removes stale `v4tov4` entries owned by the Headroom port; and recreates the VM-scoped firewall rule. `HEADROOM_HYPERV_REMOTE_CONFIG_MODE=ssh` additionally updates Linux guest settings atomically and probes from its namespace; `none` is the Windows/no-SSH bridge-only mode and requires a one-time guest base-URL update. Run `scripts/test-hyperv-headroom-bridge-contract.ps1` and `scripts/test-autostart-self-heal-contract.ps1` after editing this path. Restart already-open Claude Code processes after the endpoint or hook runtime changes because they may retain the old settings registry.

### Qwen delegated profile on every Claude host

Do not assume host settings propagate into WSL or Hyper-V guests. Each OS/user that launches Claude has its own `~/.claude` and process environment.

Windows host or Windows guest:

```powershell
./scripts/sync-claude-subagent-profile.ps1
./scripts/sync-claude-subagent-profile.ps1 -CheckOnly
```

Native Ubuntu or WSL user:

```bash
bash ./scripts/sync-claude-subagent-profile.sh
bash ./scripts/sync-claude-subagent-profile.sh --check
```

Both paths pin small-fast, Opus/Fable/Sonnet/Haiku picker slots, and `CLAUDE_CODE_SUBAGENT_MODEL` to `qwen3.8-max-preview`, while the five global delegated-agent files use `effort: high`. They preserve existing hooks, unknown settings, custom agent prompt bodies, and the main `ANTHROPIC_MODEL` choice.

For Windows Hyper-V guests that expose no SSH/WinRM, add this opt-in sidecar configuration:

```dotenv
HEADROOM_HYPERV_STAGE_QWEN_PROFILE=1
HEADROOM_HYPERV_QWEN_VM_NAMES=guest-one,guest-two
HEADROOM_HYPERV_SUBAGENT_MODEL=qwen3.8-max-preview
HEADROOM_HYPERV_SUBAGENT_EFFORT=high
```

The elevated watchdog enables Guest Service Interface, copies the portable sync to `C:\ProgramData\sub2api`, and puts a one-shot launcher in the all-users Startup folder. Host `hyperv-qwen-*.staged` files and `hyperv_subagent_profile_staged` events prove delivery, not execution. The guest applies the profile on its next interactive logon and writes `C:\ProgramData\sub2api\sync-claude-subagent-profile.log`; restart already-open Claude processes before the live `Agent(...)` verification.

The Linux VM still needs the full Claude profile, not only `ANTHROPIC_BASE_URL`: keep `CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK=1`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, the current context/compact targets, small-fast model, and subagent model in its settings. Native `/compact` is intentionally non-streaming and is identified by `source=compact` plus `x-sub2api-claude-compact`; that is different from Claude Code's emergency non-streaming fallback. If the disable knob is missing, a failed streaming turn can be replayed as a much larger non-stream request and loop for many minutes.

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
