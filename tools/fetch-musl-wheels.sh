#!/bin/bash
# ============================================================================
#  并行下载 musl-aarch64 平台的 wheel
# ============================================================================
#
#  用 `xargs -P<n>` 跑满 CPU 核数 —— 每个包一个独立的 pip download 进程，
#  天然可并行（pip 自己的依赖求解是单线程的，但 --no-deps 下没有求解）。
#
#  用法:
#     sh tools/fetch-musl-wheels.sh [清单文件] [输出目录]
#
#  默认:
#     清单     tools/data/needs-musl.txt
#     输出     ./wheels-musl
#
#  可用环境变量:
#     PIP          pip 可执行文件（默认自动探测 pip3 / python3 -m pip）
#     PYVER        Python 版本号无点形式（默认 314，即 3.14）
#     PIP_INDEX    自定义 PyPI 镜像，如 https://mirrors.cloud.tencent.com/pypi/simple
#     JOBS         并行度（默认 CPU 核数，最多 8）
#
#  例:
#     PIP_INDEX=https://mirrors.cloud.tencent.com/pypi/simple \
#       sh tools/fetch-musl-wheels.sh tools/data/needs-musl.txt ./wheels-musl
# ============================================================================
set -u

REPO_ROOT=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
LIST=${1:-"$REPO_ROOT/tools/data/needs-musl.txt"}
OUT=${2:-"$PWD/wheels-musl"}

PYVER=${PYVER:-314}
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}
[ "$JOBS" -gt 8 ] && JOBS=8

# --- 定位 pip -----------------------------------------------------------------
if [ -n "${PIP:-}" ]; then
	PIP_CMD="$PIP"
elif command -v pip3 >/dev/null 2>&1; then
	PIP_CMD="pip3"
elif command -v pip >/dev/null 2>&1; then
	PIP_CMD="pip"
else
	PIP_CMD="python3 -m pip"
fi

# --- 组装平台参数 -------------------------------------------------------------
PLATFORM_ARGS=""
for v in 1_2 1_1 1_0; do
	PLATFORM_ARGS="$PLATFORM_ARGS --platform musllinux_${v}_aarch64"
done

INDEX_ARGS=""
if [ -n "${PIP_INDEX:-}" ]; then
	HOST=$(printf '%s' "$PIP_INDEX" | sed -E 's#^https?://([^/]+).*#\1#')
	INDEX_ARGS="-i $PIP_INDEX --trusted-host $HOST"
fi

[ -f "$LIST" ] || { echo "!! 清单文件不存在: $LIST" >&2; exit 1; }
mkdir -p "$OUT"
TMPBASE=${TMPBASE:-"${TMPDIR:-/tmp}/musl-one"}
mkdir -p "$TMPBASE"

echo "=== 并行下载 musl wheel ==="
echo "  清单  : $LIST ($(wc -l < "$LIST") 个包)"
echo "  输出  : $OUT"
echo "  pip   : $PIP_CMD"
echo "  平台  : musllinux_{1_2,1_1,1_0}_aarch64 / cp$PYVER"
echo "  并行度: $JOBS"
echo ""

dl_one() {
	spec="$1"
	name="${spec%%==*}"
	d="$TMPBASE/$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')"
	rm -rf "$d"; mkdir -p "$d"

	# 先按 musl 平台取
	if $PIP_CMD download "$spec" --no-deps -d "$d" $INDEX_ARGS $PLATFORM_ARGS \
			--python-version "$PYVER" --implementation cp \
			--only-binary=:all: -q >/dev/null 2>&1; then
		whl=$(ls "$d"/*.whl 2>/dev/null | head -1)
		if [ -n "$whl" ]; then
			cp "$whl" "$OUT/"
			echo "OK       $spec"
			return 0
		fi
	fi

	# 回退：不限平台，看是否本来就是纯 py 包（不该出现在此清单里，作提示用）
	rm -rf "$d"; mkdir -p "$d"
	if $PIP_CMD download "$spec" --no-deps -d "$d" $INDEX_ARGS \
			--only-binary=:all: -q >/dev/null 2>&1; then
		whl=$(ls "$d"/*.whl 2>/dev/null | head -1)
		if [ -n "$whl" ]; then
			case "$(basename "$whl")" in
				*py3-none-any*|*py2.py3-none-any*)
					echo "PURE?    $spec  (其实是纯 py 包，应移到 pure-list)"
					return 0 ;;
			esac
			echo "WRONGABI $spec  ($(basename "$whl"))"
			return 1
		fi
	fi

	echo "MISSING  $spec  （上游无 musl wheel，需交叉编译或打桩）"
	return 1
}

export -f dl_one
export PIP_CMD OUT INDEX_ARGS PLATFORM_ARGS PYVER TMPBASE

cat "$LIST" | xargs -P"$JOBS" -I{} bash -c 'dl_one "$@"' _ {} 2>&1 | sort

echo ""
echo "=== 统计 ==="
GOT=$(ls "$OUT"/*.whl 2>/dev/null | wc -l)
TOTAL=$(wc -l < "$LIST")
echo "  成功 $GOT / $TOTAL"
du -sh "$OUT" 2>/dev/null
