[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$module = Join-Path $scriptRoot "fleet-contract.psm1"
$repoRoot = Resolve-Path (Join-Path $scriptRoot "..\..\..\..\..")
$manifestPath = Join-Path $repoRoot "deploy\claude-code-codex-headroom\fleet-manifest.json"
$temp = Join-Path ([IO.Path]::GetTempPath()) ("sub2api-fleet-contract-" + [guid]::NewGuid().ToString("N"))

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

try {
  Import-Module $module -Force
  $manifest = Read-FleetManifest -Path $manifestPath
  Assert-True ($manifest.schema_version -eq 1) "manifest schema must be versioned"
  Assert-True (@($manifest.nodes | Where-Object required).Count -eq 3) "host and both Windows VMs must be required"
  Assert-True (@($manifest.clients | Where-Object required).Count -eq 2) "Claude and DSH clients must be required"

  New-Item -ItemType Directory -Path $temp -Force | Out-Null
  $dshPath = Join-Path $temp "settings.yaml"
  $dshFixture = @"
llm-pi-ai:
  providers:
    {
      head:
        {
          apiKeyEnv: HEAD_API_KEY,
          api: openai-responses,
          baseURL: http://127.0.0.1:8787/v1,
          models: [ { id: gpt-5.6-luna } ]
        },
      other:
        {
          baseURL: https://example.invalid/v1,
          models: []
        }
    }
"@
  [IO.File]::WriteAllText($dshPath, $dshFixture, [Text.UTF8Encoding]::new($false))
  Assert-True ((Get-DshHeadBaseUrl -SettingsPath $dshPath) -eq "http://127.0.0.1:8787/v1") "DSH head endpoint must parse"
  $dshResult = Set-DshHeadBaseUrl -SettingsPath $dshPath -BaseUrl "http://172.22.128.1:8787/v1"
  Assert-True ($dshResult.status -eq "updated") "DSH endpoint must update"
  Assert-True ((Get-DshHeadBaseUrl -SettingsPath $dshPath) -eq "http://172.22.128.1:8787/v1") "DSH endpoint update must persist"
  Assert-True (Test-Path -LiteralPath "$dshPath.rollback") "DSH update must keep one rollback file"
  Assert-True ((Get-Content -Raw $dshPath) -match 'other:[\s\S]+https://example\.invalid/v1') "unrelated DSH provider must survive"

  $claudePath = Join-Path $temp "claude-settings.json"
  [IO.File]::WriteAllText($claudePath, '{"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:8787","KEEP":"yes"}}', [Text.UTF8Encoding]::new($false))
  $claudeResult = Set-ClaudeHeadroomBaseUrl -SettingsPath $claudePath -BaseUrl "http://172.30.1.2:8787"
  Assert-True ($claudeResult.status -eq "updated") "Claude endpoint must update"
  $claude = Get-Content -Raw $claudePath | ConvertFrom-Json
  Assert-True ($claude.env.ANTHROPIC_BASE_URL -eq "http://172.30.1.2:8787") "Claude endpoint update must persist"
  Assert-True ($claude.env.KEEP -eq "yes") "unrelated Claude settings must survive"

  $nodes = [pscustomobject]@{
    windows_host = [pscustomobject]@{ status = "synced" }
    windows_hyperv_ghost_spectre_win11 = [pscustomobject]@{ status = "pending-reconcile"; detail = "fixture" }
    windows_hyperv_win10_ltsc_docker = [pscustomobject]@{ status = "synced" }
    ubuntu_hyperv_devcontainer_ubuntu_2404 = [pscustomobject]@{ status = "pending-reconcile"; detail = "optional fixture" }
  }
  $summary = Get-FleetReconcileSummary -Manifest $manifest -Nodes $nodes
  Assert-True (-not $summary.ok) "a required pending VM must fail the fleet"
  Assert-True ($summary.required_failures[0].id -eq "ghost-spectre-win11") "required failure must name the VM"
  $nodes.windows_hyperv_ghost_spectre_win11.status = "synced"
  $summary = Get-FleetReconcileSummary -Manifest $manifest -Nodes $nodes
  Assert-True ($summary.ok -and $summary.status -eq "degraded") "an optional offline VM may degrade without false failure"

  "FLEET_CONTRACT_TESTS_OK"
} finally {
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
