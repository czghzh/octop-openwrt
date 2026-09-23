#!/bin/bash
# ============================================================================
#  并行下载纯 Python wheel（py3-none-any）
# ============================================================================
#
#  纯 py 包不带平台标签，任何平台下到的都是同一个文件，
#  因此通常不需要指定 --platform（脚本仍带一次 musl 尝试，命中率更高）。
#
#  用法:
#     sh tools/fetch-pure-wheels.sh [清单文件] [输出目录]
#
#  默认:
#     清单     tools/data/pure-list.txt
#     输出     ./wheels-pure
#
#  可用环境变量:
#     PIP / PIP_INDEX / JOBS      （含义见 fetch-musl-wheels.sh）
#
#  ⚠️ 与 fetch-musl-wheels.sh 不要写同一个输出目录 —— 两批 xargs -P 并发会互相踩。
# ============================================================================
set -u

REPO_ROOT=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
LIST=${1:-"$REPO_ROOT/tools/data/pure-list.txt"}
OUT=${2:-"$PWD/wheels-pure"}

PYVER=${PYVER:-314}
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}
[ "$JOBS" -gt 8 ] && JOBS=8

if [ -n "${PIP:-}" ]; then
	PIP_CMD="$PIP"
elif command -v pip3 >/dev/null 2>&1; then
	PIP_CMD="pip3"
elif command -v pip >/dev/null 2>&1; then
	PIP_CMD="pip"
else
	PIP_CMD="python3 -m pip"
fi

INDEX_ARGS=""
if [ -n "${PIP_INDEX:-}" ]; then
	HOST=$(printf '%s' "$PIP_INDEX" | sed -E 's#^https?://([^/]+).*#\1#')
	INDEX_ARGS="-i $PIP_INDEX --trusted-host $HOST"
fi

[ -f "$LIST" ] || { echo "!! 清单文件不存在: $LIST" >&2; exit 1; }
mkdir -p "$OUT"
TMPBASE=${TMPBASE:-"${TMPDIR:-/tmp}/pure-one"}
mkdir -p "$TMPBASE"

echo "=== 并行下载纯 Python wheel ==="
echo "  清单  : $LIST ($(wc -l < "$LIST") 个包)"
echo "  输出  : $OUT"
echo "  pip   : $PIP_CMD"
echo "  并行度: $JOBS"
echo ""

dl_one() {
	spec="$1"
	name="${spec%%==*}"
	d="$TMPBASE/$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')"
	rm -rf "$d"; mkdir -p "$d"

	# 先试带 musl 平台参数（有些包虽标 pure 但会提供平台 wheel）
	if $PIP_CMD download "$spec" --no-deps -d "$d" $INDEX_ARGS \
			--platform musllinux_1_2_aarch64 --python-version "$PYVER" \
			--implementation cp --only-binary=:all: -q >/dev/null 2>&1 \
	|| $PIP_CMD download "$spec" --no-deps -d "$d" $INDEX_ARGS \
			--only-binary=:all: -q >/dev/null 2>&1; then
		whl=$(ls "$d"/*.whl 2>/dev/null | head -1)
		if [ -n "$whl" ]; then
			cp "$whl" "$OUT/"
			echo "OK       $spec"
			return 0
		fi
	fi

	echo "SDIST-ONLY  $spec  （只有源码包，需现场编译或跳过）"
	return 1
}

export -f dl_one
export PIP_CMD OUT INDEX_ARGS PYVER TMPBASE

cat "$LIST" | xargs -P"$JOBS" -I{} bash -c 'dl_one "$@"' _ {} 2>&1 | sort

echo ""
echo "=== 统计 ==="
GOT=$(ls "$OUT"/*.whl 2>/dev/null | wc -l)
TOTAL=$(wc -l < "$LIST")
echo "  成功 $GOT / $TOTAL"
du -sh "$OUT" 2>/dev/null
