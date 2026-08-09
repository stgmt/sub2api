from __future__ import annotations

import asyncio
import hashlib
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import types
import unittest


PATCH = Path(__file__).with_name("patch-headroom-claude-code-streaming.py")


STREAMING_FIXTURE = """
import asyncio
import json
import logging
import time
from typing import Any

logger = logging.getLogger("headroom.proxy")


class StreamingHandler:
    _mid_turn_queues: dict[str, asyncio.Queue] = {}
    _active_streams: set[str] = set()

    def __init__(self) -> None:
        self.finalized_tags: dict[str, str] | None = None
        self.raise_in_finalizer = False

    @staticmethod
    def _get_session_key(body: dict, session_header: str | None = None) -> str:
        return session_header or "derived-session"

    def _queue_mid_turn_message(self, session_key: str, body: dict) -> dict:
        if session_key not in self._mid_turn_queues:
            self._mid_turn_queues[session_key] = asyncio.Queue()
        self._mid_turn_queues[session_key].put_nowait(body)
        return {"status": 202, "event": "headroom_queued"}

    def _cleanup_mid_turn_stream(
        self, session_key: str, *, drain_pending_messages: bool = False
    ) -> list[dict]:
        self._active_streams.discard(session_key)
        queue = self._mid_turn_queues.pop(session_key, None)
        if not drain_pending_messages or queue is None or queue.empty():
            return []
        return [queue.get_nowait()]

    async def _finalize_stream_response(self, **kwargs: Any) -> None:
        self.finalized_tags = dict(kwargs["tags"])
        if self.raise_in_finalizer:
            raise RuntimeError("injected telemetry finalizer failure")

    async def _stream_response(
        self,
        url: str,
        headers: dict,
        body: dict,
        provider: str,
        model: str,
        request_id: str,
        original_tokens: int,
        optimized_tokens: int,
        tokens_saved: int,
        transforms_applied: list[str],
        tags: dict[str, str],
        optimization_latency: float,
        session_key: str | None = None,
    ):
        session_key = session_key or self._get_session_key(body)
        self._active_streams.add(session_key)

        # Guard everything up to the generator's own try/finally
        return await self._stream_response_inner()

    async def _stream_response_inner(self):
        headers = {}
        body = {"stream": True}
        provider = "anthropic"
        outcome_provider = "openai"
        model = "gpt-5.6-luna"
        request_id = "request-id"
        original_tokens = 12
        optimized_tokens = 8
        tokens_saved = 4
        transforms_applied = ["fixture"]
        tags = {"existing": "tag"}
        optimization_latency = 0.001
        pipeline_timing = {}
        prefix_tracker = None
        original_messages = []
        client = "claude-code"
        waste_signals = {}
        session_key = "session-1"
        start_time = time.time()
        outbound_headers = {**headers, "content-type": "application/json"}
        chunks = [
            b'event: message_start\\ndata: {"type":"message_start"}\\n\\n',
            b'event: content_block_delta\\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"OK"}}\\n\\n',
            b'event: message_stop\\ndata: {"type":"message_stop"}\\n\\n',
        ]
        stream_state: dict[str, Any] = {
            "total_bytes": 0,
            "ttfb_ms": None,  # Time to first byte from upstream
        }
        forwarded_headers = {}

        async def generate():
            full_sse_bytes = bytearray()
            parsed_response = None
            completed_normally = False
            try:
                for chunk in chunks:
                    full_sse_bytes.extend(chunk)
                    stream_state["total_bytes"] += len(chunk)
                    yield chunk
                completed_normally = True
            except (httpx.ConnectError, httpx.ConnectTimeout, httpx.PoolTimeout) as e:
                logger.error(f"[{request_id}] Connection error to upstream API: {e}")
            except httpx.HTTPStatusError as e:
                logger.error(f"[{request_id}] HTTP error from upstream API: {e}")
            except Exception as e:
                logger.error(f"[{request_id}] Unexpected streaming error: {e}")
            finally:
                pending_messages = self._cleanup_mid_turn_stream(
                    session_key
                )
                await self._finalize_stream_response(
                    tags=tags,
                )

        return generate()
"""


