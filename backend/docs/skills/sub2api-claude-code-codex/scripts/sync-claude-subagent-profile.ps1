[CmdletBinding()]
param(
  [string]$Model = "qwen3.8-max-preview",
  [ValidateSet("low", "medium", "high", "max")]
  [string]$Effort = "high",
  [string]$ClaudeHome = (Join-Path $HOME ".claude"),
  [string]$WrapperPath = (Join-Path $HOME ".local\bin\claude.cmd"),
  [switch]$SkipUserEnvironment,
  [switch]$CheckOnly
)

$ErrorActionPreference = "Stop"

$modelKeys = @(
  "ANTHROPIC_SMALL_FAST_MODEL",
  "ANTHROPIC_DEFAULT_OPUS_MODEL",
  "ANTHROPIC_DEFAULT_FABLE_MODEL",
  "ANTHROPIC_DEFAULT_SONNET_MODEL",
  "ANTHROPIC_DEFAULT_HAIKU_MODEL",
  "CLAUDE_CODE_SUBAGENT_MODEL"
)
$agentNames = @("general-purpose", "Explore", "workflow-subagent", "bench-reviewer", "bench-triage")
$mismatches = [System.Collections.Generic.List[string]]::new()

function Set-JsonProperty {
  param([object]$Object, [string]$Name, [object]$Value)

  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
  } else {
    $property.Value = $Value
  }
}

function Get-AgentText {
  param([string]$Name)

  $path = Join-Path (Join-Path $ClaudeHome "agents") "$Name.md"
  if (Test-Path -LiteralPath $path) {
    return Get-Content -LiteralPath $path -Raw
  }

  return @"
---
name: $Name
description: Global delegated Claude Code worker pinned by the sub2api Qwen profile.
model: $Model
effort: $Effort
---

Execute the delegated task with concrete evidence and return the result to the parent agent.
"@
}

function Set-AgentProfile {
  param([string]$Name)

  $agentsDir = Join-Path $ClaudeHome "agents"
  $path = Join-Path $agentsDir "$Name.md"
  $existed = Test-Path -LiteralPath $path
  $text = Get-AgentText -Name $Name
  if (-not $existed) {
    $mismatches.Add("agent:${Name}:missing")
  } else {
    $originalModel = [regex]::Match($text, "(?m)^model:\s*(.+)$")
    $originalEffort = [regex]::Match($text, "(?m)^effort:\s*(.+)$")
    if (-not $originalModel.Success -or $originalModel.Groups[1].Value.Trim() -ne $Model) {
      $mismatches.Add("agent:${Name}:model")
    }
    if (-not $originalEffort.Success -or $originalEffort.Groups[1].Value.Trim() -ne $Effort) {
      $mismatches.Add("agent:${Name}:effort")
    }
  }
  if ($text -match "(?ms)^---\s.*?\s---") {
    if ($text -match "(?m)^model:\s*.+$") {
      $text = $text -replace "(?m)^model:\s*.+$", "model: $Model"
    } else {
      $text = $text -replace "(?m)^description:\s*.+$", "`$0`nmodel: $Model"
    }
    if ($text -match "(?m)^effort:\s*.+$") {
      $text = $text -replace "(?m)^effort:\s*.+$", "effort: $Effort"
    } else {
      $text = $text -replace "(?m)^model:\s*.+$", "`$0`neffort: $Effort"
    }
  } else {
    $text = "---`nname: $Name`ndescription: Global delegated Claude Code worker pinned by the sub2api Qwen profile.`nmodel: $Model`neffort: $Effort`n---`n`n" + $text
  }

  if (-not $CheckOnly) {
    New-Item -ItemType Directory -Force -Path $agentsDir | Out-Null
    [IO.File]::WriteAllText($path, $text.TrimEnd() + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
  }
}

$settingsPath = Join-Path $ClaudeHome "settings.json"
if (Test-Path -LiteralPath $settingsPath) {
  $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
} else {
  $settings = [pscustomobject]@{}
}
if ($null -eq $settings.PSObject.Properties["env"]) {
  Set-JsonProperty -Object $settings -Name "env" -Value ([pscustomobject]@{})
}

foreach ($key in $modelKeys) {
  $current = $settings.env.PSObject.Properties[$key]
  if ($null -eq $current -or [string]$current.Value -ne $Model) {
    $mismatches.Add("settings:$key")
    if (-not $CheckOnly) {
      Set-JsonProperty -Object $settings.env -Name $key -Value $Model
    }
  }

  if (-not $SkipUserEnvironment) {
    $userValue = [Environment]::GetEnvironmentVariable($key, "User")
    if ($userValue -ne $Model) {
      $mismatches.Add("user-env:$key")
      if (-not $CheckOnly) {
        [Environment]::SetEnvironmentVariable($key, $Model, "User")
      }
    }
  }
}

if (-not $CheckOnly) {
  New-Item -ItemType Directory -Force -Path $ClaudeHome | Out-Null
  [IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 100) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}

foreach ($agentName in $agentNames) {
  Set-AgentProfile -Name $agentName
}

if (Test-Path -LiteralPath $WrapperPath) {
  $wrapper = Get-Content -LiteralPath $WrapperPath -Raw
  foreach ($key in $modelKeys) {
    $pattern = '(?im)^\s*set\s+"?' + [regex]::Escape($key) + '=[^\r\n"]*"?\s*$'
    $expected = 'set "' + $key + '=' + $Model + '"'
    if ($wrapper -match $pattern) {
      if ($Matches[0].Trim() -ne $expected) {
        $mismatches.Add("wrapper:$key")
        if (-not $CheckOnly) {
          $wrapper = [regex]::Replace($wrapper, $pattern, $expected)
        }
      }
    } else {
      $mismatches.Add("wrapper:$key")
      if (-not $CheckOnly) {
        $wrapper = $expected + "`r`n" + $wrapper
      }
    }
  }
  if (-not $CheckOnly) {
    [IO.File]::WriteAllText($WrapperPath, $wrapper, [Text.UTF8Encoding]::new($false))
  }
}

$result = [ordered]@{
  status = if ($CheckOnly -and $mismatches.Count -gt 0) { "mismatch" } elseif ($CheckOnly) { "ok" } else { "synced" }
  platform = "windows"
  claude_home = $ClaudeHome
  model = $Model
  effort = $Effort
  agents = $agentNames
  mismatches = @($mismatches)
}
$result | ConvertTo-Json -Depth 4

if ($CheckOnly -and $mismatches.Count -gt 0) {
  exit 1
}
