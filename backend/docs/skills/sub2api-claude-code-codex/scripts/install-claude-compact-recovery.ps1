param(
  [string]$ClaudeHome = "$env:USERPROFILE\.claude"
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceHook = Join-Path $scriptDir "compact-recovery.mjs"
if (-not (Test-Path -LiteralPath $sourceHook)) {
  throw "compact-recovery.mjs not found beside installer"
}

$hooksDir = Join-Path $ClaudeHome "hooks"
New-Item -ItemType Directory -Force -Path $hooksDir | Out-Null
$targetHook = Join-Path $hooksDir "compact-recovery.mjs"
Copy-Item -LiteralPath $sourceHook -Destination $targetHook -Force

$settingsPath = Join-Path $ClaudeHome "settings.json"
if (Test-Path -LiteralPath $settingsPath) {
  $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
} else {
  $settings = [pscustomobject]@{}
}

if (-not $settings.PSObject.Properties["hooks"]) {
  $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
}

function Ensure-HookEvent {
  param([string]$Name)
  if (-not $settings.hooks.PSObject.Properties[$Name]) {
    $settings.hooks | Add-Member -NotePropertyName $Name -NotePropertyValue @()
  }
}

function Add-CommandHook {
  param(
    [string]$Event,
    [string]$Mode,
    [string]$Matcher = "",
    [int]$Timeout = 5
  )
  Ensure-HookEvent $Event
  $nodeExe = "C:/Program Files/nodejs/node.exe"
  $hookPath = $targetHook.Replace("\", "/")
  $command = '"' + $nodeExe + '" "' + $hookPath + '" ' + $Mode
  $json = @{
    hooks = @(@{
      type = "command"
      command = $command
      timeout = $Timeout
    })
  }
  if ($Matcher) {
    $json.matcher = $Matcher
  }
  $exists = @($settings.hooks.$Event) | Where-Object {
    ($_ | ConvertTo-Json -Depth 8 -Compress) -like "*compact-recovery.mjs* $Mode*"
  }
  if (-not $exists) {
    $settings.hooks.$Event += [pscustomobject]$json
  }
}

Add-CommandHook -Event "PreCompact" -Matcher "manual|auto" -Mode "precompact"
Add-CommandHook -Event "PostCompact" -Matcher "manual|auto" -Mode "postcompact"
Add-CommandHook -Event "UserPromptSubmit" -Mode "userprompt"
Add-CommandHook -Event "SessionStart" -Matcher "compact" -Mode "sessionstart"

$json = $settings | ConvertTo-Json -Depth 20
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($settingsPath, $json + [Environment]::NewLine, $utf8NoBom)

Write-Host "Installed compact recovery hook: $targetHook"
Write-Host "Updated Claude settings: $settingsPath"
