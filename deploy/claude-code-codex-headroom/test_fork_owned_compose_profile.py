from pathlib import Path
import json


ROOT = Path(__file__).resolve().parent


def read(name: str) -> str:
    return (ROOT / name).read_text(encoding="utf-8")


def test_headroom_image_builds_from_stgmt_fork_ref() -> None:
    dockerfile = read("Dockerfile.headroom")
    compose = read("docker-compose.yml")

    assert "ARG HEADROOM_GIT_REPO=https://github.com/stgmt/headroom.git" in dockerfile
    assert "ARG HEADROOM_GIT_REF=773755d469e0dfda5952ea77976f861be0f1679c" in dockerfile
    assert "ARG HEADROOM_RUST_TOOLCHAIN=1.88.0" in dockerfile
    assert "build-essential curl pkg-config" in dockerfile
    assert '--default-toolchain "${HEADROOM_RUST_TOOLCHAIN}"' in dockerfile
    assert "git+${HEADROOM_GIT_REPO}@${HEADROOM_GIT_REF}" in dockerfile
    assert "headroom-ai[proxy,code,relevance,html,spreadsheet,otel,reports,mcp]==" not in dockerfile
    assert "HEADROOM_GIT_REPO: ${HEADROOM_GIT_REPO:-https://github.com/stgmt/headroom.git}" in compose
    assert "HEADROOM_GIT_REF: ${HEADROOM_GIT_REF:-773755d469e0dfda5952ea77976f861be0f1679c}" in compose
    assert "HEADROOM_RUST_TOOLCHAIN: ${HEADROOM_RUST_TOOLCHAIN:-1.88.0}" in compose
    assert "stop_grace_period: 90s" in compose


def test_sub2api_service_records_fork_provenance() -> None:
    compose = read("docker-compose.yml")
    env_example = read(".env.example")

    assert "org.opencontainers.image.source: ${SUB2API_GIT_REPO:-https://github.com/stgmt/sub2api.git}" in compose
    assert "org.opencontainers.image.revision: ${SUB2API_GIT_REF:-local}" in compose
    assert "SUB2API_GIT_REPO=https://github.com/stgmt/sub2api.git" in env_example
    assert "SUB2API_GIT_REF=local" in env_example
    assert "${SUB2API_STATE_ROOT:-./data}/postgres:/var/lib/postgresql" in compose
    assert "${SUB2API_STATE_ROOT:-./data}/postgres:/var/lib/postgresql/data" not in compose
    assert "SUB2API_OPENAI_CODEX_AUTH_FILE: ${SUB2API_OPENAI_CODEX_AUTH_FILE:-/app/data/codex-auth.json}" in compose
    assert "SUB2API_OPENAI_CODEX_AUTH_FILE=/app/data/codex-auth.json" in env_example


def test_setup_script_preserves_fork_source_values() -> None:
    setup = (ROOT / "../../backend/docs/skills/sub2api-claude-code-codex/scripts/setup-sub2api-claude-code.ps1").resolve()
    text = setup.read_text(encoding="utf-8")

    assert '$HeadroomGitRepo = "https://github.com/stgmt/headroom.git"' in text
    assert '$HeadroomGitRef = "773755d469e0dfda5952ea77976f861be0f1679c"' in text
    assert '$HeadroomRustToolchain = "1.88.0"' in text
    assert '$Sub2apiGitRepo = "https://github.com/stgmt/sub2api.git"' in text
    assert 'Set-DotEnvValue $envMap "HEADROOM_GIT_REPO" $HeadroomGitRepo' in text
    assert 'Set-DotEnvValue $envMap "SUB2API_GIT_REF" $Sub2apiGitRef' in text
    assert 'Set-DotEnvValue $envMap "SUB2API_OPENAI_CODEX_AUTH_FILE" "/app/data/codex-auth.json"' in text


