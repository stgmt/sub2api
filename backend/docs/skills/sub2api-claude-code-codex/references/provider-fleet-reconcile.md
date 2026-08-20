# Fleet Reconciliation

## Discovery

The topology is versioned in `deploy/claude-code-codex-headroom/fleet-manifest.json`. The current required topology is:

- current Windows host user;
- Windows guest `ghost-spectre-win11`, user `admin`;
- Windows guest `win10-ltsc-docker`, user `admin`.

The absent Ubuntu guest `devcontainer-ubuntu-2404` is retained as optional inventory. Do not silently substitute it for either required Windows VM.

VM names and required/optional policy come from the manifest; addresses remain discovery inputs. Record connection method and last successful reconciliation per node.

## Owned Fields

Reconcile only provider/model fields in:

- `~/.claude/settings.json`, DSH `settings.yaml`, DSH's `HEAD_API_KEY` slot, and user environment variables;
- `ANTHROPIC_MODEL`, picker defaults, `ANTHROPIC_SMALL_FAST_MODEL`, and `CLAUDE_CODE_SUBAGENT_MODEL`;
- global agent `model` and `effort` frontmatter;
- higher-precedence `claude.cmd`, shell profiles, aliases, and environment.d entries;
- model gateway cache and status display metadata;
- boot/login self-heal generation marker.

For profiles that declare `unset_client_env`, remove those keys from settings and User environment. On Windows, also write an explicit empty assignment in the launcher wrapper so an already-open parent process cannot re-inject a stale hard override into a new Claude process.

Preserve hooks, MCP servers, permissions, custom agent bodies, project rules, and unrelated settings.

## Adapters

- Windows host: local PowerShell adapter.
- Ubuntu guest: SSH adapter and user-level systemd/login reconciliation.
- Windows guest: PowerShell Remoting or SSH, plus a Scheduled Task/login reconciliation. Hyper-V Guest Service Interface may stage files, but a successful `Copy-VMFile` proves staging only.

Each adapter supports apply and check-only modes and returns `synced`, `pending-reconcile`, or `drifted` with the active generation.

The existing elevated `Sub2API Codex Proxy Stack Autostart` task is the only Windows autostart owner. It runs scripts from the Git checkout, reads the canonical manifest, compares the stored route generation with every node marker, and probes the exact Claude and DSH endpoints. A required pending node is an unhealthy provider route; it cannot be logged as `healthy` merely because another WSL address responds. Do not create a second provider-switcher Scheduled Task.

The watchdog must never stage a separate Qwen-only subagent script. That legacy path ignored the active profile and could silently revert a VM after `chatgpt-only` or `anthropic-only` was selected. `claude-route` is the only owner of provider, model, effort, key, and generation fields on every node.

## Offline Nodes

Required nodes participate in the switch transaction. If a required guest cannot apply and prove the new generation, restore the previous stable-key binding and previous node profile. Do not report the new profile active.

If an optional guest is offline after a successful proxy switch:

1. mark it `pending-reconcile`;
2. leave the selected profile active with fleet status `degraded`;
3. stage no credentials;
4. let its boot/login repair fetch and apply the active generation;
5. require a later live probe before marking it `synced`.