ANTHROPIC_FIXTURE = """
import asyncio
import logging
from typing import Any

logger = logging.getLogger("headroom.proxy")


class AnthropicHandlerMixin:
    async def handle_anthropic_messages(
        self,
        request: Any,
        upstream_base_url: str | None = None,
        provider_name: str = "anthropic",
        model_override: str | None = None,
        force_stream: bool = False,
    ):
        body = getattr(request, "body", {"stream": True})
        stream = body.get("stream", True)
        buffered_stream_ccr = body.get("buffered_stream_ccr", False)
        if (
            request.headers.get("x-sub2api-headroom-watchdog-retry") == "1"
            and not body.get("sleep_forever_after_retry")
        ):
            return "retry-ok"
        if body.get("sleep_forever"):
            await asyncio.sleep(3600)
        if stream and not buffered_stream_ccr:
                    session_key = self._get_session_key(
                        body,
                        session_header=request.headers.get("x-headroom-session-id"),
                    )
                    if session_key in self._active_streams:
                        from fastapi.responses import JSONResponse

                        queued = self._queue_mid_turn_message(session_key, body)
                        return JSONResponse(content=queued, status_code=202)
                    return await self._stream_response(
                        "url",
                        {},
                        body,
                        "anthropic",
                        "model",
                        "request-id",
                        0,
                        0,
                        0,
                        [],
                        {},
                        0.0,
                        session_key=session_key,
                    )
"""


def write_fake_headroom(root: Path, *, broken_anthropic: bool = False) -> tuple[Path, Path]:
    package = root / "headroom"
    handlers = package / "proxy" / "handlers"
    handlers.mkdir(parents=True)
    (package / "__init__.py").write_text("# fake headroom package\n", encoding="utf-8")
    (package / "proxy" / "__init__.py").write_text("", encoding="utf-8")
    (handlers / "__init__.py").write_text("", encoding="utf-8")
    streaming = handlers / "streaming.py"
    anthropic = handlers / "anthropic.py"
    streaming.write_text(textwrap.dedent(STREAMING_FIXTURE), encoding="utf-8")
    anthropic_text = textwrap.dedent(ANTHROPIC_FIXTURE)
    if broken_anthropic:
        anthropic_text = anthropic_text.replace(
            "                    if session_key in self._active_streams:\n",
            "                    if False:\n",
        )
    anthropic.write_text(anthropic_text, encoding="utf-8")
    return streaming, anthropic