def test_fullpower_profile_tracks_both_forks() -> None:
    profile = json.loads(
        (ROOT / "../../backend/docs/skills/sub2api-claude-code-codex/references/fullpower-profile.json")
        .resolve()
        .read_text(encoding="utf-8")
    )

    assert profile["proxy"]["headroom"]["fork"] == "https://github.com/stgmt/headroom"
    assert profile["proxy"]["headroom"]["git_repo"] == "https://github.com/stgmt/headroom.git"
    assert profile["proxy"]["headroom"]["git_ref"] == "773755d469e0dfda5952ea77976f861be0f1679c"
    assert profile["proxy"]["headroom"]["upstream_429_hold_enabled"] is True
    assert profile["proxy"]["headroom"]["upstream_429_max_wait_seconds"] == 21600
    assert profile["proxy"]["headroom"]["upstream_429_heartbeat_seconds"] == 15
    assert profile["proxy"]["headroom"]["rust_toolchain"] == "1.88.0"
    assert profile["proxy"]["sub2api"]["fork"] == "https://github.com/stgmt/sub2api"


def test_headroom_gpu_stage_and_overlay_are_explicit() -> None:
    dockerfile = read("Dockerfile.headroom")
    compose = read("docker-compose.yml")
    gpu_compose = read("docker-compose.gpu.yml")

    assert "FROM headroom-base AS cpu" in dockerfile
    assert "FROM headroom-base AS gpu" in dockerfile
    assert "ARG HEADROOM_TORCH_VERSION=" in dockerfile
    assert "ARG HEADROOM_TORCH_INDEX_URL=" in dockerfile
    assert 'python -m pip install "torch==${HEADROOM_TORCH_VERSION}"' in dockerfile
    assert "torch.cuda.is_available()" in dockerfile
    assert "target: ${HEADROOM_DOCKER_TARGET:-gpu}" in compose
    assert "HEADROOM_KOMPRESS_BACKEND: ${HEADROOM_KOMPRESS_BACKEND:-auto}" in compose
    assert "gpus: all" in compose
    assert "target: gpu" in gpu_compose
    assert "HEADROOM_KOMPRESS_BACKEND: pytorch" in gpu_compose
    assert 'HEADROOM_FORCE_KOMPRESS: "1"' in gpu_compose
    assert 'HEADROOM_DISABLE_KOMPRESS: "0"' in gpu_compose
    assert 'HEADROOM_REQUIRE_CUDA: "1"' in gpu_compose


def test_setup_and_autostart_select_gpu_overlay_from_env() -> None:
    scripts = (ROOT / "../../backend/docs/skills/sub2api-claude-code-codex/scripts").resolve()
    setup = (scripts / "setup-sub2api-claude-code.ps1").read_text(encoding="utf-8")
    start = (scripts / "start-sub2api-proxy-stack.ps1").read_text(encoding="utf-8")

    assert 'ValidateSet("auto", "cpu", "cuda")' in setup
    assert 'Set-DotEnvValue $envMap "HEADROOM_ACCELERATOR"' in setup
    assert 'Set-DotEnvValue $envMap "HEADROOM_DOCKER_TARGET"' in setup
    assert 'Set-DotEnvValue $envMap "HEADROOM_KOMPRESS_BACKEND"' in setup
    assert 'if ($Existing -eq "cuda") { return "cuda" }' in setup
    assert 'docker-compose.gpu.yml' in setup
    assert 'Get-DotEnvValue -Path $envPath -Name "HEADROOM_ACCELERATOR"' in start
    assert 'if ($HeadroomAccelerator -eq "auto")' in start
    assert 'auto accelerator resolved to cuda; applying GPU compose overlay' in start
    assert 'docker-compose.gpu.yml' in start


def test_autostart_retries_transient_wsl_service_failures() -> None:
    scripts = (ROOT / "../../backend/docs/skills/sub2api-claude-code-codex/scripts").resolve()
    start = (scripts / "start-sub2api-proxy-stack.ps1").read_text(encoding="utf-8")

    assert '-replace "`0", ""' in start
    assert "Wsl/Service" in start
    assert "0x8007274c" in start
    assert "WSL service transient on attempt $attempt; retrying" in start


