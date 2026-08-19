"""Patch headroom-ai 0.31.0 Claude Code streaming overlap handling.

The upstream wheel returns HTTP 202 ``{"event":"headroom_queued"}`` when a
second streaming Anthropic request arrives while the same internal session key
is still active. Claude Code does not implement that private queue protocol; it
expects Anthropic SSE events for every ``stream:true`` /v1/messages response and
reports "Stream ended without receiving any events" when Headroom returns 202.

This downstream image patch makes the path Claude Code-safe:

* derive the stream key from ``x-claude-code-session-id`` plus
  ``x-claude-code-agent-id`` when no explicit ``x-headroom-session-id`` exists;
* wait for the active stream to close instead of returning the private 202
  queue response;
* keep a small active-stream reference count so an emergency overlap forward
  cannot let an older stream cleanup clear a newer stream's active marker;
* bound the whole Claude Code Anthropic handler so a pre-upstream Headroom
  deadlock/cancellation cannot leave Claude Code waiting for an empty stream.
"""

from __future__ import annotations

from pathlib import Path
import py_compile

import headroom


STREAMING_ACTIVE_COUNT_SENTINEL = (
    "# sub2api downstream Claude Code active-stream refcount patch"
)
STREAMING_WAIT_SENTINEL = "# sub2api downstream Claude Code overlap wait patch"
ANTHROPIC_SESSION_SENTINEL = "# sub2api downstream Claude Code session key patch"
ANTHROPIC_NO_202_SENTINEL = "# sub2api downstream Claude Code no-202 overlap patch"
ANTHROPIC_HANDLER_WATCHDOG_SENTINEL = (
    "# sub2api downstream Claude Code handler watchdog patch"
)
STREAMING_TRACE_SENTINEL = "# sub2api downstream Claude Code stream trace patch"


def _replace_once(text: str, old: str, new: str, path: Path) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"expected exactly one match in {path}: {old!r}, got {count}")
    return text.replace(old, new, 1)


