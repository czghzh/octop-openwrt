#!/bin/bash
# 在宿主机上「并行」为 40 个包取 musllinux-aarch64/cp314 wheel
# 用 xargs -P8 跑满 8 核 —— 每个包一个独立 pip download 进程，天然可并行
set -u

PIP=/home/wen/.workbuddy/binaries/python/envs/default/bin/pip
OUT=/home/wen/octop-cross/wheels-musl
NEEDS=/home/wen/octop-cross/needs-musl.txt
mkdir -p "$OUT"
rm -f "$OUT"/*.whl 2>/dev/null

IDX="-i https://mirrors.cloud.tencent.com/pypi/simple --trusted-host mirrors.cloud.tencent.com"

# 每个包单独 download，--no-deps 避免任何解析/回溯
dl_one() {
  spec="$1"
  name="${spec%%==*}"
  d="/tmp/musl-one/$(echo "$name" | tr -c 'A-Za-z0-9._-' '_')"
  rm -rf "$d"; mkdir -p "$d"
  if $PIP download "$spec" --no-deps -d "$d" $IDX \
      --platform musllinux_1_2_aarch64 \
      --platform musllinux_1_1_aarch64 \
      --platform musllinux_1_0_aarch64 \
      --python-version 314 --implementation cp \
      --only-binary=:all: -q >/dev/null 2>&1; then
    whl=$(ls "$d"/*.whl 2>/dev/null | head -1)
    if [ -n "$whl" ]; then
      cp "$whl" "$OUT/"
      echo "OK      $spec"
      return 0
    fi
  fi
  # 回退：不限平台，看有没有纯 py 的任意 wheel
  rm -rf "$d"; mkdir -p "$d"
  if $PIP download "$spec" --no-deps -d "$d" $IDX --only-binary=:all: -q >/dev/null 2>&1; then
    whl=$(ls "$d"/*.whl 2>/dev/null | head -1)
    if [ -n "$whl" ]; then
      echo "PURE?   $spec  ($(basename "$whl"))"
      return 0
    fi
  fi
  echo "MISSING $spec"
  return 1
}
export -f dl_one
export PIP OUT IDX

echo "=== 并行取 musl wheel（8 路）==="
cat "$NEEDS" | xargs -P8 -I{} bash -c 'dl_one "$@"' _ {} 2>&1 | sort

echo ""
echo "=== 统计 ==="
echo "取到的 wheel: $(ls "$OUT"/*.whl 2>/dev/null | wc -l) / 40"
du -sh "$OUT"
