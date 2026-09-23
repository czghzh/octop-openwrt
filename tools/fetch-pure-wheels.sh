#!/bin/bash
# 1) 宿主机批量下载 157 个纯 Python 包
# 2) 分析 4 个只有 sdist 的包（evdev/crcmod/oss2/esdk-obs-python）
set -u
PIP=/home/wen/.workbuddy/binaries/python/envs/default/bin/pip
OUT=/home/wen/octop-cross/wheels-pure
TSV=/home/wen/octop-cross/pkgs.tsv
IDX="-i https://mirrors.cloud.tencent.com/pypi/simple --trusted-host mirrors.cloud.tencent.com"

mkdir -p "$OUT"
rm -f "$OUT"/*.whl 2>/dev/null

echo "=== 并行下载纯 Python 包（单包单进程，8 路）==="
awk -F"\t" '$3=="pure" {print $1"=="$2}' "$TSV" > /tmp/pure-list.txt
echo "数量: $(wc -l < /tmp/pure-list.txt)"

dl() {
  spec="$1"
  d="/tmp/pure-one/$(echo "${spec%%==*}" | tr -c 'A-Za-z0-9._-' '_')"
  rm -rf "$d"; mkdir -p "$d"
  if $PIP download "$spec" --no-deps -d "$d" $IDX \
      --platform musllinux_1_2_aarch64 --python-version 314 --implementation cp \
      --only-binary=:all: -q >/dev/null 2>&1 \
   || $PIP download "$spec" --no-deps -d "$d" $IDX --only-binary=:all: -q >/dev/null 2>&1; then
    whl=$(ls "$d"/*.whl 2>/dev/null | head -1)
    [ -n "$whl" ] && { cp "$whl" "$OUT/"; echo "OK  $spec"; return 0; }
  fi
  echo "MISS $spec"
  return 1
}
export -f dl; export PIP OUT IDX
cat /tmp/pure-list.txt | xargs -P8 -I{} bash -c 'dl "$@"' _ {}

echo ""
echo "纯 Python wheel: $(ls "$OUT"/*.whl 2>/dev/null | wc -l) / $(wc -l < /tmp/pure-list.txt)"
du -sh "$OUT" 2>/dev/null

echo ""
echo "=========================================="
echo "=== 分析 4 个只有 sdist 的包 ==="
echo "=========================================="
for spec in evdev==2.0.0 crcmod==1.7 oss2==2.19.1 esdk-obs-python==3.26.6; do
  echo ""
  echo "### $spec"
  d="/tmp/sdist-$(echo "${spec%%==*}" | tr -c 'A-Za-z0-9._-' '_')"
  rm -rf "$d"; mkdir -p "$d"
  $PIP download "$spec" --no-deps -d "$d" $IDX -q 2>&1 | tail -2
  ls "$d"
done