def test_normal_autostart_cannot_recreate_a_live_stream() -> None:
    scripts = (ROOT / "../../backend/docs/skills/sub2api-claude-code-codex/scripts").resolve()
    start = (scripts / "start-sub2api-proxy-stack.ps1").read_text(encoding="utf-8")
    ensure = (scripts / "ensure-sub2api-proxy-stack.ps1").read_text(encoding="utf-8")

    assert '[switch]$ForceRecreate' in start
    assert '$recreateFlag = if ($ForceRecreate) { "--force-recreate" } else { "--no-recreate" }' in start
    assert 'up -d --remove-orphans $recreateFlag' in start
    assert 'ForceRecreate = $true' in ensure
    assert 'SSE/tool turn' in start
    assert 'function Invoke-HeadroomStatsProbe' in ensure
    assert 'function Get-ActiveHeadroomState' in ensure
    assert 'function Get-StackLifecycleState' in ensure
    assert 'recovery_deferred' in ensure
    assert 'active_proxy_requests' in ensure
    assert 'active_state_unproven' in ensure
    assert 'active -eq 0' in ensure
    assert 'missing_or_stopped' in ensure
    assert "Where-Object { ([string]$_).Trim() -match '^/' }" in ensure
    assert 'function Get-HeadroomImageState' in ensure
    assert 'function Invoke-HeadroomIdleRollout' in ensure
    assert 'param([System.Collections.IDictionary]$ImageState)' in ensure
    assert 'headroom_image_rollout_deferred' in ensure
    assert '--no-deps --force-recreate headroom' in ensure


def test_stream_trace_contract_is_durable_and_correlation_is_explicit() -> None:
    patch = read("patch-headroom-claude-code-streaming.py")

    assert "STREAMING_TRACE_SENTINEL" in patch
    assert 'outbound_headers["x-headroom-request-id"] = request_id' in patch
    assert 'stream_output_started' in patch
    assert 'stream_completed_normally' in patch
    assert 'client_disconnect_or_cancel' in patch
    assert "After the first yielded byte, never replay" in patch
    assert 'final_tags = dict(tags or {})' in patch
    assert 'tags=final_tags' in patch
    assert 'event=claude_code_stream_finalize_failed' in patch
    assert "'                tags = dict(tags or {})\\n'" not in patch
    assert 'forwarded_start = text.find("        forwarded_headers =")' in patch
    assert 'could not locate _stream_response_inner generator' in patch


def test_verifier_retries_wsl_and_cannot_false_green_gpu_as_cpu() -> None:
    scripts = (ROOT / "../../backend/docs/skills/sub2api-claude-code-codex/scripts").resolve()
    verifier = (scripts / "verify-claude-code-sub2api.ps1").read_text(encoding="utf-8")

    assert "wsl.exe -d $WslDistro -- docker" in verifier
    assert '0x8007274c' in verifier
    assert 'if ($LASTEXITCODE -ne 0)' in verifier
    assert "GPU/CPU profile cannot be classified" in verifier
    assert verifier.count("Test-HeadroomGpuRuntime") == 3
    assert '$oldErrorActionPreference = $ErrorActionPreference' in verifier
    assert '$ErrorActionPreference = "Continue"' in verifier
    assert '$ErrorActionPreference = $oldErrorActionPreference' in verifier


def test_verifier_uses_active_profile_for_all_wrapper_picker_aliases() -> None:
    scripts = (ROOT / "../../backend/docs/skills/sub2api-claude-code-codex/scripts").resolve()
    verifier = (scripts / "verify-claude-code-sub2api.ps1").read_text(encoding="utf-8")

    for slot in ("Opus", "Fable", "Sonnet"):
        assert f'ANTHROPIC_DEFAULT_{slot.upper()}_MODEL' in verifier
        assert f'-Default{slot}Model $Default{slot}Model' in verifier
        assert f'-Default{slot}Model "qwen3.8-max-preview"' not in verifier

    assert 'if ($isNativeClaudeProfile) { "claude-subscription-only" }' in verifier
    assert 'elseif ($isChatGPTOnlyProfile) { "chatgpt-subscription-only" }' in verifier
    assert '$sdkCliAutomaticFallbackModel = ""' in verifier
    assert '-Effort $sdkCliEffort' in verifier
    assert 'Claude subagent profile contract check failed' in verifier
    assert 'Claude wrapper model contract check failed' in verifier
    assert '$sdkCliModel = $SubagentModel -replace' in verifier
    assert '$usesNativeRtk = $hookCommand.Trim() -eq "rtk hook claude"' in verifier
    assert '-DefaultOpusModel $DefaultOpusModel' in verifier

    sdk_sync = (scripts / "sync-sub2api-sdk-cli-routing.ps1").read_text(encoding="utf-8")
    assert "$fallbackUpdateSql = if ($fallbackModelSql)" in sdk_sync
    assert "- '$modelSql'" in sdk_sync
    assert "AND NOT (COALESCE(messages_dispatch_model_config->'model_fallbacks'" in sdk_sync
    assert "$automaticFallbackUpdateSql = if ($automaticFallbackModelSql)" in sdk_sync
    assert "automatic_model_fallbacks" in sdk_sync

    subagent_sync = (scripts / "sync-claude-subagent-profile.ps1").read_text(encoding="utf-8")
    assert '[ValidateSet("low", "medium", "high", "xhigh", "max")]' in subagent_sync
    assert "$modelValues = [ordered]@{" in subagent_sync
    assert "ANTHROPIC_DEFAULT_OPUS_MODEL = $DefaultOpusModel" in subagent_sync