def patch_streaming(base: Path) -> None:
    path = base / "proxy" / "handlers" / "streaming.py"
    text = path.read_text(encoding="utf-8")

    if STREAMING_ACTIVE_COUNT_SENTINEL not in text:
        text = _replace_once(
            text,
            "    _mid_turn_queues: dict[str, asyncio.Queue] = {}\n"
            "    _active_streams: set[str] = set()\n",
            "    _mid_turn_queues: dict[str, asyncio.Queue] = {}\n"
            "    _active_streams: set[str] = set()\n"
            f"    {STREAMING_ACTIVE_COUNT_SENTINEL}\n"
            "    _active_stream_counts: dict[str, int] = {}\n",
            path,
        )

    if STREAMING_WAIT_SENTINEL not in text:
        text = _replace_once(
            text,
            "    def _cleanup_mid_turn_stream(\n",
            f"""    {STREAMING_WAIT_SENTINEL}
    def _mark_mid_turn_stream_active(self, session_key: str) -> None:
        self._active_stream_counts[session_key] = (
            self._active_stream_counts.get(session_key, 0) + 1
        )
        self._active_streams.add(session_key)

    async def _wait_for_mid_turn_stream(self, session_key: str, request_id: str) -> float:
        import os

        raw_wait_ms = os.environ.get("HEADROOM_MID_TURN_STREAM_WAIT_MS", "600000")
        try:
            wait_ms = max(0, int(raw_wait_ms))
        except (TypeError, ValueError):
            wait_ms = 600000
        if wait_ms <= 0:
            return 0.0

        start = time.monotonic()
        deadline = start + (wait_ms / 1000.0)
        logged = False
        while session_key in self._active_streams and time.monotonic() < deadline:
            if not logged:
                logger.warning(
                    "event=mid_turn_overlap_wait request_id=%s session_key=%s wait_ms=%s",
                    request_id,
                    session_key,
                    wait_ms,
                )
                logged = True
            await asyncio.sleep(0.05)

        waited_ms = (time.monotonic() - start) * 1000.0
        if logged:
            logger.warning(
                "event=mid_turn_overlap_wait_done request_id=%s session_key=%s "
                "waited_ms=%.2f still_active=%s",
                request_id,
                session_key,
                waited_ms,
                session_key in self._active_streams,
            )
        return waited_ms

    def _cleanup_mid_turn_stream(
""",
            path,
        )

    if "count = self._active_stream_counts.get(session_key, 0)" not in text:
        text = _replace_once(
            text,
            "        self._active_streams.discard(session_key)\n"
            "        queue = self._mid_turn_queues.pop(session_key, None)\n",
            "        count = self._active_stream_counts.get(session_key, 0)\n"
            "        if count > 1:\n"
            "            self._active_stream_counts[session_key] = count - 1\n"
            "            return []\n"
            "        self._active_stream_counts.pop(session_key, None)\n"
            "        self._active_streams.discard(session_key)\n"
            "        queue = self._mid_turn_queues.pop(session_key, None)\n",
            path,
        )

    if "self._mark_mid_turn_stream_active(session_key)" not in text:
        text = _replace_once(
            text,
            "        self._active_streams.add(session_key)\n\n"
            "        # Guard everything up to the generator's own try/finally",
            "        self._mark_mid_turn_stream_active(session_key)\n\n"
            "        # Guard everything up to the generator's own try/finally",
            path,
        )

    if STREAMING_TRACE_SENTINEL not in text:
        text = _replace_once(
            text,
            '        outbound_headers = {**headers, "content-type": "application/json"}\n',
            '        outbound_headers = {**headers, "content-type": "application/json"}\n'
            f'        {STREAMING_TRACE_SENTINEL}\n'
            '        # Carry one stable id through Headroom -> sub2api -> request logs.\n'
            '        outbound_headers.setdefault("x-request-id", request_id)\n'
            '        outbound_headers["x-headroom-request-id"] = request_id\n',
            path,
        )

        forwarded_start = text.find("        forwarded_headers =")
        if forwarded_start < 0:
            raise RuntimeError(f"could not locate streaming forwarded_headers block in {path}")
        forwarded_line_end = text.find("\n", forwarded_start)
        generate_pos = text.find("        async def generate():\n", forwarded_line_end)
        if generate_pos < 0:
            raise RuntimeError(f"could not locate _stream_response_inner generator in {path}")
        text = text[:generate_pos] + (
            '        forwarded_headers["x-headroom-request-id"] = request_id\n'
            '        forwarded_headers.setdefault("x-request-id", request_id)\n\n'
        ) + text[generate_pos:]

        text = _replace_once(
            text,
            '            "ttfb_ms": None,  # Time to first byte from upstream\n',
            '            "ttfb_ms": None,  # Time to first byte from upstream\n'
            '            "chunks_yielded": 0,\n'
            '            "terminal_event_seen": False,\n'
            '            "stream_error": None,\n',
            path,
        )

        yield_positions = [
            index for index in range(len(text)) if text.startswith("yield chunk\n", index)
        ]
        if len(yield_positions) != 1:
            raise RuntimeError(
                f"expected exactly one streaming yield in {path}, got {len(yield_positions)}"
            )
        yield_pos = yield_positions[0]
        line_start = text.rfind("\n", 0, yield_pos) + 1
        indent = text[line_start:yield_pos]
        text = text[:line_start] + (
            indent + 'stream_state["chunks_yielded"] += 1\n'
            + indent + 'if b"message_stop" in chunk:\n'
            + indent + '    stream_state["terminal_event_seen"] = True\n'
            + indent + "# After the first yielded byte, never replay the request.\n"
            + indent + "# A tool_use may already be visible to Claude Code.\n"
            + indent + "yield chunk\n"
        ) + text[yield_pos + len("yield chunk\n") :]

        text = _replace_once(
            text,
            '            except (httpx.ConnectError, httpx.ConnectTimeout, httpx.PoolTimeout) as e:\n',
            '            except asyncio.CancelledError:\n'
            '                stream_state["stream_error"] = "client_disconnect_or_cancel"\n'
            '                logger.warning(\n'
            '                    "event=claude_code_stream_cancelled request_id=%s "\n'
            '                    "chunks_yielded=%s bytes=%s output_started=%s",\n'
            '                    request_id,\n'
            '                    stream_state["chunks_yielded"],\n'
            '                    stream_state["total_bytes"],\n'
            '                    stream_state["chunks_yielded"] > 0,\n'
            '                )\n'
            '                raise\n'
            '            except (httpx.ConnectError, httpx.ConnectTimeout, httpx.PoolTimeout) as e:\n',
            path,
        )

        text = _replace_once(
            text,
            '                logger.error(f"[{request_id}] Connection error to upstream API: {e}")\n',
            '                stream_state["stream_error"] = "upstream_connection_error"\n'
            '                logger.error(f"[{request_id}] Connection error to upstream API: {e}")\n',
            path,
        )

        text = _replace_once(
            text,
            '                logger.error(f"[{request_id}] HTTP error from upstream API: {e}")\n',
            '                stream_state["stream_error"] = "upstream_http_error"\n'
            '                logger.error(f"[{request_id}] HTTP error from upstream API: {e}")\n',
            path,
        )

        text = _replace_once(
            text,
            '                logger.error(f"[{request_id}] Unexpected streaming error: {e}")\n',
            '                stream_state["stream_error"] = type(e).__name__\n'
            '                logger.error(f"[{request_id}] Unexpected streaming error: {e}")\n',
            path,
        )

        text = _replace_once(
            text,
            '                pending_messages = self._cleanup_mid_turn_stream(\n',
            '                try:\n'
            '                    final_tags = dict(tags or {})\n'
            '                    final_tags.update(\n'
            '                        {\n'
            '                            "stream_chunks_yielded": str(stream_state["chunks_yielded"]),\n'
            '                            "stream_bytes_yielded": str(stream_state["total_bytes"]),\n'
            '                            "stream_output_started": str(stream_state["chunks_yielded"] > 0).lower(),\n'
            '                            "stream_terminal_event": str(stream_state["terminal_event_seen"]).lower(),\n'
            '                            "stream_error": str(stream_state["stream_error"] or ""),\n'
            '                            "stream_completed_normally": str(completed_normally).lower(),\n'
            '                        }\n'
            '                    )\n'
            '                    logger.info(\n'
            '                        "event=claude_code_stream_finalized request_id=%s "\n'
            '                        "chunks_yielded=%s bytes=%s output_started=%s terminal_event=%s "\n'
            '                        "completed_normally=%s error=%s",\n'
            '                        request_id,\n'
            '                        stream_state["chunks_yielded"],\n'
            '                        stream_state["total_bytes"],\n'
            '                        stream_state["chunks_yielded"] > 0,\n'
            '                        stream_state["terminal_event_seen"],\n'
            '                        completed_normally,\n'
            '                        stream_state["stream_error"] or "",\n'
            '                    )\n'
            '                except Exception as trace_error:\n'
            '                    final_tags = {}\n'
            '                    logger.exception(\n'
            '                        "event=claude_code_stream_trace_failed request_id=%s "\n'
            '                        "error_type=%s",\n'
            '                        request_id,\n'
            '                        type(trace_error).__name__,\n'
            '                    )\n'
            '                pending_messages = self._cleanup_mid_turn_stream(\n',
            path,
        )

        finalize_start = text.find(
            '                await self._finalize_stream_response(\n',
            generate_pos,
        )
        if finalize_start < 0:
            raise RuntimeError(f"could not locate generator stream finalizer in {path}")
        finalize_end = text.find('                )\n', finalize_start)
        if finalize_end < 0:
            raise RuntimeError(f"could not locate generator stream finalizer end in {path}")
        finalize_end += len('                )\n')
        finalize_block = text[finalize_start:finalize_end]
        if finalize_block.count('                    tags=tags,\n') != 1:
            raise RuntimeError(f"could not locate unique generator finalizer tags in {path}")
        finalize_block = finalize_block.replace(
            '                    tags=tags,\n',
            '                    tags=final_tags,\n',
            1,
        )
        indented_finalize_block = "".join(
            f"    {line}" if line.strip() else line
            for line in finalize_block.splitlines(keepends=True)
        )
        text = (
            text[:finalize_start]
            + '                try:\n'
            + indented_finalize_block
            + '                except Exception as finalize_error:\n'
            + '                    logger.exception(\n'
            + '                        "event=claude_code_stream_finalize_failed request_id=%s "\n'
            + '                        "error_type=%s output_started=%s terminal_event=%s",\n'
            + '                        request_id,\n'
            + '                        type(finalize_error).__name__,\n'
            + '                        stream_state["chunks_yielded"] > 0,\n'
            + '                        stream_state["terminal_event_seen"],\n'
            + '                    )\n'
            + text[finalize_end:]
        )

    path.write_text(text, encoding="utf-8")
    py_compile.compile(str(path), doraise=True)


