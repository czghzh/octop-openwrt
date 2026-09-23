#!/bin/bash
# ============================================================================
#  构建 GitHub Release 用的运行时包
# ============================================================================
#
#  产物: octop-openwrt-runtime-aarch64-musl-cp314-v<版本>.tar.gz
#        内含 wheels/ + prebuilt/ + scripts/ + etc/ + install.sh
#        解压后 cd octop-openwrt && sh install.sh 即可完全离线安装
#
#  用法:
#     WHEELS_SRC=/path/to/wheels sh tools/make-release.sh [输出目录]
#
#  说明: wheels 目录应在宿主机上用 tools/fetch-*.sh 预先备好（设备上不必编译）。
# ============================================================================
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT_DIR=${1:-"$REPO_ROOT/dist"}
VERSION=${VERSION:-1.0.1}
WHEELS_SRC=${WHEELS_SRC:-"$REPO_ROOT/wheels"}

PKG_NAME="octop-openwrt"
TARBALL="octop-openwrt-runtime-aarch64-musl-cp314-v${VERSION}.tar.gz"

say() { printf '==> %s\n' "$*"; }
die() { printf '!! %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 前置检查 ---
say "检查源文件"

[ -f "$REPO_ROOT/install.sh" ]                        || die "缺少 install.sh"
[ -f "$REPO_ROOT/prebuilt/_sqlite3.cpython-314-aarch64-linux-musl.so" ] \
	|| die "缺少 prebuilt/_sqlite3.cpython-314-aarch64-linux-musl.so"
[ -f "$REPO_ROOT/scripts/start-octop.sh" ]            || die "缺少 scripts/start-octop.sh"
[ -f "$REPO_ROOT/scripts/reset-password.sh" ]         || die "缺少 scripts/reset-password.sh"
[ -f "$REPO_ROOT/etc/init.d/octop" ]                  || die "缺少 etc/init.d/octop"

[ -d "$WHEELS_SRC" ] || die "wheel 目录不存在: $WHEELS_SRC
   请先运行 tools/fetch-musl-wheels.sh 与 tools/fetch-pure-wheels.sh 备好 wheel，
   或通过 WHEELS_SRC=<目录> 指定。"

WHEEL_COUNT=$(ls "$WHEELS_SRC"/*.whl 2>/dev/null | wc -l)
[ "$WHEEL_COUNT" -gt 100 ] || die "wheel 数量异常: $WHEEL_COUNT"

say "找到 $WHEEL_COUNT 个 wheel（$(du -sh "$WHEELS_SRC" | cut -f1)）"

for pkg in octop playwright sqlite_vec tzdata; do
	ls "$WHEELS_SRC"/${pkg}-*.whl >/dev/null 2>&1 || die "缺少 ${pkg} 的 wheel"
done
say "关键 wheel 齐全"

# ---------------------------------------------------------------- 组装 ---
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

ROOT="$STAGE/$PKG_NAME"
mkdir -p "$ROOT"

say "拷贝文件到暂存目录"
cp -f "$REPO_ROOT/install.sh" "$ROOT/"
mkdir -p "$ROOT/prebuilt" "$ROOT/scripts" "$ROOT/etc/init.d"

cp -f "$REPO_ROOT/prebuilt/_sqlite3.cpython-314-aarch64-linux-musl.so" "$ROOT/prebuilt/"
cp -f "$REPO_ROOT/scripts/start-octop.sh"    "$ROOT/scripts/"
cp -f "$REPO_ROOT/scripts/reset-password.sh" "$ROOT/scripts/"
cp -f "$REPO_ROOT/etc/init.d/octop"          "$ROOT/etc/init.d/"

say "拷贝 $WHEEL_COUNT 个 wheel（这一步最耗时）"
mkdir -p "$ROOT/wheels"
cp -f "$WHEELS_SRC"/*.whl "$ROOT/wheels/"

# 离线安装所需的说明文件
cp -f "$REPO_ROOT/README.md" "$ROOT/" 2>/dev/null || true

chmod 755 "$ROOT/install.sh" "$ROOT/scripts/"*.sh "$ROOT/etc/init.d/octop"

# ---------------------------------------------------------------- 打包 ---
mkdir -p "$OUT_DIR"
say "打包 → $TARBALL"
tar -czf "$OUT_DIR/$TARBALL" -C "$STAGE" "$PKG_NAME"

# ---------------------------------------------------------------- 校验 ---
say "校验产物"
SIZE=$(du -h "$OUT_DIR/$TARBALL" | cut -f1)
say "  大小: $SIZE"
say "  包内 wheel: $(tar -tzf "$OUT_DIR/$TARBALL" | grep -c '\.whl$')"

sha256sum "$OUT_DIR/$TARBALL" | tee "$OUT_DIR/$TARBALL.sha256"
echo
echo "✅ 完成: $OUT_DIR/$TARBALL"
