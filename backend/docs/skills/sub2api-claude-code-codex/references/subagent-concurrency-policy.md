# Claude Code subagent concurrency policy

Use this playbook with `claude-route`, stack setup, and fleet reconciliation. The policy is provider-independent and must survive every switch between `anthropic-only`, `chatgpt-only`, and `hybrid-current`.

## Required policy

```text
CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=10
CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1
```

- `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=10` is the native per-session hard cap added in Claude Code 2.1.217. It replaces the default of 20.
- `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1` disables nested spawning on Claude Code 2.1.219, whose default nesting depth is 3.
- `workflowSizeGuideline=small` remains useful as an advisory hint, but it is not an enforcement boundary.
- Do not implement the primary limit in Headroom or sub2api. HTTP admission happens after Claude Code has already created the workers and turns an orchestration problem into retries or provider errors.
- The native cap is scoped to one Claude Code root process. Multiple interactive windows can each run ten subagents. A fleet-wide aggregate cap requires a separate atomic lease service; a JSON-file hook is not race-safe.

## Incident evidence

Session `688c01ce-9020-4205-881a-b8e7d2714ddc` ran on Claude Code 2.1.202, before the native caps existed. It created 367 subagent transcripts. The main thread launched 44 workers, 92 children invoked Agent again, the tree reached depth 5, and observed transcript lifetimes overlapped at a peak of 174. The `Audit launch ledger code` subtree alone grew beyond 180 descendants. Proxy evidence showed its Claude Code 2.1.202 traffic on `gpt-5.6-terra` with `reasoning_effort=xhigh`.

## Installation boundary

Write both values to all of these surfaces:

1. The active provider profile `client_env`, so `claude-route` preserves the policy.
2. `~/.claude/settings.json` under `env`.
3. The Windows User environment or Linux `~/.config/environment.d/90-claude-subagents.conf`.
4. A managed `claude.cmd` wrapper when one exists.

Already-running Claude Code processes retain their startup environment and binary. Restart them after applying the policy. A session still running Claude Code 2.1.202 cannot enforce these variables; relaunch it with 2.1.219 or newer.

## Verification

Windows:

```powershell
claude --version
[Environment]::GetEnvironmentVariable("CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS", "User")
[Environment]::GetEnvironmentVariable("CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH", "User")
Get-Content "$HOME/.claude/settings.json" -Raw | ConvertFrom-Json | Select-Object -ExpandProperty env
```

Linux:

```bash
claude --version
grep -E 'CLAUDE_CODE_MAX_(CONCURRENT_SUBAGENTS|SUBAGENT_SPAWN_DEPTH)' \
  "$HOME/.config/environment.d/90-claude-subagents.conf" "$HOME/.claude/settings.json"
```

Run the portable sync in check-only mode after setup or a provider switch. A clean result must prove both values in addition to the model and effort profile.
