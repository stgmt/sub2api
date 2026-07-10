# Install And Claude Code Config

Docker/WSL install, OAuth import, Claude Code config, dynamic MCP loading, and project memory/rules guidance.

## Workflow

1. Confirm the user has Docker available. On Windows with Docker-in-WSL, prefer `BIND_HOST=0.0.0.0` plus `ANTHROPIC_BASE_URL=http://<wsl-primary-ip>:18081` if Windows `127.0.0.1:18081` hangs or is owned by a stuck `wslrelay.exe`.
2. Install or repair sub2api using `scripts/setup-sub2api-claude-code.ps1`.
3. Import an OpenAI/Codex OAuth account into sub2api.
4. Configure a sub2api OpenAI group for `/v1/messages` dispatch.
5. Create a sub2api API key for Claude Code.
6. Configure Claude Code env/settings.
7. Verify with `/context`, a real Claude Code request, and sub2api usage logs.

## Docker Install

Use the bundled setup script from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\setup-sub2api-claude-code.ps1
```

The script writes a Docker Compose runtime, starts sub2api, and configures Claude Code environment values. It intentionally does not embed anyone's real OAuth refresh token or sub2api API key.

If running from a copied skill folder, first `cd` into that folder.

### WSL Docker Notes

On Windows, run Docker inside WSL when the user has that setup. Keep Postgres and Redis on Docker named volumes. Do not bind Postgres data to `/mnt/c`; Postgres can fail on Windows-mounted filesystems because chmod/ownership semantics are not Linux-native.

Use:

```powershell
wsl.exe -- bash -lc "docker ps"
```

If that works, use WSL Docker for `docker compose up -d`.

For Docker-in-WSL, verify both the container-side port and the Windows route:

```powershell
$wslIp = (wsl.exe -- bash -lc "ip -4 addr show eth0 | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -n1").Trim()
wsl.exe -- bash -lc "curl -sS -m 5 http://127.0.0.1:18081/health"
curl.exe --max-time 5 "http://$wslIp:18081/health"
```

If `curl.exe http://127.0.0.1:18081/health` hangs but `curl.exe http://$wslIp:18081/health` returns `{"status":"ok"}`, do not chase model mapping first. The Windows localhost relay is the failing layer. Use `BIND_HOST=0.0.0.0` in the runtime `.env`, recreate `sub2api`, and set Claude Code `ANTHROPIC_BASE_URL` to `http://$wslIp:18081`.