def run_patch(root: Path) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ)
    env["PYTHONPATH"] = str(root)
    return subprocess.run(
        [sys.executable, str(PATCH)],
        cwd=Path(__file__).parent,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


def digest(*paths: Path) -> str:
    h = hashlib.sha256()
    for path in paths:
        h.update(path.read_bytes())
    return h.hexdigest()


class HeadroomClaudeCodeStreamingPatchTest(unittest.TestCase):
    @staticmethod
    def _load_streaming_module(path: Path, module_name: str) -> types.ModuleType:
        spec = importlib.util.spec_from_file_location(module_name, path)
        if spec is None or spec.loader is None:
            raise RuntimeError(f"could not load patched streaming fixture: {path}")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    @staticmethod
    async def _consume_fixture_stream(handler: Any) -> list[bytes]:
        response = await handler._stream_response(
            "url",
            {},
            {"stream": True},
            "anthropic",
            "gpt-5.6-luna",
            "request-id",
            12,
            8,
            4,
            ["fixture"],
            {"existing": "tag"},
            0.001,
            session_key="session-1",
        )
        return [chunk async for chunk in response]

    def test_patches_streaming_and_anthropic_and_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            streaming, anthropic = write_fake_headroom(root)

            first = run_patch(root)
            self.assertEqual(first.returncode, 0, first.stderr)

            streaming_text = streaming.read_text(encoding="utf-8")
            anthropic_text = anthropic.read_text(encoding="utf-8")
            self.assertIn("sub2api downstream Claude Code active-stream refcount patch", streaming_text)
            self.assertIn("sub2api downstream Claude Code overlap wait patch", streaming_text)
            self.assertIn("_active_stream_counts", streaming_text)
            self.assertIn("_wait_for_mid_turn_stream", streaming_text)
            self.assertIn("self._mark_mid_turn_stream_active(session_key)", streaming_text)
            self.assertIn("sub2api downstream Claude Code session key patch", anthropic_text)
            self.assertIn("sub2api downstream Claude Code no-202 overlap patch", anthropic_text)
            self.assertIn("sub2api downstream Claude Code handler watchdog patch", anthropic_text)
            self.assertNotIn("return JSONResponse(content=queued, status_code=202)", anthropic_text)
            self.assertNotIn("HEADROOM_ANTHROPIC_MID_TURN_WAIT_TIMEOUT_SECONDS", anthropic_text)

            after_first = digest(streaming, anthropic)
            second = run_patch(root)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(after_first, digest(streaming, anthropic))

    def test_stream_generator_reaches_message_stop_and_clean_eof(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            streaming, _ = write_fake_headroom(root)
            result = run_patch(root)
            self.assertEqual(result.returncode, 0, result.stderr)

            module = self._load_streaming_module(streaming, "patched_streaming_clean_eof")
            handler = module.StreamingHandler()
            chunks = asyncio.run(self._consume_fixture_stream(handler))

            wire = b"".join(chunks)
            self.assertIn(b"event: message_start", wire)
            self.assertIn(b"event: content_block_delta", wire)
            self.assertIn(b"event: message_stop", wire)
            self.assertEqual(handler.finalized_tags["existing"], "tag")
            self.assertEqual(handler.finalized_tags["stream_chunks_yielded"], "3")
            self.assertEqual(handler.finalized_tags["stream_terminal_event"], "true")
            self.assertNotIn("session-1", handler._active_streams)
            self.assertNotIn("session-1", handler._active_stream_counts)

    def test_telemetry_finalizer_failure_does_not_break_completed_stream(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            streaming, _ = write_fake_headroom(root)
            result = run_patch(root)
            self.assertEqual(result.returncode, 0, result.stderr)

            module = self._load_streaming_module(streaming, "patched_streaming_finalize_error")
            handler = module.StreamingHandler()
            handler.raise_in_finalizer = True

            with self.assertLogs("headroom.proxy", level="ERROR") as captured:
                chunks = asyncio.run(self._consume_fixture_stream(handler))

            self.assertIn(b"event: message_stop", b"".join(chunks))
            self.assertTrue(
                any("event=claude_code_stream_finalize_failed" in line for line in captured.output)
            )
            self.assertNotIn("session-1", handler._active_streams)
            self.assertNotIn("session-1", handler._active_stream_counts)

    def test_session_key_helper_uses_claude_session_and_agent(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _, anthropic = write_fake_headroom(root)
            result = run_patch(root)
            self.assertEqual(result.returncode, 0, result.stderr)

            spec = importlib.util.spec_from_file_location("patched_anthropic", anthropic)
            self.assertIsNotNone(spec)
            module = importlib.util.module_from_spec(spec)
            assert spec and spec.loader
            spec.loader.exec_module(module)

            class Request:
                def __init__(self, headers: dict[str, str]) -> None:
                    self.headers = headers

            helper = module._headroom_session_header_from_request
            self.assertEqual(helper(Request({"x-headroom-session-id": "explicit"})), "explicit")
            self.assertEqual(
                helper(
                    Request(
                        {
                            "x-claude-code-session-id": "session-1",
                            "x-claude-code-agent-id": "agent-2",
                        }
                    )
                ),
                "claude-code:session-1:agent-2",
            )
            self.assertEqual(
                helper(Request({"x-claude-code-session-id": "session-1"})),
                "claude-code:session-1:main",
            )
            self.assertIsNone(helper(Request({})))

    def test_handler_watchdog_retries_claude_code_request_with_bypass(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _, anthropic = write_fake_headroom(root)
            result = run_patch(root)
            self.assertEqual(result.returncode, 0, result.stderr)

            spec = importlib.util.spec_from_file_location("patched_anthropic_watchdog", anthropic)
            self.assertIsNotNone(spec)
            module = importlib.util.module_from_spec(spec)
            assert spec and spec.loader
            spec.loader.exec_module(module)

            class Handler(module.AnthropicHandlerMixin):
                _active_streams: set[str] = set()

                def _get_session_key(self, body: dict, session_header: str | None = None) -> str:
                    return session_header or "derived-session"

                async def _stream_response(self, *args, **kwargs):
                    return "ok"

            class Request:
                headers = {"x-claude-code-session-id": "session-1"}
                body = {"stream": True, "sleep_forever": True}

            async def run() -> object:
                old_timeout = os.environ.get("HEADROOM_CLAUDE_CODE_HANDLER_WATCHDOG_MS")
                os.environ["HEADROOM_CLAUDE_CODE_HANDLER_WATCHDOG_MS"] = "10"
                try:
                    return await Handler().handle_anthropic_messages(Request())
                finally:
                    if old_timeout is None:
                        os.environ.pop("HEADROOM_CLAUDE_CODE_HANDLER_WATCHDOG_MS", None)
                    else:
                        os.environ["HEADROOM_CLAUDE_CODE_HANDLER_WATCHDOG_MS"] = old_timeout

            response = asyncio.run(run())
            self.assertEqual(response, "retry-ok")

    def test_handler_watchdog_returns_sse_error_if_bypass_retry_also_times_out(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _, anthropic = write_fake_headroom(root)
            result = run_patch(root)
            self.assertEqual(result.returncode, 0, result.stderr)

            spec = importlib.util.spec_from_file_location("patched_anthropic_watchdog_retry_fail", anthropic)
            self.assertIsNotNone(spec)
            module = importlib.util.module_from_spec(spec)
            assert spec and spec.loader
            spec.loader.exec_module(module)

            class Handler(module.AnthropicHandlerMixin):
                _active_streams: set[str] = set()

                def _get_session_key(self, body: dict, session_header: str | None = None) -> str:
                    return session_header or "derived-session"

                async def _stream_response(self, *args, **kwargs):
                    return "ok"

            class Request:
                headers = {"x-claude-code-session-id": "session-1"}
                body = {
                    "stream": True,
                    "sleep_forever": True,
                    "sleep_forever_after_retry": True,
                }

            async def run() -> object:
                old_timeout = os.environ.get("HEADROOM_CLAUDE_CODE_HANDLER_WATCHDOG_MS")
                os.environ["HEADROOM_CLAUDE_CODE_HANDLER_WATCHDOG_MS"] = "10"
                try:
                    return await Handler().handle_anthropic_messages(Request())
                finally:
                    if old_timeout is None:
                        os.environ.pop("HEADROOM_CLAUDE_CODE_HANDLER_WATCHDOG_MS", None)
                    else:
                        os.environ["HEADROOM_CLAUDE_CODE_HANDLER_WATCHDOG_MS"] = old_timeout

            class FakeStreamingResponse:
                def __init__(self, _body, media_type: str, status_code: int) -> None:
                    self.body = _body
                    self.media_type = media_type
                    self.status_code = status_code

            old_fastapi_responses = sys.modules.get("fastapi.responses")
            sys.modules["fastapi.responses"] = types.SimpleNamespace(
                StreamingResponse=FakeStreamingResponse
            )
            response = asyncio.run(run())
            if old_fastapi_responses is None:
                sys.modules.pop("fastapi.responses", None)
            else:
                sys.modules["fastapi.responses"] = old_fastapi_responses
            self.assertEqual(getattr(response, "status_code", None), 504)
            self.assertEqual(getattr(response, "media_type", None), "text/event-stream")

    def test_refuses_unknown_anthropic_overlap_shape(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_fake_headroom(root, broken_anthropic=True)
            result = run_patch(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Could not find Anthropic mid-turn overlap branch", result.stderr)


if __name__ == "__main__":
    unittest.main()
