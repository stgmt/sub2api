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

exec headroom proxy "$@"
