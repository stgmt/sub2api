[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$ProfilePath,
  [string]$SettingsPath,
  [string]$AgentsPath,
  [string]$WrapperPath,
  [string]$Generation = "0",
  [string]$AuthToken,
  [string]$BaseUrl,
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
$unsetClientEnv = @()
if ($profile.PSObject.Properties.Name -contains "unset_client_env") {
  $unsetClientEnv = @($profile.unset_client_env | ForEach-Object { [string]$_ })
}
$desiredClientEnv = [ordered]@{}
foreach ($property in $profile.client_env.PSObject.Properties) {
  $desiredClientEnv[$property.Name] = [string]$property.Value
}
if ($BaseUrl.Trim()) {
  $desiredClientEnv["ANTHROPIC_BASE_URL"] = $BaseUrl.TrimEnd('/')
}
foreach ($name in $unsetClientEnv) {
  if ($settings.env.PSObject.Properties.Name -contains $name) {
    $drift.Add("settings.env.$name")
    if (-not $CheckOnly) { $settings.env.PSObject.Properties.Remove($name) }
  }
}
foreach ($entry in $desiredClientEnv.GetEnumerator()) {
  $current = if ($settings.env.PSObject.Properties.Name -contains $entry.Key) { [string]$settings.env.($entry.Key) } else { $null }
  if ($current -ne [string]$entry.Value) {
    $drift.Add("settings.env.$($entry.Key)")
    if (-not $CheckOnly) { Set-ObjectProperty $settings.env $entry.Key ([string]$entry.Value) }
  }
}
if ($AuthToken) {
  $currentAuthToken = if ($settings.env.PSObject.Properties.Name -contains "ANTHROPIC_AUTH_TOKEN") { [string]$settings.env.ANTHROPIC_AUTH_TOKEN } else { $null }
  if ($currentAuthToken -ne $AuthToken) {
    $drift.Add("settings.env.ANTHROPIC_AUTH_TOKEN")
    if (-not $CheckOnly) { Set-ObjectProperty $settings.env "ANTHROPIC_AUTH_TOKEN" $AuthToken }
  }
}

$markerName = "CLAUDE_PROVIDER_PROFILE_GENERATION"
if ([string]$settings.env.$markerName -ne [string]$Generation) {
  $drift.Add("settings.env.$markerName")
  if (-not $CheckOnly) { Set-ObjectProperty $settings.env $markerName ([string]$Generation) }
}

if ($EnvironmentTarget -ne "None") {
  $target = [Enum]::Parse([EnvironmentVariableTarget], $EnvironmentTarget)
  foreach ($name in $unsetClientEnv) {
    $current = [Environment]::GetEnvironmentVariable($name, $target)
    if ($null -ne $current) {
      $drift.Add("user_env.$name")
      if (-not $CheckOnly) { [Environment]::SetEnvironmentVariable($name, $null, $target) }
    }
  }
  $desiredUserEnvironment = [ordered]@{}
  foreach ($entry in $desiredClientEnv.GetEnumerator()) {
    $desiredUserEnvironment[$entry.Key] = [string]$entry.Value
  }
  if ($AuthToken) { $desiredUserEnvironment["ANTHROPIC_AUTH_TOKEN"] = $AuthToken }
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
  foreach ($name in $unsetClientEnv) {
    $escapedName = [regex]::Escape($name)
    $pattern = '(?im)^set\s+"{0}=.*?"\s*$' -f $escapedName
    $clearLine = "set `"$name=`""
    if ($updatedWrapper -match $pattern) {
      $updatedWrapper = [regex]::Replace($updatedWrapper, $pattern, $clearLine)
    } elseif ($updatedWrapper -match '(?im)^setlocal\s*$') {
      $updatedWrapper = [regex]::Replace($updatedWrapper, '(?im)^setlocal\s*$', "setlocal`r`n$clearLine", 1)
    } else {
      $updatedWrapper = "$clearLine`r`n$updatedWrapper"
    }
  }
  foreach ($entry in $desiredClientEnv.GetEnumerator()) {
    $escapedName = [regex]::Escape($entry.Key)
    $pattern = '(?im)^set\s+"{0}=.*?"\s*$' -f $escapedName
    if ($updatedWrapper -match $pattern) {
      $replacement = "set `"$($entry.Key)=$($entry.Value)`""
      $updatedWrapper = [regex]::Replace($updatedWrapper, $pattern, $replacement)
    } elseif ($updatedWrapper -match '(?im)^setlocal\s*$') {
      $replacement = "set `"$($entry.Key)=$($entry.Value)`""
      $updatedWrapper = [regex]::Replace($updatedWrapper, '(?im)^setlocal\s*$', "setlocal`r`n$replacement", 1)
    } else {
      $updatedWrapper = "set `"$($entry.Key)=$($entry.Value)`"`r`n$updatedWrapper"
    }
  }
  if ($AuthToken) {
    $authPattern = '(?im)^set\s+"ANTHROPIC_AUTH_TOKEN=.*?"\s*$'
    $authLine = "set `"ANTHROPIC_AUTH_TOKEN=$AuthToken`""
    if ($updatedWrapper -match $authPattern) {
      $updatedWrapper = [regex]::Replace($updatedWrapper, $authPattern, $authLine)
    } elseif ($updatedWrapper -match '(?im)^setlocal\s*$') {
      $updatedWrapper = [regex]::Replace($updatedWrapper, '(?im)^setlocal\s*$', "setlocal`r`n$authLine", 1)
    }
  }
  $nativeClaudePath = Join-Path (Split-Path -Parent $WrapperPath) "claude.exe"
  if ((Test-Path -LiteralPath $nativeClaudePath) -and $updatedWrapper -match '(?i)claude-real\.exe') {
    $updatedWrapper = [regex]::Replace($updatedWrapper, '(?i)claude-real\.exe', 'claude.exe')
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
