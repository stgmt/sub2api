#!/usr/bin/env python3
"""Run a deterministic Kompress CPU/GPU throughput and retention benchmark."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import statistics
import time

from headroom.transforms import kompress_compressor as kompress


def build_inputs(items: int, words_per_item: int) -> tuple[list[str], list[str]]:
    inputs: list[str] = []
    sentinels: list[str] = []
    for item in range(items):
        words: list[str] = []
        index = 0
        while len(words) < words_per_item:
            sentinel = f"REQ_{item:02d}_{index:04d}"
            sentinels.append(sentinel)
            words.extend(
                (
                    "Runtime",
                    "verification",
                    "must",
                    "preserve",
                    sentinel,
                    f"/srv/workflows/{item}/step-{index}.json",
                    "after",
                    "compression",
                    "while",
                    "removing",
                    "repeated",
                    "diagnostic",
                    "prose",
                    "and",
                    "redundant",
                    "status",
                    "explanations.",
                )
            )
            index += 1
        inputs.append(" ".join(words[:words_per_item]))
    return inputs, sentinels


def synchronize_cuda() -> None:
    try:
        import torch

        if torch.cuda.is_available():
            torch.cuda.synchronize()
    except ImportError:
        return


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--items", type=int, default=8)
    parser.add_argument("--words-per-item", type=int, default=1400)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--target-ratio", type=float, default=0.30)
    parser.add_argument("--require-cuda", action="store_true")
    args = parser.parse_args()

    inputs, sentinels = build_inputs(args.items, args.words_per_item)
    compressor = kompress.KompressCompressor()
    load_started = time.perf_counter()
    backend = compressor.preload(allow_download=False)
    load_seconds = time.perf_counter() - load_started

    model, _, _ = kompress._kompress_cache[compressor.config.model_id]
    device = kompress._model_device_type(model, backend)
    if args.require_cuda and device != "cuda":
        raise SystemExit(f"CUDA_REQUIRED backend={backend} device={device}")

    # Warm the selected graph and allocator before measured runs.
    compressor.compress_batch(
        inputs,
        target_ratio=args.target_ratio,
        batch_size=args.batch_size,
    )

    elapsed: list[float] = []
    results = []
    for _ in range(args.repeats):
        synchronize_cuda()
        started = time.perf_counter()
        results = compressor.compress_batch(
            inputs,
            target_ratio=args.target_ratio,
            batch_size=args.batch_size,
        )
        synchronize_cuda()
        elapsed.append(time.perf_counter() - started)

    median_seconds = statistics.median(elapsed)
    original_tokens = sum(result.original_tokens for result in results)
    compressed_tokens = sum(result.compressed_tokens for result in results)
    combined = "\n".join(result.compressed for result in results)
    retained = sum(sentinel in combined for sentinel in sentinels)
    cuda_memory = None
    try:
        import torch

        if torch.cuda.is_available():
            cuda_memory = torch.cuda.max_memory_allocated()
    except ImportError:
        pass

    print(
        json.dumps(
            {
                "backend": backend,
                "device": device,
                "backend_env": os.environ.get("HEADROOM_KOMPRESS_BACKEND", "auto"),
                "items": args.items,
                "words_per_item": args.words_per_item,
                "batch_size": args.batch_size,
                "repeats": args.repeats,
                "load_seconds": round(load_seconds, 4),
                "elapsed_seconds": [round(value, 4) for value in elapsed],
                "median_seconds": round(median_seconds, 4),
                "input_tokens": original_tokens,
                "compressed_tokens": compressed_tokens,
                "compression_ratio": round(compressed_tokens / max(1, original_tokens), 4),
                "input_tokens_per_second": round(original_tokens / median_seconds, 2),
                "sentinels_total": len(sentinels),
                "sentinels_retained": retained,
                "sentinel_retention": round(retained / max(1, len(sentinels)), 4),
                "output_sha256": hashlib.sha256(combined.encode("utf-8")).hexdigest(),
                "cuda_max_memory_bytes": cuda_memory,
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
