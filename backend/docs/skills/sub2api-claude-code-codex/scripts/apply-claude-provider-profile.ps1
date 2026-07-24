[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$ProfilePath,
  [string]$SettingsPath,
  [string]$AgentsPath,
  [string]$WrapperPath,
  [string]$Generation = "0",
  [ValidateSet("User", "Process", "None")]
  [string]$EnvironmentTarget = "User",
  [switch]$CheckOnly
)

$ErrorActionPreference = "Stop"

function Write-Utf8NoBom([string]$Path, [string]$Content) {
  $parent = Split-Path -Parent $Path
  if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Set-ObjectProperty($Object, [string]$Name, $Value) {
  if ($Object.PSObject.Properties.Name -contains $Name) {
    $Object.$Name = $Value
  } else {
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
  }
}

function Get-DefaultHome {
  if ($env:USERPROFILE) { return $env:USERPROFILE }
  if ($HOME) { return $HOME }
  throw "Unable to determine the user home directory"
}

$profile = Get-Content -Raw -LiteralPath $ProfilePath | ConvertFrom-Json
$homeDir = Get-DefaultHome
if (-not $SettingsPath) { $SettingsPath = Join-Path $homeDir ".claude\settings.json" }
if (-not $AgentsPath) { $AgentsPath = Join-Path $homeDir ".claude\agents" }
if (-not $WrapperPath) { $WrapperPath = Join-Path $homeDir ".local\bin\claude.cmd" }

if (Test-Path -LiteralPath $SettingsPath) {
  $settings = Get-Content -Raw -LiteralPath $SettingsPath | ConvertFrom-Json
} else {
  $settings = [pscustomobject]@{}
}
if (-not ($settings.PSObject.Properties.Name -contains "env") -or $null -eq $settings.env) {
  Set-ObjectProperty $settings "env" ([pscustomobject]@{})
}

$drift = [Collections.Generic.List[string]]::new()
foreach ($property in $profile.client_env.PSObject.Properties) {
  $current = if ($settings.env.PSObject.Properties.Name -contains $property.Name) { [string]$settings.env.($property.Name) } else { $null }
  if ($current -ne [string]$property.Value) {
    $drift.Add("settings.env.$($property.Name)")
    if (-not $CheckOnly) { Set-ObjectProperty $settings.env $property.Name ([string]$property.Value) }
  }
}

$markerName = "CLAUDE_PROVIDER_PROFILE_GENERATION"
if ([string]$settings.env.$markerName -ne [string]$Generation) {
  $drift.Add("settings.env.$markerName")
  if (-not $CheckOnly) { Set-ObjectProperty $settings.env $markerName ([string]$Generation) }
}

if ($EnvironmentTarget -ne "None") {
  $target = [Enum]::Parse([EnvironmentVariableTarget], $EnvironmentTarget)
  $desiredUserEnvironment = [ordered]@{}
  foreach ($property in $profile.client_env.PSObject.Properties) {
    $desiredUserEnvironment[$property.Name] = [string]$property.Value
  }
  $desiredUserEnvironment[$markerName] = [string]$Generation
  foreach ($entry in $desiredUserEnvironment.GetEnumerator()) {
    $current = [Environment]::GetEnvironmentVariable([string]$entry.Key, $target)
    if ([string]$current -ne [string]$entry.Value) {
      $drift.Add("user_env.$($entry.Key)")
      if (-not $CheckOnly) { [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, $target) }
    }
  }
}

if (-not $CheckOnly -and $drift.Count -gt 0) {
  Write-Utf8NoBom $SettingsPath (($settings | ConvertTo-Json -Depth 100) + [Environment]::NewLine)
}

$agentFiles = @()
if (Test-Path -LiteralPath $AgentsPath) {
  $agentFiles = @(Get-ChildItem -LiteralPath $AgentsPath -Filter "*.md" -File -ErrorAction SilentlyContinue)
}
foreach ($file in $agentFiles) {
  $text = Get-Content -Raw -LiteralPath $file.FullName
  $frontmatterMatch = [regex]::Match($text, '(?s)\A---\r?\n(?<header>.*?)\r?\n---')
  if (-not $frontmatterMatch.Success) { continue }
  $header = $frontmatterMatch.Groups['header'].Value
  $newHeader = $header
  if ($newHeader -match '(?m)^model:\s*.*$') {
    $newHeader = [regex]::Replace($newHeader, '(?m)^model:\s*.*$', "model: $($profile.agent_model)")
  } else {
    $newHeader += "`nmodel: $($profile.agent_model)"
  }
  if ($newHeader -match '(?m)^effort:\s*.*$') {
    $newHeader = [regex]::Replace($newHeader, '(?m)^effort:\s*.*$', "effort: $($profile.agent_effort)")
  } else {
    $newHeader += "`neffort: $($profile.agent_effort)"
  }
  if ($newHeader -ne $header) {
    $drift.Add("agent:$($file.Name)")
    if (-not $CheckOnly) {
      $updated = $text.Substring(0, $frontmatterMatch.Index) + "---`n$newHeader`n---" + $text.Substring($frontmatterMatch.Index + $frontmatterMatch.Length)
      Write-Utf8NoBom $file.FullName $updated
    }
  }
}

if (Test-Path -LiteralPath $WrapperPath) {
  $wrapper = Get-Content -Raw -LiteralPath $WrapperPath
  $updatedWrapper = $wrapper
  foreach ($property in $profile.client_env.PSObject.Properties) {
    $escapedName = [regex]::Escape($property.Name)
    $pattern = '(?im)^set\s+"{0}=.*?"\s*$' -f $escapedName
    if ($updatedWrapper -match $pattern) {
      $replacement = "set `"$($property.Name)=$($property.Value)`""
      $updatedWrapper = [regex]::Replace($updatedWrapper, $pattern, $replacement)
    }
  }
  if ($updatedWrapper -ne $wrapper) {
    $drift.Add("wrapper:$WrapperPath")
    if (-not $CheckOnly) { Write-Utf8NoBom $WrapperPath $updatedWrapper }
  }
}

$result = [ordered]@{
  profile = $profile.name
  version = $profile.version
  generation = [string]$Generation
  settings_path = $SettingsPath
  agents_checked = $agentFiles.Count
  drift = @($drift)
  status = if ($drift.Count -eq 0) { "synced" } elseif ($CheckOnly) { "drifted" } else { "synced" }
  environment_target = $EnvironmentTarget
}
$result | ConvertTo-Json -Depth 10
if ($CheckOnly -and $drift.Count -gt 0) { exit 3 }
