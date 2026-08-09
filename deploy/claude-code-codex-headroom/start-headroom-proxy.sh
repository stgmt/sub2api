#!/usr/bin/env sh
set -eu

seed_dir="/opt/headroom-seed"

copy_seed() {
  src="$1"
  dst="$2"
  mkdir -p "$dst"
  if [ -d "$src" ]; then
    cp -a -n "$src"/. "$dst"/ 2>/dev/null || true
  fi
}

copy_seed "$seed_dir/headroom" /root/.headroom
copy_seed "$seed_dir/cache-headroom" /root/.cache/headroom
copy_seed "$seed_dir/cache-huggingface" /root/.cache/huggingface

mkdir -p /root/.headroom/logs /root/.cache/headroom /root/.cache/huggingface

if [ "${HEADROOM_REQUIRE_CUDA:-1}" = "1" ]; then
  if ! python -c 'import sys, torch; ok = bool(torch.cuda.is_available()); print("HEADROOM_CUDA_AVAILABLE=" + str(ok)); sys.exit(0 if ok else 78)'; then
    echo "Headroom startup refused: CUDA is required but torch.cuda.is_available() is false" >&2
    exit 78
  fi
fi

exec headroom proxy "$@"
