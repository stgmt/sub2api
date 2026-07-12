from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent
PATCH = ROOT / "patch-headroom-claude-code-streaming.py"
TEST = ROOT / "test_headroom_claude_code_streaming_patch.py"


@dataclass(frozen=True)
class Mutation:
    name: str
    target: str
    replacement: str


MUTATIONS = [
    Mutation(
        name="skip_anthropic_no202_patch",
        target="if ANTHROPIC_NO_202_SENTINEL not in text:",
        replacement="if False and ANTHROPIC_NO_202_SENTINEL not in text:",
    ),
    Mutation(
        name="ignore_claude_agent_id",
        target=(
            '    claude_agent = request.headers.get("x-claude-code-agent-id") or "main"\n'
            '    return f"claude-code:{{claude_session}}:{{claude_agent}}"\n'
        ),
        replacement=(
            '    claude_agent = "main"\n'
            '    return f"claude-code:{{claude_session}}:{{claude_agent}}"\n'
        ),
    ),
    Mutation(
        name="skip_handler_watchdog_patch",
        target="if ANTHROPIC_HANDLER_WATCHDOG_SENTINEL not in text:",
        replacement="if False and ANTHROPIC_HANDLER_WATCHDOG_SENTINEL not in text:",
    ),
    Mutation(
        name="skip_active_stream_refcount_patch",
        target="if STREAMING_ACTIVE_COUNT_SENTINEL not in text:",
        replacement="if False and STREAMING_ACTIVE_COUNT_SENTINEL not in text:",
    ),
    Mutation(
        name="do_not_fail_closed_on_unknown_shape",
        target='raise RuntimeError(f"Could not find Anthropic mid-turn overlap branch in {path}")',
        replacement="return",
    ),
    Mutation(
        name="break_idempotency_by_forcing_repatch",
        target="if ANTHROPIC_SESSION_SENTINEL not in text:",
        replacement="if True:",
    ),
]


def run_test(workdir: Path) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            [sys.executable, str(workdir / TEST.name)],
            cwd=workdir,
            text=True,
            capture_output=True,
            check=False,
            timeout=20,
        )
    except subprocess.TimeoutExpired as exc:
        return subprocess.CompletedProcess(
            args=exc.cmd,
            returncode=124,
            stdout=exc.stdout or "",
            stderr=(exc.stderr or "") + "\nmutation test timed out",
        )


def copy_case(root: Path) -> Path:
    workdir = root / "case"
    workdir.mkdir()
    shutil.copy2(PATCH, workdir / PATCH.name)
    shutil.copy2(TEST, workdir / TEST.name)
    return workdir


def mutate_patch(workdir: Path, mutation: Mutation) -> None:
    patch = workdir / PATCH.name
    text = patch.read_text(encoding="utf-8")
    count = text.count(mutation.target)
    if count != 1:
        raise RuntimeError(
            f"{mutation.name}: expected exactly one mutation target, got {count}"
        )
    patch.write_text(
        text.replace(mutation.target, mutation.replacement, 1),
        encoding="utf-8",
    )


def output_hint(result: subprocess.CompletedProcess[str]) -> str:
    combined = "\n".join(
        line
        for line in (result.stderr + "\n" + result.stdout).splitlines()
        if line.strip()
    )
    if not combined:
        return "<no output>"
    return combined[-240:]


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)

        baseline_dir = copy_case(root)
        baseline = run_test(baseline_dir)
        if baseline.returncode != 0:
            print("BASELINE FAILED")
            print(output_hint(baseline))
            raise SystemExit(1)
        print("baseline PASS")

        survived: list[str] = []
        for mutation in MUTATIONS:
            case_dir = root / mutation.name
            shutil.copytree(baseline_dir, case_dir)
            mutate_patch(case_dir, mutation)
            result = run_test(case_dir)
            if result.returncode == 0:
                survived.append(mutation.name)
                print(f"{mutation.name}: SURVIVED")
            else:
                print(f"{mutation.name}: KILLED ({output_hint(result)})")

        if survived:
            print("survived mutations: " + ", ".join(survived))
            raise SystemExit(1)

        print(f"mutation score: {len(MUTATIONS)}/{len(MUTATIONS)} killed")


if __name__ == "__main__":
    main()
