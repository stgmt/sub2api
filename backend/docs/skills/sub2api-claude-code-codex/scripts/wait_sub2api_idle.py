#!/usr/bin/env python3
"""Wait until sub2api has no in-flight Anthropic Messages requests."""

from __future__ import annotations

import argparse
import json
import re
import select
import subprocess
import sys
import time
from datetime import datetime, timezone


REQUEST_ID = re.compile(r"hr_[0-9]+_[0-9]+")
START_EVENT = "content_moderation.gateway_check_start"
DONE_EVENT = "http request completed"


def update_active(active: set[str], line: str) -> None:
    match = REQUEST_ID.search(line)
    if not match:
        return
    request_id = match.group(0)
    if START_EVENT in line:
        active.add(request_id)
    if DONE_EVENT in line:
        active.discard(request_id)


def docker_logs(args: list[str]) -> subprocess.Popen[str]:
    return subprocess.Popen(
        ["docker", "logs", *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        bufsize=1,
    )


def load_snapshot(container: str, since: str) -> set[str]:
    active: set[str] = set()
    process = docker_logs(["--since", since, container])
    assert process.stdout is not None
    for line in process.stdout:
        update_active(active, line)
    if process.wait() != 0:
        raise RuntimeError(f"docker logs snapshot failed for {container}")
    return active


def wait_for_idle(container: str, since: str, timeout: float, stable: float) -> dict[str, object]:
    follow_from = datetime.now(timezone.utc).isoformat()
    active = load_snapshot(container, since)
    process = docker_logs(["--follow", "--since", follow_from, container])
    assert process.stdout is not None
    started = time.monotonic()
    idle_since = time.monotonic() if not active else None

    try:
        while True:
            now = time.monotonic()
            if now - started >= timeout:
                raise TimeoutError(
                    f"drain timeout after {timeout:.1f}s with {len(active)} active request(s)"
                )
            if idle_since is not None and now - idle_since >= stable:
                return {
                    "status": "idle",
                    "active": 0,
                    "elapsed_seconds": round(now - started, 3),
                }

            wait = min(0.25, timeout - (now - started))
            ready, _, _ = select.select([process.stdout], [], [], max(wait, 0.01))
            if not ready:
                continue

            line = process.stdout.readline()
            if line == "":
                if process.poll() is not None:
                    raise RuntimeError("docker logs --follow ended before drain completed")
                continue
            update_active(active, line)
            idle_since = time.monotonic() if not active else None
    finally:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--container", default="sub2api-codex")
    parser.add_argument("--since", default="6h")
    parser.add_argument("--timeout", type=float, default=900)
    parser.add_argument("--stable-seconds", type=float, default=0.5)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        result = wait_for_idle(args.container, args.since, args.timeout, args.stable_seconds)
    except (RuntimeError, TimeoutError) as exc:
        print(json.dumps({"status": "blocked", "error": str(exc)}), file=sys.stderr)
        return 42
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
