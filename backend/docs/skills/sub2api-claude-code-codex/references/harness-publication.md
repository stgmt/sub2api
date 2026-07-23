# Harness Publication Contract

The reproducible Claude Code stack is larger than `SKILL.md`. A release is
complete only when the skill bundle, deploy profile, routing implementation,
admin round-trip, and contract tests are committed together.

## Published Surfaces

- `backend/docs/skills/sub2api-claude-code-codex/`
  - operating rules and failure registry
  - Windows and Linux host-profile synchronization
  - setup, verification, autostart, RTK, compact recovery, and live routing scripts
  - focused contract tests and eval prompts
- `deploy/claude-code-codex-headroom/`
  - CPU/GPU compose profiles
  - pinned Headroom fork build
  - persistent-state and streaming/embedding guardrails
  - deterministic fork, RTK, and Kompress tests
- `backend/internal/`
  - group-owned `sdk_cli_mapped_model` and `sdk_cli_reasoning_effort`
  - `external, sdk-cli` routing before provider classification
  - service, cache, admin, and handler regression coverage
- `frontend/src/views/admin/`
  - lossless messages-dispatch config round-trip so an admin save cannot erase
    compact, SDK CLI, exact-mapping, or fallback fields

Run the publication contract from the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File backend/docs/skills/sub2api-claude-code-codex/scripts/test-qwen-sdk-cli-harness-contract.ps1
```

The test verifies both file presence and Git tracking. It also checks the
critical cross-file wiring: setup writes the SDK CLI profile, verification
audits it, the backend distinguishes print/Agent SDK traffic from interactive
CLI traffic, and the frontend preserves the fields.

## Deliberately Local State

Never publish generated runtime state merely to make the harness look complete:

- `.env`, OAuth files, API keys, refresh tokens, account exports, or passwords
- `data/`, PostgreSQL, Redis, Headroom memory, embedding caches, and RTK history
- `logs/`, test status, session state, `.mcp-lock.json`, or `__pycache__`
- VM-specific IP addresses, firewall state, scheduled-task history, or copied
  guest credentials

The repository publishes `.env.example` and idempotent setup/sync scripts
instead. A fresh machine should be reconstructed from those files and then
verified through live `claude -p`, Agent, and interactive-control requests.

## Release Checklist

1. Run the publication contract and focused backend/frontend tests.
2. Sync the source skill into the installed Codex skill and compare hashes.
3. Commit all harness changes intentionally; leave unrelated local state out.
4. Push `main` to `stgmt/sub2api` and verify the remote SHA.
5. Build the live image from `git archive HEAD`, recreate only affected
   services, and verify the image revision label.
6. Prove `claude -p` and Agent SDK use Qwen/high while `(external, cli)` keeps
   the user's selected model and effort.
