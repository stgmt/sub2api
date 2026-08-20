Set-StrictMode -Version Latest

function Write-AtomicUtf8NoBom {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Content
  )

  $parent = Split-Path -Parent $Path
  if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  $temp = Join-Path $parent (".{0}.{1}.tmp" -f ([IO.Path]::GetFileName($Path)), [guid]::NewGuid().ToString("N"))
  $backup = "$Path.rollback"
  try {
    [IO.File]::WriteAllText($temp, $Content, [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $Path) {
      [IO.File]::Replace($temp, $Path, $backup, $true)
    } else {
      [IO.File]::Move($temp, $Path)
    }
  } finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
  }
}

function Resolve-FleetPath {
  [CmdletBinding()]
  param([Parameter(Mandatory = $true)][string]$Path)
  return [Environment]::ExpandEnvironmentVariables($Path)
}

function Read-FleetManifest {
  [CmdletBinding()]
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) { throw "Fleet manifest not found: $Path" }
  $manifest = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -ErrorAction Stop
  if ([int]$manifest.schema_version -ne 1) { throw "Unsupported fleet manifest schema: $($manifest.schema_version)" }
  $ids = @($manifest.nodes | ForEach-Object { [string]$_.id })
  if ($ids.Count -eq 0 -or @($ids | Where-Object { -not $_.Trim() }).Count -gt 0) {
    throw "Fleet manifest must contain named nodes"
  }
  if (@($ids | Group-Object | Where-Object Count -gt 1).Count -gt 0) {
    throw "Fleet manifest node ids must be unique"
  }
  return $manifest
}

function Get-FleetNodeStateKey {
  [CmdletBinding()]
  param([Parameter(Mandatory = $true)]$Node)
  if ($Node.PSObject.Properties.Name -contains "state_key" -and [string]$Node.state_key) {
    return [string]$Node.state_key
  }
  return ([string]$Node.id -replace '[^A-Za-z0-9_]', '_')
}

function Get-FleetReconcileSummary {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]$Manifest,
    [Parameter(Mandatory = $true)]$Nodes
  )

  $requiredFailures = [Collections.Generic.List[object]]::new()
  $optionalFailures = [Collections.Generic.List[object]]::new()
  foreach ($definition in @($Manifest.nodes)) {
    $key = Get-FleetNodeStateKey -Node $definition
    $property = @($Nodes.PSObject.Properties | Where-Object Name -eq $key | Select-Object -First 1)
    $status = if ($property.Count -eq 1) { [string]$property[0].Value.status } else { "missing" }
    if ($status -eq "synced") { continue }
    $failure = [pscustomobject]@{
      id = [string]$definition.id
      state_key = $key
      required = [bool]$definition.required
      status = $status
      detail = if ($property.Count -eq 1) { $property[0].Value.detail } else { "node result missing" }
    }
    if ([bool]$definition.required) { $requiredFailures.Add($failure) } else { $optionalFailures.Add($failure) }
  }
  return [pscustomobject]@{
    ok = $requiredFailures.Count -eq 0
    status = if ($requiredFailures.Count -eq 0) { if ($optionalFailures.Count -eq 0) { "synced" } else { "degraded" } } else { "pending-reconcile" }
    required_failures = @($requiredFailures)
    optional_failures = @($optionalFailures)
  }
}

function Assert-FleetRequiredNodesSynced {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]$Manifest,
    [Parameter(Mandatory = $true)]$Nodes
  )
  $summary = Get-FleetReconcileSummary -Manifest $Manifest -Nodes $Nodes
  if (-not $summary.ok) {
    $names = @($summary.required_failures | ForEach-Object { "$($_.id)=$($_.status)" }) -join ", "
    throw "Required fleet nodes are not synchronized: $names"
  }
  return $summary
}

function Get-DshHeadBaseUrl {
  [CmdletBinding()]
  param([Parameter(Mandatory = $true)][string]$SettingsPath)

  if (-not (Test-Path -LiteralPath $SettingsPath)) { return $null }
  $lines = @(Get-Content -LiteralPath $SettingsPath)
  $headIndex = -1
  $headIndent = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^(?<indent>\s*)head:\s*$') {
      $headIndex = $i
      $headIndent = $Matches.indent.Length
      break
    }
  }
  if ($headIndex -lt 0) { return $null }
  for ($i = $headIndex + 1; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^(?<indent>\s*)(?<key>[A-Za-z0-9_.-]+):\s*$' -and $Matches.indent.Length -le $headIndent) { break }
    if ($lines[$i] -match '^\s*baseURL:\s*(?<url>[^,]+),?\s*$') {
      return $Matches.url.Trim().Trim('"').Trim("'").TrimEnd('/')
    }
  }
  return $null
}

