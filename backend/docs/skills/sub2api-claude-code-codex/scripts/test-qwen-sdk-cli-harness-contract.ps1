[CmdletBinding()]
param(
  [string]$RepoRoot = ""
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\..\..\.."))
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$requiredFiles = @(
  "backend/docs/skills/sub2api-claude-code-codex/SKILL.md",
  "backend/docs/skills/sub2api-claude-code-codex/README.md",
  "backend/docs/skills/sub2api-claude-code-codex/evals/evals.json",
  "backend/docs/skills/sub2api-claude-code-codex/references/fullpower-profile.json",
  "backend/docs/skills/sub2api-claude-code-codex/references/group-and-compact-routing.md",
  "backend/docs/skills/sub2api-claude-code-codex/references/harness-publication.md",
  "backend/docs/skills/sub2api-claude-code-codex/references/session-failure-registry.md",
  "backend/docs/skills/sub2api-claude-code-codex/references/verification.md",
  "backend/docs/skills/sub2api-claude-code-codex/scripts/setup-sub2api-claude-code.ps1",
  "backend/docs/skills/sub2api-claude-code-codex/scripts/verify-claude-code-sub2api.ps1",
  "backend/docs/skills/sub2api-claude-code-codex/scripts/sync-sub2api-sdk-cli-routing.ps1",
  "backend/docs/skills/sub2api-claude-code-codex/scripts/sync-claude-subagent-profile.ps1",
  "backend/docs/skills/sub2api-claude-code-codex/scripts/sync-claude-subagent-profile.sh",
  "backend/docs/skills/sub2api-claude-code-codex/scripts/test-claude-subagent-profile-contract.ps1",
  "backend/docs/skills/sub2api-claude-code-codex/scripts/test-claude-subagent-profile-contract.sh",
  "backend/docs/skills/sub2api-claude-code-codex/scripts/test-qwen-sdk-cli-harness-contract.ps1",
  "deploy/claude-code-codex-headroom/.env.example",
  "deploy/claude-code-codex-headroom/docker-compose.yml",
  "deploy/claude-code-codex-headroom/docker-compose.gpu.yml",
  "deploy/claude-code-codex-headroom/Dockerfile.headroom",
  "deploy/claude-code-codex-headroom/start-headroom-proxy.sh",
  "deploy/claude-code-codex-headroom/test_fork_owned_compose_profile.py",
  "deploy/claude-code-codex-headroom/test_headroom_claude_code_streaming_patch.py",
  "deploy/claude-code-codex-headroom/test_rtk_host_integration.py",
  "backend/internal/domain/openai_messages_dispatch.go",
  "backend/internal/service/openai_messages_dispatch.go",
  "backend/internal/service/openai_messages_dispatch_test.go",
  "backend/internal/handler/claude_code_multiprovider.go",
  "backend/internal/handler/claude_code_multiprovider_test.go",
  "frontend/src/views/admin/groupsMessagesDispatch.ts",
  "frontend/src/views/admin/__tests__/groupsMessagesDispatch.spec.ts"
)

$missing = @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RepoRoot $_)) })
if ($missing.Count -gt 0) {
  throw "Required harness files are missing: $($missing -join ', ')"
}

Push-Location $RepoRoot
try {
  $untracked = @()
  foreach ($relativePath in $requiredFiles) {
    & git ls-files --error-unmatch -- $relativePath 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
      $untracked += $relativePath
    }
  }
  if ($untracked.Count -gt 0) {
    throw "Required harness files are not tracked by Git: $($untracked -join ', ')"
  }
} finally {
  Pop-Location
}

function Assert-Contains([string]$RelativePath, [string]$Pattern, [string]$Description) {
  $content = Get-Content -LiteralPath (Join-Path $RepoRoot $RelativePath) -Raw
  if ($content -notmatch $Pattern) {
    throw "$Description is missing from $RelativePath"
  }
}

Assert-Contains `
  "backend/docs/skills/sub2api-claude-code-codex/scripts/setup-sub2api-claude-code.ps1" `
  "sync-sub2api-sdk-cli-routing\.ps1" `
  "setup-to-SDK-CLI routing wiring"
Assert-Contains `
  "backend/docs/skills/sub2api-claude-code-codex/scripts/verify-claude-code-sub2api.ps1" `
  "sync-sub2api-sdk-cli-routing\.ps1[\s\S]*-CheckOnly" `
  "SDK CLI routing verification"
Assert-Contains `
  "backend/docs/skills/sub2api-claude-code-codex/scripts/sync-sub2api-sdk-cli-routing.ps1" `
  'sdk_cli_mapped_model' `
  "SDK CLI mapped-model persistence"
Assert-Contains `
  "backend/docs/skills/sub2api-claude-code-codex/scripts/sync-sub2api-sdk-cli-routing.ps1" `
  'sdk_cli_reasoning_effort' `
  "SDK CLI effort persistence"
Assert-Contains `
  "backend/internal/handler/claude_code_multiprovider.go" `
  'external, sdk-cli' `
  "SDK CLI User-Agent classifier"
Assert-Contains `
  "backend/internal/handler/claude_code_multiprovider_test.go" `
  'external, cli' `
  "interactive CLI negative control"
Assert-Contains `
  "frontend/src/views/admin/groupsMessagesDispatch.ts" `
  'sdk_cli_reasoning_effort' `
  "frontend lossless SDK CLI config round-trip"
Assert-Contains `
  "backend/docs/skills/sub2api-claude-code-codex/references/session-failure-registry.md" `
  'F29' `
  "standalone print-mode incident registry entry"
Assert-Contains `
  "backend/docs/skills/sub2api-claude-code-codex/evals/evals.json" `
  '"id"\s*:\s*28' `
  "standalone print-mode skill eval"

Write-Output "SUB2API_QWEN_HARNESS_CONTRACT_OK files=$($requiredFiles.Count)"
