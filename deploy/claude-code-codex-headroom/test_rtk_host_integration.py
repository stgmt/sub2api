from pathlib import Path


ROOT = Path(__file__).resolve().parent
SKILL_ROOT = (
    ROOT / "../../backend/docs/skills/sub2api-claude-code-codex"
).resolve()


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_compose_shares_host_rtk_history_with_headroom() -> None:
    compose = read(ROOT / "docker-compose.yml")

    assert (
        "${HEADROOM_RTK_STATE_ROOT:-./data/rtk}:/root/.local/share/rtk"
        in compose
    )


def test_setup_installs_host_and_wsl_rtk_and_persists_state_path() -> None:
    setup = read(SKILL_ROOT / "scripts/setup-sub2api-claude-code.ps1")

    assert '[string]$RtkVersion = "v0.42.4"' in setup
    assert '[string]$RtkStateRoot = ""' in setup
    assert '[switch]$SkipRtk' in setup
    assert 'Set-DotEnvValue $envMap "HEADROOM_RTK_WIRING" "enabled"' in setup
    assert 'Set-DotEnvValue $envMap "HEADROOM_RTK_STATE_ROOT" $composeRtkStateRoot' in setup
    assert 'Join-Path $PSScriptRoot "install-claude-rtk.ps1"' in setup
    assert '& $rtkInstaller -Version $RtkVersion -WslDistro $WslDistro' in setup


def test_hook_bridge_is_msys_safe_and_probed_through_git_bash() -> None:
    installer = read(SKILL_ROOT / "scripts/install-claude-rtk.ps1")
    verifier = read(SKILL_ROOT / "scripts/verify-claude-code-sub2api.ps1")

    for script in (installer, verifier):
        assert "MSYS2_ARG_CONV_EXCL" in script
        assert "Git\\bin\\bash.exe" in script
        assert "-lc $hookCommand" in script or "-lc $command" in script

    assert "MSYS2_ARG_CONV_EXCL='*'" in installer
    assert "$payload | & $gitBash -lc $command" in installer
    assert "$payload | & $gitBash -lc $hookCommand" in verifier


def test_accuracy_exclusions_and_live_gain_checks_are_durable() -> None:
    installer = read(SKILL_ROOT / "scripts/install-claude-rtk.ps1")
    verifier = read(SKILL_ROOT / "scripts/verify-claude-code-sub2api.ps1")

    for command in ("cat", "git diff", "git show", "curl"):
        assert f'"{command}"' in installer
        assert f'"{command}"' in verifier

    assert "init --global --auto-patch" in installer
    assert "rtk gain --format json" in installer
    assert "Test-HeadroomRtkSharedState" in verifier
    assert 'Assert-DockerBindMount -Container "headroom-sub2api" -Destinations @("/root/.local/share/rtk")' in verifier
