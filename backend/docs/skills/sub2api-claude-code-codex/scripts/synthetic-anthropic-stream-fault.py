#!/usr/bin/env python3
"""Deterministic Anthropic SSE upstream for Claude stream-recovery proofs."""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def _event(event: str, payload: dict) -> bytes:
    return f"event: {event}\ndata: {json.dumps(payload, separators=(',', ':'))}\n\n".encode()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    _lock = threading.Lock()
    _request_count = 0

    def _json(self, payload: dict) -> None:
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        with self._lock:
            count = type(self)._request_count
        self._json({"ok": True, "requests": count})

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("content-length", "0"))
        body = self.rfile.read(length)
        with self._lock:
            type(self)._request_count += 1
            request_index = type(self)._request_count

        try:
            model = json.loads(body).get("model", "proof-model")
        except (json.JSONDecodeError, AttributeError):
            model = "proof-model"
        print(
            json.dumps(
                {
                    "event": "synthetic_request",
                    "request_index": request_index,
                    "model": model,
                    "body_bytes": len(body),
                },
                separators=(",", ":"),
            ),
            flush=True,
        )

        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.end_headers()

        message_id = f"msg_recovery_proof_{request_index}"
        frames = [
            _event(
                "message_start",
                {
                    "type": "message_start",
                    "message": {
                        "id": message_id,
                        "type": "message",
                        "role": "assistant",
                        "model": model,
                        "content": [],
                        "stop_reason": None,
                        "stop_sequence": None,
                        "usage": {"input_tokens": 10, "output_tokens": 1},
                    },
                },
            ),
            _event(
                "content_block_start",
                {
                    "type": "content_block_start",
                    "index": 0,
                    "content_block": {"type": "text", "text": ""},
                },
            ),
            _event(
                "content_block_delta",
                {
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": {
                        "type": "text_delta",
                        "text": "FIRST_PART" if request_index == 1 else "SECOND_PASS",
                    },
                },
            ),
        ]
        if request_index > 1:
            frames.extend(
                [
                    _event("content_block_stop", {"type": "content_block_stop", "index": 0}),
                    _event(
                        "message_delta",
                        {
                            "type": "message_delta",
                            "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                            "usage": {"output_tokens": 2},
                        },
                    ),
                    _event("message_stop", {"type": "message_stop"}),
                ]
            )

        for frame in frames:
            self.wfile.write(frame)
            self.wfile.flush()
        self.close_connection = True

    def log_message(self, _format: str, *_args) -> None:
        return


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 19090), Handler).serve_forever()