def patch_anthropic(base: Path) -> None:
    path = base / "proxy" / "handlers" / "anthropic.py"
    text = path.read_text(encoding="utf-8")

    if ANTHROPIC_SESSION_SENTINEL not in text:
        text = _replace_once(
            text,
            'logger = logging.getLogger("headroom.proxy")\n\n\n',
            f'''logger = logging.getLogger("headroom.proxy")


{ANTHROPIC_SESSION_SENTINEL}
def _headroom_session_header_from_request(request: Any) -> str | None:
    explicit = request.headers.get("x-headroom-session-id")
    if explicit:
        return explicit

    claude_session = request.headers.get("x-claude-code-session-id")
    if not claude_session:
        return None

    claude_agent = request.headers.get("x-claude-code-agent-id") or "main"
    return f"claude-code:{{claude_session}}:{{claude_agent}}"


''',
            path,
        )

    session_header_old = (
        '                        session_header=request.headers.get("x-headroom-session-id"),\n'
    )
    if session_header_old in text:
        text = text.replace(
            session_header_old,
            "                        session_header=_headroom_session_header_from_request(request),\n",
            1,
        )

    old = """                    session_key = self._get_session_key(
                        body,
                        session_header=_headroom_session_header_from_request(request),
                    )
                    if session_key in self._active_streams:
                        from fastapi.responses import JSONResponse

                        queued = self._queue_mid_turn_message(session_key, body)
                        return JSONResponse(content=queued, status_code=202)
                    return await self._stream_response(
"""
    new_if_branch = f"""                    if session_key in self._active_streams:
                        {ANTHROPIC_NO_202_SENTINEL}
                        waited_ms = await self._wait_for_mid_turn_stream(
                            session_key,
                            request_id,
                        )
                        if session_key in self._active_streams:
                            logger.warning(
                                "event=mid_turn_overlap_timeout request_id=%s "
                                "session_key=%s waited_ms=%.2f action=forward_anyway",
                                request_id,
                                session_key,
                                waited_ms,
                            )
"""
    if ANTHROPIC_NO_202_SENTINEL not in text:
        if old in text:
            text = text.replace(old, old.split("                    if session_key", 1)[0] + new_if_branch + "                    return await self._stream_response(\n", 1)
        else:
            session_marker = "                    session_key = self._get_session_key(\n"
            return_marker = "                    return await self._stream_response(\n"
            session_pos = text.find(session_marker)
            return_pos = text.find(return_marker, session_pos)
            branch_marker = "                    if session_key in self._active_streams:\n"
            branch_pos = text.find(branch_marker, session_pos, return_pos)
            if session_pos < 0 or return_pos < 0 or branch_pos < 0:
                raise RuntimeError(f"Could not find Anthropic mid-turn overlap branch in {path}")
            text = text[:branch_pos] + new_if_branch + text[return_pos:]

    if "return JSONResponse(content=queued, status_code=202)" in text:
        raise RuntimeError(f"unsafe 202 queue response still present in {path}")

    if ANTHROPIC_HANDLER_WATCHDOG_SENTINEL not in text:
        text += f'''


{ANTHROPIC_HANDLER_WATCHDOG_SENTINEL}
_sub2api_original_handle_anthropic_messages = (
    AnthropicHandlerMixin.handle_anthropic_messages
)


async def _sub2api_handle_anthropic_messages_with_watchdog(
    self,
    request,
    upstream_base_url=None,
    provider_name="anthropic",
    model_override=None,
    force_stream=False,
):
    import asyncio as _sub2api_asyncio
    import json as _sub2api_json
    import os as _sub2api_os

    claude_session = request.headers.get("x-claude-code-session-id")
    if not claude_session:
        return await _sub2api_original_handle_anthropic_messages(
            self,
            request,
            upstream_base_url=upstream_base_url,
            provider_name=provider_name,
            model_override=model_override,
            force_stream=force_stream,
        )

    raw_timeout_ms = _sub2api_os.environ.get(
        "HEADROOM_CLAUDE_CODE_HANDLER_WATCHDOG_MS",
        "60000",
    )
    try:
        timeout_ms = max(1000, int(raw_timeout_ms))
    except (TypeError, ValueError):
        timeout_ms = 60000

    claude_agent = request.headers.get("x-claude-code-agent-id") or "main"

    class _Sub2apiWatchdogRetryRequest:
        def __init__(self, original_request, retry_headers):
            self._original_request = original_request
            self.headers = retry_headers

        def __getattr__(self, name):
            return getattr(self._original_request, name)

    def _consume_late_task_result(task):
        try:
            task.result()
        except _sub2api_asyncio.CancelledError:
            pass
        except Exception as exc:
            logger.warning(
                "event=claude_code_handler_watchdog_late_task_error "
                "session_id=%s agent_id=%s error=%r",
                claude_session,
                claude_agent,
                exc,
            )

    async def _run_original(current_request):
        return await _sub2api_original_handle_anthropic_messages(
            self,
            current_request,
            upstream_base_url=upstream_base_url,
            provider_name=provider_name,
            model_override=model_override,
            force_stream=force_stream,
        )

    async def _run_with_watchdog(current_request, attempt):
        task = _sub2api_asyncio.create_task(_run_original(current_request))
        done, _ = await _sub2api_asyncio.wait(
            {{task}},
            timeout=timeout_ms / 1000.0,
        )
        if task in done:
            return False, await task

        task.cancel()
        task.add_done_callback(_consume_late_task_result)
        logger.error(
            "event=claude_code_handler_watchdog_timeout "
            "session_id=%s agent_id=%s timeout_ms=%s attempt=%s",
            claude_session,
            claude_agent,
            timeout_ms,
            attempt,
        )
        return True, None

    timed_out, response = await _run_with_watchdog(request, "primary")
    if not timed_out:
        return response

    retry_headers = dict(request.headers.items())
    retry_headers["x-headroom-bypass"] = "true"
    retry_headers["x-headroom-mode"] = "passthrough"
    retry_headers["x-sub2api-headroom-watchdog-retry"] = "1"
    retry_request = _Sub2apiWatchdogRetryRequest(request, retry_headers)
    logger.warning(
        "event=claude_code_handler_watchdog_retry "
        "session_id=%s agent_id=%s mode=bypass",
        claude_session,
        claude_agent,
    )

    retry_timed_out, retry_response = await _run_with_watchdog(
        retry_request,
        "bypass",
    )
    if not retry_timed_out:
        logger.warning(
            "event=claude_code_handler_watchdog_retry_ok "
            "session_id=%s agent_id=%s",
            claude_session,
            claude_agent,
        )
        return retry_response

    from fastapi.responses import StreamingResponse

    logger.error(
        "event=claude_code_handler_watchdog_retry_timeout "
        "session_id=%s agent_id=%s timeout_ms=%s",
        claude_session,
        claude_agent,
        timeout_ms,
    )

    async def _timeout_sse():
        error_event = {{
            "type": "error",
            "error": {{
                "type": "api_error",
                "message": (
                    "Headroom timed out before producing an Anthropic stream "
                    "event. A local bypass retry was attempted and also timed "
                    "out."
                ),
            }},
        }}
        yield (
            "event: error\\n"
            f"data: {{_sub2api_json.dumps(error_event)}}\\n\\n"
        ).encode()

    return StreamingResponse(
        _timeout_sse(),
        media_type="text/event-stream",
        status_code=504,
    )


AnthropicHandlerMixin.handle_anthropic_messages = (
    _sub2api_handle_anthropic_messages_with_watchdog
)
'''

    path.write_text(text, encoding="utf-8")
    py_compile.compile(str(path), doraise=True)


def main() -> None:
    base = Path(headroom.__file__).resolve().parent
    patch_streaming(base)
    patch_anthropic(base)
    print("patched Claude Code streaming overlap handling")


if __name__ == "__main__":
    main()
