from pathlib import Path
import json


ROOT = Path(__file__).resolve().parent


def read(name: str) -> str:
    return (ROOT / name).read_text(encoding="utf-8")


def test_headroom_image_builds_from_stgmt_fork_ref() -> None:
    dockerfile = read("Dockerfile.headroom")
    compose = read("docker-compose.yml")

    assert "ARG HEADROOM_GIT_REPO=https://github.com/stgmt/headroom.git" in dockerfile
    assert "ARG HEADROOM_GIT_REF=5a313c2e5bbf22c87b55efb8737cf2a4cd7ed54d" in dockerfile
    assert "ARG HEADROOM_RUST_TOOLCHAIN=1.88.0" in dockerfile
    assert "build-essential curl pkg-config" in dockerfile
    assert '--default-toolchain "${HEADROOM_RUST_TOOLCHAIN}"' in dockerfile
    assert "git+${HEADROOM_GIT_REPO}@${HEADROOM_GIT_REF}" in dockerfile
    assert "headroom-ai[proxy,code,relevance,html,spreadsheet,otel,reports,mcp]==" not in dockerfile
    assert "HEADROOM_GIT_REPO: ${HEADROOM_GIT_REPO:-https://github.com/stgmt/headroom.git}" in compose
    assert "HEADROOM_GIT_REF: ${HEADROOM_GIT_REF:-5a313c2e5bbf22c87b55efb8737cf2a4cd7ed54d}" in compose
    assert "HEADROOM_RUST_TOOLCHAIN: ${HEADROOM_RUST_TOOLCHAIN:-1.88.0}" in compose


def test_sub2api_service_records_fork_provenance() -> None:
    compose = read("docker-compose.yml")
    env_example = read(".env.example")

    assert "org.opencontainers.image.source: ${SUB2API_GIT_REPO:-https://github.com/stgmt/sub2api.git}" in compose
    assert "org.opencontainers.image.revision: ${SUB2API_GIT_REF:-local}" in compose
    assert "SUB2API_GIT_REPO=https://github.com/stgmt/sub2api.git" in env_example
    assert "SUB2API_GIT_REF=local" in env_example


def test_setup_script_preserves_fork_source_values() -> None:
    setup = (ROOT / "../../backend/docs/skills/sub2api-claude-code-codex/scripts/setup-sub2api-claude-code.ps1").resolve()
    text = setup.read_text(encoding="utf-8")

    assert '$HeadroomGitRepo = "https://github.com/stgmt/headroom.git"' in text
    assert '$HeadroomGitRef = "5a313c2e5bbf22c87b55efb8737cf2a4cd7ed54d"' in text
    assert '$HeadroomRustToolchain = "1.88.0"' in text
    assert '$Sub2apiGitRepo = "https://github.com/stgmt/sub2api.git"' in text
    assert 'Set-DotEnvValue $envMap "HEADROOM_GIT_REPO" $HeadroomGitRepo' in text
    assert 'Set-DotEnvValue $envMap "SUB2API_GIT_REF" $Sub2apiGitRef' in text


def test_fullpower_profile_tracks_both_forks() -> None:
    profile = json.loads(
        (ROOT / "../../backend/docs/skills/sub2api-claude-code-codex/references/fullpower-profile.json")
        .resolve()
        .read_text(encoding="utf-8")
    )

    assert profile["proxy"]["headroom"]["fork"] == "https://github.com/stgmt/headroom"
    assert profile["proxy"]["headroom"]["git_repo"] == "https://github.com/stgmt/headroom.git"
    assert profile["proxy"]["headroom"]["git_ref"] == "5a313c2e5bbf22c87b55efb8737cf2a4cd7ed54d"
    assert profile["proxy"]["headroom"]["rust_toolchain"] == "1.88.0"
    assert profile["proxy"]["sub2api"]["fork"] == "https://github.com/stgmt/sub2api"