function Set-DshHeadBaseUrl {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$SettingsPath,
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [switch]$CheckOnly
  )

  if (-not (Test-Path -LiteralPath $SettingsPath)) {
    return [pscustomobject]@{ status = "missing"; path = $SettingsPath; previous = $null; endpoint = $BaseUrl.TrimEnd('/') }
  }
  $desired = $BaseUrl.TrimEnd('/')
  $lines = @(Get-Content -LiteralPath $SettingsPath)
  $headIndex = -1
  $headIndent = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^(?<indent>\s*)head:\s*$') {
      $headIndex = $i
      $headIndent = $Matches.indent.Length
      break
    }
  }
  if ($headIndex -lt 0) { throw "DSH head provider is missing from $SettingsPath" }

  $baseIndex = -1
  for ($i = $headIndex + 1; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^(?<indent>\s*)(?<key>[A-Za-z0-9_.-]+):\s*$' -and $Matches.indent.Length -le $headIndent) { break }
    if ($lines[$i] -match '^(?<indent>\s*)baseURL:\s*(?<url>[^,]+)(?<comma>,?)\s*$') {
      $baseIndex = $i
      $indent = $Matches.indent
      $comma = if ($Matches.comma) { $Matches.comma } else { "," }
      break
    }
  }
  if ($baseIndex -lt 0) { throw "DSH head provider baseURL is missing from $SettingsPath" }
  $previous = Get-DshHeadBaseUrl -SettingsPath $SettingsPath
  if ($previous -eq $desired) {
    return [pscustomobject]@{ status = "unchanged"; path = $SettingsPath; previous = $previous; endpoint = $desired }
  }
  if (-not $CheckOnly) {
    $lines[$baseIndex] = "${indent}baseURL: ${desired}${comma}"
    Write-AtomicUtf8NoBom -Path $SettingsPath -Content (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
  }
  return [pscustomobject]@{ status = if ($CheckOnly) { "drifted" } else { "updated" }; path = $SettingsPath; previous = $previous; endpoint = $desired }
}

function Get-ClaudeHeadroomBaseUrl {
  [CmdletBinding()]
  param([Parameter(Mandatory = $true)][string]$SettingsPath)
  if (-not (Test-Path -LiteralPath $SettingsPath)) { return $null }
  try {
    $settings = Get-Content -Raw -LiteralPath $SettingsPath | ConvertFrom-Json -ErrorAction Stop
    return ([string]$settings.env.ANTHROPIC_BASE_URL).TrimEnd('/')
  } catch {
    return $null
  }
}

function Set-ClaudeHeadroomBaseUrl {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$SettingsPath,
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [switch]$CheckOnly
  )
  if (-not (Test-Path -LiteralPath $SettingsPath)) {
    return [pscustomobject]@{ status = "missing"; path = $SettingsPath; previous = $null; endpoint = $BaseUrl.TrimEnd('/') }
  }
  $settings = Get-Content -Raw -LiteralPath $SettingsPath | ConvertFrom-Json -ErrorAction Stop
  if (-not ($settings.PSObject.Properties.Name -contains "env") -or $null -eq $settings.env) {
    $settings | Add-Member -NotePropertyName env -NotePropertyValue ([pscustomobject]@{}) -Force
  }
  $desired = $BaseUrl.TrimEnd('/')
  $previous = [string]$settings.env.ANTHROPIC_BASE_URL
  if ($previous.TrimEnd('/') -eq $desired) {
    return [pscustomobject]@{ status = "unchanged"; path = $SettingsPath; previous = $previous; endpoint = $desired }
  }
  if (-not $CheckOnly) {
    if ($settings.env.PSObject.Properties.Name -contains "ANTHROPIC_BASE_URL") {
      $settings.env.ANTHROPIC_BASE_URL = $desired
    } else {
      $settings.env | Add-Member -NotePropertyName ANTHROPIC_BASE_URL -NotePropertyValue $desired
    }
    Write-AtomicUtf8NoBom -Path $SettingsPath -Content (($settings | ConvertTo-Json -Depth 100) + [Environment]::NewLine)
  }
  return [pscustomobject]@{ status = if ($CheckOnly) { "drifted" } else { "updated" }; path = $SettingsPath; previous = $previous; endpoint = $desired }
}

Export-ModuleMember -Function @(
  "Write-AtomicUtf8NoBom",
  "Resolve-FleetPath",
  "Read-FleetManifest",
  "Get-FleetNodeStateKey",
  "Get-FleetReconcileSummary",
  "Assert-FleetRequiredNodesSynced",
  "Get-DshHeadBaseUrl",
  "Set-DshHeadBaseUrl",
  "Get-ClaudeHeadroomBaseUrl",
  "Set-ClaudeHeadroomBaseUrl"
)
