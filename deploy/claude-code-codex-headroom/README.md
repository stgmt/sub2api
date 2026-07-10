# Claude Code + Headroom + sub2api

This profile runs a local Claude Code chain backed by a Codex/OpenAI subscription:

```text
Claude Code -> Headroom on 127.0.0.1:8787 -> sub2api on Docker DNS sub2api:8080 -> OpenAI/Codex OAuth
```

Headroom is the Claude Code-facing endpoint. sub2api still exposes `127.0.0.1:18081` for the admin UI, diagnostics, and non-Claude clients.

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

The setup script generates a local `.env`, starts the compose project as `sub2api-codex`, and configures Claude Code to use `http://127.0.0.1:8787`.
