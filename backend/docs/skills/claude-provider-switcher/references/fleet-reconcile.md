# Fleet Reconciliation

## Discovery

The known topology is one Windows host plus two Hyper-V guests:

- current Windows host user;
- Ubuntu guest `devcontainer-ubuntu-2404`, user `migration`;
- one Windows guest whose name must be discovered with `Get-VM`, user `admin`.

Treat names and addresses as discovery inputs, not constants. Record connection method and last successful reconciliation per node.

## Owned Fields

Reconcile only provider/model fields in:

- `~/.claude/settings.json` and user environment variables;
- `ANTHROPIC_MODEL`, picker defaults, `ANTHROPIC_SMALL_FAST_MODEL`, and `CLAUDE_CODE_SUBAGENT_MODEL`;
- global agent `model` and `effort` frontmatter;
- higher-precedence `claude.cmd`, shell profiles, aliases, and environment.d entries;
- model gateway cache and status display metadata;
- boot/login self-heal generation marker.

Preserve hooks, MCP servers, permissions, custom agent bodies, project rules, and unrelated settings.

## Adapters

- Windows host: local PowerShell adapter.
- Ubuntu guest: SSH adapter and user-level systemd/login reconciliation.
- Windows guest: PowerShell Remoting or SSH, plus a Scheduled Task/login reconciliation. Hyper-V Guest Service Interface may stage files, but a successful `Copy-VMFile` proves staging only.

Each adapter supports apply and check-only modes and returns `synced`, `pending-reconcile`, or `drifted` with the active generation.

The existing elevated `Sub2API Codex Proxy Stack Autostart` task is the only Windows autostart owner. Its health-first ensure script compares the stored route generation with the host marker, retries pending guests no more often than the configured reconcile interval, and records provider-reconcile failures without restarting a healthy proxy stack. Do not create a second provider-switcher Scheduled Task.

## Offline Nodes

The proxy route is authoritative. If a guest is offline after a successful proxy switch:

1. mark it `pending-reconcile`;
2. leave the selected profile active;
3. stage no credentials;
4. let its boot/login repair fetch and apply the active generation;
5. require a later live probe before marking it `synced`.