def test_gpu_research_and_manual_watchdog_are_repo_owned() -> None:
    skill = (ROOT / "../../backend/docs/skills/sub2api-claude-code-codex").resolve()
    reference = (skill / "references/headroom-gpu-kompress.md").read_text(encoding="utf-8")
    watchdog = (skill / "scripts/watch-claude-proxy-stack.ps1").read_text(encoding="utf-8")

    assert "CPU ONNX" in reference
    assert "CUDA PyTorch" in reference
    assert "Known Remaining Work" in reference
    assert "[switch]$RequireCuda" in watchdog
    assert "Get-HeadroomGpuRuntime" in watchdog
    assert "wsl.exe -d $Distro -- docker" in watchdog
    assert "PSNativeCommandUseErrorActionPreference" in watchdog
    assert "$exit = $LASTEXITCODE" in watchdog
    assert "for ($attempt = 1; $attempt -le 3; $attempt++)" in watchdog
    assert "Start-Sleep -Milliseconds (250 * $attempt)" in watchdog
    assert "WSL Docker command failed after 3 attempts" in watchdog
    assert "Sub2API Codex Proxy Stack Autostart" not in watchdog


def test_loopback_profile_cannot_fall_back_to_headroom_60_rpm() -> None:
    compose = read("docker-compose.yml")
    env_example = read(".env.example")
    setup = (
        ROOT / "../../backend/docs/skills/sub2api-claude-code-codex/scripts/setup-sub2api-claude-code.ps1"
    ).resolve().read_text(encoding="utf-8")
    probe = (
        ROOT / "../../backend/docs/skills/sub2api-claude-code-codex/scripts/test-headroom-rate-limit-burst.mjs"
    ).resolve().read_text(encoding="utf-8")
    verifier = (
        ROOT / "../../backend/docs/skills/sub2api-claude-code-codex/scripts/verify-claude-code-sub2api.ps1"
    ).resolve().read_text(encoding="utf-8")

    assert "HEADROOM_RPM: ${HEADROOM_RPM:-6000}" in compose
    assert "HEADROOM_TPM: ${HEADROOM_TPM:-100000000}" in compose
    assert "HEADROOM_RPM=6000" in env_example
    assert "HEADROOM_TPM=100000000" in env_example
    assert '[int]$HeadroomRequestsPerMinute = 6000' in setup
    assert '[int]$HeadroomTokensPerMinute = 100000000' in setup
    assert 'Set-DotEnvValue $envMap "HEADROOM_RPM"' in setup
    assert 'Set-DotEnvValue $envMap "HEADROOM_TPM"' in setup
    assert "rate_limited" in probe
    assert "process.exitCode = 1" in probe
    assert "function Test-HeadroomRateLimitProfile" in verifier
    assert "expected at least 6000/100000000" in verifier
    assert "function Test-HeadroomRequestHistory" in verifier
    assert "did not expose durable request_history" in verifier
    assert 'Test-HeadroomRequestHistory $BaseUrl' in verifier


