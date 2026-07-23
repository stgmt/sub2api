from pathlib import Path
import json


ROOT = Path(__file__).resolve().parent


def read(name: str) -> str:
    return (ROOT / name).read_text(encoding="utf-8")


def test_headroom_image_builds_from_stgmt_fork_ref() -> None:
    dockerfile = read("Dockerfile.headroom")
    compose = read("docker-compose.yml")

    assert "ARG HEADROOM_GIT_REPO=https://github.com/stgmt/headroom.git" in dockerfile
    assert "ARG HEADROOM_GIT_REF=7077f5589b528a6f16ca43fcddad54c86bbc85d5" in dockerfile
    assert "ARG HEADROOM_RUST_TOOLCHAIN=1.88.0" in dockerfile
    assert "build-essential curl pkg-config" in dockerfile
    assert '--default-toolchain "${HEADROOM_RUST_TOOLCHAIN}"' in dockerfile
    assert "git+${HEADROOM_GIT_REPO}@${HEADROOM_GIT_REF}" in dockerfile
    assert "headroom-ai[proxy,code,relevance,html,spreadsheet,otel,reports,mcp]==" not in dockerfile
    assert "HEADROOM_GIT_REPO: ${HEADROOM_GIT_REPO:-https://github.com/stgmt/headroom.git}" in compose
    assert "HEADROOM_GIT_REF: ${HEADROOM_GIT_REF:-7077f5589b528a6f16ca43fcddad54c86bbc85d5}" in compose
    assert "HEADROOM_RUST_TOOLCHAIN: ${HEADROOM_RUST_TOOLCHAIN:-1.88.0}" in compose


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
    assert '$HeadroomGitRef = "7077f5589b528a6f16ca43fcddad54c86bbc85d5"' in text
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
    assert profile["proxy"]["headroom"]["git_ref"] == "7077f5589b528a6f16ca43fcddad54c86bbc85d5"
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
    assert "target: ${HEADROOM_DOCKER_TARGET:-cpu}" in compose
    assert "HEADROOM_KOMPRESS_BACKEND: ${HEADROOM_KOMPRESS_BACKEND:-auto}" in compose
    assert "gpus: all" in gpu_compose
    assert "target: gpu" in gpu_compose
    assert "HEADROOM_KOMPRESS_BACKEND: pytorch" in gpu_compose


def test_setup_and_autostart_select_gpu_overlay_from_env() -> None:
    scripts = (ROOT / "../../backend/docs/skills/sub2api-claude-code-codex/scripts").resolve()
    setup = (scripts / "setup-sub2api-claude-code.ps1").read_text(encoding="utf-8")
    start = (scripts / "start-sub2api-proxy-stack.ps1").read_text(encoding="utf-8")

    assert 'ValidateSet("auto", "cpu", "cuda")' in setup
    assert 'Set-DotEnvValue $envMap "HEADROOM_ACCELERATOR"' in setup
    assert 'Set-DotEnvValue $envMap "HEADROOM_DOCKER_TARGET"' in setup
    assert 'Set-DotEnvValue $envMap "HEADROOM_KOMPRESS_BACKEND"' in setup
    assert 'docker-compose.gpu.yml' in setup
    assert 'Get-DotEnvValue -Path $envPath -Name "HEADROOM_ACCELERATOR"' in start
    assert 'docker-compose.gpu.yml' in start


def test_autostart_retries_transient_wsl_service_failures() -> None:
    scripts = (ROOT / "../../backend/docs/skills/sub2api-claude-code-codex/scripts").resolve()
    start = (scripts / "start-sub2api-proxy-stack.ps1").read_text(encoding="utf-8")

    assert '-replace "`0", ""' in start
    assert "Wsl/Service" in start
    assert "0x8007274c" in start
    assert "WSL service transient on attempt $attempt; retrying" in start


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
