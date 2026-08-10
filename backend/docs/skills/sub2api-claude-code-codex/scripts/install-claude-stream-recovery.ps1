param(
  [string]$ClaudeHome = "$env:USERPROFILE\.claude"
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceHook = Join-Path $scriptDir "claude-stream-recovery.mjs"
if (-not (Test-Path -LiteralPath $sourceHook)) {
  throw "claude-stream-recovery.mjs not found beside installer"
}

$node = Get-Command node.exe -ErrorAction Stop
$hooksDir = Join-Path $ClaudeHome "hooks"
New-Item -ItemType Directory -Force -Path $hooksDir | Out-Null
$targetHook = Join-Path $hooksDir "claude-stream-recovery.mjs"
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

foreach ($eventName in @("Stop", "SubagentStop")) {
  if (-not $settings.hooks.PSObject.Properties[$eventName]) {
    $settings.hooks | Add-Member -NotePropertyName $eventName -NotePropertyValue @()
  }
  $existing = @(
    @($settings.hooks.$eventName) | Where-Object {
      ($_ | ConvertTo-Json -Depth 10 -Compress) -notlike "*claude-stream-recovery.mjs*"
    }
  )
  $nodePath = $node.Source.Replace("\", "/")
  $hookPath = $targetHook.Replace("\", "/")
  $existing += [pscustomobject]@{
    hooks = @([pscustomobject]@{
      type = "command"
      command = '"' + $nodePath + '" "' + $hookPath + '"'
      timeout = 5
    })
  }
  $settings.hooks.$eventName = @($existing)
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$json = $settings | ConvertTo-Json -Depth 30
[System.IO.File]::WriteAllText($settingsPath, $json + [Environment]::NewLine, $utf8NoBom)

Write-Host "Installed Claude stream recovery hook: $targetHook"
Write-Host "Updated Claude settings: $settingsPath"