def test_headroom_holds_long_upstream_rate_limit_windows() -> None:
    compose = read("docker-compose.yml")
    env_example = read(".env.example")
    setup = (
        ROOT / "../../backend/docs/skills/sub2api-claude-code-codex/scripts/setup-sub2api-claude-code.ps1"
    ).resolve().read_text(encoding="utf-8")

    assert "HEADROOM_RETRY_MAX_ATTEMPTS: ${HEADROOM_RETRY_MAX_ATTEMPTS:-10}" in compose
    assert "HEADROOM_RETRY_MAX_ATTEMPTS=10" in env_example
    assert "[int]$HeadroomRetryMaxAttempts = 10" in setup
    assert 'Set-DotEnvValue $envMap "HEADROOM_RETRY_MAX_ATTEMPTS"' in setup
    assert (
        "HEADROOM_UPSTREAM_429_HOLD_ENABLED: "
        "${HEADROOM_UPSTREAM_429_HOLD_ENABLED:-1}" in compose
    )
    assert "HEADROOM_UPSTREAM_429_MAX_WAIT_SECONDS:-21600" in compose
    assert "HEADROOM_UPSTREAM_429_HEARTBEAT_SECONDS:-15" in compose
    assert "HEADROOM_UPSTREAM_429_HOLD_ENABLED=1" in env_example
    assert "HEADROOM_UPSTREAM_429_MAX_WAIT_SECONDS=21600" in env_example
    assert "HEADROOM_UPSTREAM_RECOVERY_HOLD_STATUSES:-429,502,503,504,529" in compose
    assert "HEADROOM_UPSTREAM_RECOVERY_HOLD_STATUSES=429,502,503,504,529" in env_example
    assert '[string]$HeadroomUpstream429HoldEnabled = "1"' in setup
    assert "[int]$HeadroomUpstream429MaxWaitSeconds = 21600" in setup
    assert (
        '[string]$HeadroomUpstreamRecoveryHoldStatuses = "429,502,503,504,529"'
        in setup
    )
    assert 'Set-DotEnvValue $envMap "HEADROOM_UPSTREAM_429_HOLD_ENABLED"' in setup
    assert (
        'Set-DotEnvValue $envMap "HEADROOM_UPSTREAM_RECOVERY_HOLD_STATUSES"'
        in setup
    )
    verifier = (
        ROOT
        / "../../backend/docs/skills/sub2api-claude-code-codex/scripts/verify-claude-code-sub2api.ps1"
    ).resolve().read_text(encoding="utf-8")
    assert "function Test-HeadroomUpstream429HoldProfile" in verifier
    assert "HEADROOM_UPSTREAM_429_HOLD_ENABLED=1" in verifier
    assert "max wait must be at least 21600 seconds" in verifier
    assert "runtime.upstream_recovery" in verifier
    assert "transport_failures_total" in verifier
    assert "Test-HeadroomUpstream429HoldProfile" in verifier


def test_cross_session_failure_registry_and_evals_are_repo_owned() -> None:
    skill_root = (
        ROOT / "../../backend/docs/skills/sub2api-claude-code-codex"
    ).resolve()
    skill = (skill_root / "SKILL.md").read_text(encoding="utf-8")
    registry = (skill_root / "references/session-failure-registry.md").read_text(
        encoding="utf-8"
    )
    evals = json.loads((skill_root / "evals/evals.json").read_text(encoding="utf-8"))[
        "evals"
    ]

    assert "references/session-failure-registry.md" in skill
    for incident in range(1, 30):
        assert f"`F{incident:02d}`" in registry
    assert "`F37`" in registry

    eval_ids = [item["id"] for item in evals]
    assert eval_ids == list(range(1, max(eval_ids) + 1))
    assert max(eval_ids) >= 39
    new_prompts = "\n".join(item["prompt"] for item in evals if item["id"] >= 16)
    for symptom in (
        "/compact",
        "No tool output found",
        "429",
        "incomplete chunked read",
        "context-mode",
        "сотни сабагентов",
        "CLAUDE_CODE_EFFORT_LEVEL",
        "Kompress",
        "анализ и отчёт only",
        "тесты зелёные",
        "Compacted",
        "proxy-requests.jsonl",
    ):
        assert symptom in new_prompts
