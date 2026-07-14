# Headroom GPU Kompress Field Report

## Scope And Ownership

This reference records the researched and live-proven GPU path for Claude Code
through Headroom and sub2api. Deployment belongs to the
[`stgmt/sub2api`](https://github.com/stgmt/sub2api) compose profile. Headroom's
compression implementation belongs to
[`stgmt/headroom`](https://github.com/stgmt/headroom). Keep both repositories
linked when behavior spans the image and the Headroom runtime.

Related public evidence:

- sub2api implementation: [`3262db50`](https://github.com/stgmt/sub2api/commit/3262db50)
- Headroom maintenance record: [`6112ecf6`](https://github.com/stgmt/headroom/commit/6112ecf6)
- dev-pomogator integration issue: [`stgmt/dev-pomogator#111`](https://github.com/stgmt/dev-pomogator/issues/111)

## Research Findings

1. Docker GPU reservation and model execution backend are separate concerns.
   Docker Compose can reserve all available GPUs, but that only exposes devices
   to the container. It does not make a CPU runtime select CUDA automatically.
   See [Docker Compose GPU support](https://docs.docker.com/compose/how-tos/gpu-support/).
2. The previous Headroom image installed ONNX Runtime without CUDA PyTorch.
   Headroom's ONNX path selects `CPUExecutionProvider`, so host `nvidia-smi` and
   Compose `gpus: all` were insufficient.
3. Headroom already contains a native PyTorch Kompress path. It selects CUDA
   when `torch.cuda.is_available()` and batches work in `compress_batch`; no
   separate compression implementation was needed.
4. PyTorch publishes an official 2.11.0 CUDA 12.8 wheel path. The pinned image
   uses the documented `https://download.pytorch.org/whl/cu128` index. See
   [PyTorch previous versions](https://pytorch.org/get-started/previous-versions/).

## Implemented Solution

- `Dockerfile.headroom` keeps a portable final `cpu` stage and adds an opt-in
  `gpu` stage with pinned `torch==2.11.0+cu128`.
- `docker-compose.gpu.yml` selects the GPU stage, requests all Docker GPUs, and
  sets `HEADROOM_KOMPRESS_BACKEND=pytorch`.
- `.env` persists `HEADROOM_ACCELERATOR=cuda`, `HEADROOM_DOCKER_TARGET=gpu`, and
  `HEADROOM_KOMPRESS_BACKEND=pytorch` so the single scheduled-task owner
  reapplies the same profile after reboot.
- `setup-sub2api-claude-code.ps1` auto-detects NVIDIA under WSL or Windows but
  accepts an explicit CPU override.
- `verify-claude-code-sub2api.ps1` requires Docker DeviceRequests, Torch CUDA,
  the expected device name, and a PyTorch Kompress preload before claiming GPU.
- `benchmark-headroom-kompress.py` uses a deterministic payload and reports
  throughput, compression ratio, sentinel retention, output hash, and CUDA
  memory. Always compare identical payloads and quality checks.
- `watch-claude-proxy-stack.ps1 -RequireCuda` is a one-shot or bounded manual
  diagnostic. It is not a second autostart owner.

## Reproducible Benchmark

Hardware: NVIDIA GeForce RTX 4070 SUPER. Fixture: 8 inputs x 1,400 words,
11,200 input tokens, batch size 16, three measured repeats after warmup.

| Path | Median | Input tokens/s | Output tokens | Sentinels |
| --- | ---: | ---: | ---: | ---: |
| CPU ONNX | 24.1358 s | 464.04 | 2,408 | 664/664 |
| CUDA PyTorch | 0.5202 s | 21,530.32 | 2,408 | 664/664 |

The controlled fixture was 46.4x faster. A later live CUDA rerun produced
0.5818 s median and 19,251.68 input tokens/s. Do not generalize this multiplier
to another GPU, payload shape, batch size, model cache state, or Headroom ref
without rerunning the same benchmark.

## Live Runtime Proof

The verified container reported:

- healthy Headroom 0.31.0 with upstream `http://sub2api:8080`
- non-empty Docker GPU DeviceRequests
- `torch.cuda.is_available() == true`
- device `NVIDIA GeForce RTX 4070 SUPER`
- Torch `2.11.0+cu128`, CUDA `12.8`, Kompress backend `pytorch`
- 21,358 input tokens reduced to 7,202, with 740.77 ms optimization latency
- compression executor queue 0, in-flight 0, leaked threads 0

The lifetime Headroom ledger at verification time recorded 394,909,410 tokens
saved from 968,723,422 input tokens, or 40.8%. Treat ledger totals as a runtime
snapshot, not a permanent performance promise.

## Autostart Failure And Fix

A real Windows Scheduled Task invocation failed after `docker info` succeeded.
The next WSL command returned UTF-16/NUL text containing
`Wsl/Service/0x8007274c`. The old classifier retried only VHDX attach-lock
errors, so it exited immediately.

The canonical start script now strips embedded NULs and retries transient WSL
service/connection errors on every WSL command within `WslRetrySeconds`. A real
post-fix task invocation completed with `LastTaskResult=0`; Headroom remained
healthy and retained GPU DeviceRequests and CUDA visibility.

The manual watchdog also needs an explicit WSL distro. A bare `wsl.exe --
docker` may target a different default distro. Native stderr is diagnostic, not
the success signal: model-load warnings can be emitted while the CUDA probe
still exits zero. Capture stderr, check the native exit code, then require the
`CUDA_OK ... pytorch` marker.

## Verification Commands

```powershell
python -m pytest deploy\claude-code-codex-headroom\test_fork_owned_compose_profile.py -q
wsl.exe -d Ubuntu-24.04 -- docker inspect headroom-sub2api --format "{{json .HostConfig.DeviceRequests}}"
wsl.exe -d Ubuntu-24.04 -- docker exec headroom-sub2api python -c "import torch; from headroom.transforms.kompress_compressor import KompressCompressor; print(torch.cuda.is_available(), torch.cuda.get_device_name(0), KompressCompressor().preload(allow_download=False))"
wsl.exe -d Ubuntu-24.04 -- docker exec headroom-sub2api benchmark-headroom-kompress --require-cuda
powershell -NoProfile -ExecutionPolicy Bypass -File backend\docs\skills\sub2api-claude-code-codex\scripts\watch-claude-proxy-stack.ps1 -RequireCuda
```

## Persistence And Recovery Invariants

- Keep one autostart owner: `Sub2API Codex Proxy Stack Autostart`.
- Keep Headroom, model caches, sub2api, Postgres, and Redis on host bind mounts.
- Never recreate secrets or OAuth state merely to change accelerator profile.
- A source commit is not runtime proof. Recreate the affected Headroom service,
  inspect DeviceRequests, and run the live preload after every image/ref change.
- CPU must remain a supported explicit fallback for machines without NVIDIA.

## Known Remaining Work

GPU removes the dominant Kompress compute bottleneck but does not solve every
large-context failure:

- partial-result compression should preserve completed blocks at a deadline
- per-session singleflight should coalesce duplicate concurrent compression
- oversized unsafe fail-open requests need a strict upper bound and an internal
  stronger-compression retry instead of forwarding an upstream-invalid payload
- model/backend load and first-request warmup remain distinct from steady-state
  throughput

Do not close these architecture items based only on the GPU benchmark.
