#!/bin/bash
# ============================================================================
#  交叉编译 _sqlite3 模块，恢复被 OpenWrt 裁掉的 load_extension
# ============================================================================
#
#  为什么需要:
#     CPython 的 Modules/_sqlite/connection.c 里，方法与方法表条目都由
#     `PY_SQLITE_ENABLE_LOAD_EXTENSION` 宏保护。OpenWrt 编译时没定义它，
#     于是 sqlite3.Connection 的 load_extension() / enable_load_extension()
#     连同方法表条目一起消失，sqlite-vec 等扩展无法加载。
#
#  三个极易混淆的宏:
#     PY_SQLITE_ENABLE_LOAD_EXTENSION  CPython wrapper  ← 必须定义
#     SQLITE_ENABLE_LOAD_EXTENSION     SQLite 本体      ← 定义
#     SQLITE_OMIT_LOAD_EXTENSION       SQLite 本体      ← 绝不能定义（=0 也算定义）
#
#  用法:
#     sh tools/build-sqlite3-load-extension.sh <源目录> [输出目录]
#
#  源目录布局约定:
#     <源目录>/inc/pyconfig.h     ★ 必须从设备取！源码包里没有
#     <源目录>/inc/               CPython 的 Include/
#     <源目录>/inc/internal/      CPython 的 Include/internal/
#     <源目录>/_sqlite/           CPython 的 Modules/_sqlite/
#     <源目录>/sqlite-amalg/      SQLite amalgamation（sqlite3.c / sqlite3.h）
#
#  可用环境变量:
#     CC      交叉编译器（默认找 aarch64-linux-musl-gcc）
#     MCPU    -mcpu 参数（默认 cortex-a53）
#     PYVER   目标 Python 版本（默认 3.14，只用于生成文件名）
#
#  例:
#     CC=~/aarch64-linux-musl-cross/bin/aarch64-linux-musl-gcc \
#       sh tools/build-sqlite3-load-extension.sh ~/octop-build ./out
# ============================================================================
set -eu

SRC=${1:-}
OUT=${2:-"$PWD"}
PYVER=${PYVER:-3.14}

if [ -z "$SRC" ]; then
	sed -n '5,30p' "$0" | sed 's/^# \{0,1\}//'
	exit 1
fi

# --- 定位交叉编译器 -----------------------------------------------------------
if [ -n "${CC:-}" ]; then
	:
elif command -v aarch64-linux-musl-gcc >/dev/null 2>&1; then
	CC=aarch64-linux-musl-gcc
else
	echo "!! 找不到 aarch64-linux-musl-gcc" >&2
	echo "   请先下载 musl 交叉工具链，或通过 CC=<路径> 指定" >&2
	echo "   工具链: https://musl.cc/aarch64-linux-musl-cross.tgz" >&2
	exit 1
fi

MCPU=${MCPU:-cortex-a53}

SQLDIR="$SRC/_sqlite"
INC="$SRC/inc"
AMALG="$SRC/sqlite-amalg"
BUILD="$SRC/build"

# --- 前置检查 -----------------------------------------------------------------
[ -f "$INC/pyconfig.h" ] || {
	echo "!! 缺 $INC/pyconfig.h" >&2
	echo "   这是设备上真实生成的配置头，源码包里没有，必须从设备取：" >&2
	echo "   scp root@<设备IP>:/usr/include/python$PYVER/pyconfig.h $INC/" >&2
	exit 1
}
[ -d "$SQLDIR" ] || { echo "!! 缺 CPython 的 Modules/_sqlite/: $SQLDIR" >&2; exit 1; }
[ -f "$AMALG/sqlite3.c" ] || { echo "!! 缺 SQLite amalgamation: $AMALG/sqlite3.c" >&2; exit 1; }

mkdir -p "$BUILD" "$OUT"
cd "$BUILD"

echo "=== 0) 环境确认 ==="
echo "  编译器   : $CC"
$CC --version | head -1
echo "  pyconfig : $INC/pyconfig.h"
echo "  sqlite   : $AMALG/sqlite3.c"

echo
echo "=== 1) 确认宏名（源码证据） ==="
printf "  connection.c 中该宏出现次数: "
grep -c "PY_SQLITE_ENABLE_LOAD_EXTENSION" "$SQLDIR/connection.c" || true
grep -n "PY_SQLITE_ENABLE_LOAD_EXTENSION" "$SQLDIR/connection.c" | head -3 | sed 's/^/    /'

echo
echo "=== 2) 编译 sqlite3.o（静态并入，避免链接到 glibc） ==="
$CC -fPIC -O2 -Os -pipe -mcpu="$MCPU" -fno-plt -fstack-protector -DNDEBUG \
	-DSQLITE_ENABLE_LOAD_EXTENSION=1 \
	-DSQLITE_ENABLE_FTS5=1 \
	-DSQLITE_ENABLE_RTREE=1 \
	-DSQLITE_ENABLE_COLUMN_METADATA=1 \
	-DSQLITE_ENABLE_JSON1=1 \
	-DSQLITE_ENABLE_MATH_FUNCTIONS=1 \
	-DSQLITE_THREADSAFE=1 \
	-I"$AMALG" \
	-c "$AMALG/sqlite3.c" -o sqlite3.o
echo "  sqlite3.o 已生成（8 核宿主机约 60 秒）"

echo
echo "=== 3) 编译 _sqlite3 的 9 个源文件（关键：加 PY_SQLITE_ENABLE_LOAD_EXTENSION） ==="
CFLAGS_MOD="-fPIC -O2 -Os -pipe -mcpu=$MCPU -fno-plt -fno-strict-overflow \
 -Wsign-compare -Wformat -DNDEBUG -Wall -fstack-protector -D_FORTIFY_SOURCE=1 \
 -DPY_SQLITE_ENABLE_LOAD_EXTENSION=1 \
 -DSQLITE_ENABLE_LOAD_EXTENSION=1 \
 -I$INC -I$INC/internal \
 -I$SQLDIR -I$AMALG"

for c in connection cursor module prepare_protocol statement util row blob microprotocols; do
	printf "  CC %s.c\n" "$c"
	# shellcheck disable=SC2086
	$CC $CFLAGS_MOD -c "$SQLDIR/$c.c" -o "$c.o"
done

echo
echo "=== 4) 链接 ==="
MODNAME="_sqlite3.cpython-${PYVER/.}-aarch64-linux-musl.so"
rm -f _sqlite3.so
$CC -shared -fPIC -o _sqlite3.so \
	connection.o cursor.o module.o prepare_protocol.o statement.o util.o \
	row.o blob.o microprotocols.o sqlite3.o \
	-Wl,--allow-shlib-undefined -Wl,-z,now -Wl,-z,relro -Wl,-z,max-page-size=4096
ls -la _sqlite3.so

echo
echo "=== 5) 宿主机层验证（⚠️ 还必须到设备上再验一次） ==="
echo "--- 方法名是否进了 rodata ---"
strings -a _sqlite3.so | grep -xE "load_extension|enable_load_extension" | sed 's/^/    /'
echo "--- PyInit 导出符号 ---"
{ objdump -T _sqlite3.so 2>/dev/null || nm -D _sqlite3.so 2>/dev/null; } \
	| grep -i PyInit | sed 's/^/    /'
echo "--- NEEDED（应只有 libc.so，不能出现 libc.so.6） ---"
{ readelf -dW _sqlite3.so 2>/dev/null || objdump -p _sqlite3.so; } \
	| grep NEEDED | sed 's/^/    /'

cp -f _sqlite3.so "$OUT/$MODNAME"
echo
echo "✅ 完成: $OUT/$MODNAME"
echo
echo "部署到设备（务必先备份原版，并用 md5 核对传输完整）:"
echo "  scp \"$OUT/$MODNAME\" root@<设备IP>:/tmp/"
echo "  ssh root@<设备IP> '"
echo "    SO=/usr/lib/python$PYVER/lib-dynload/$MODNAME"
echo "    [ -f \"\$SO.orig\" ] || cp \"\$SO\" \"\$SO.orig\""
echo "    cp /tmp/$MODNAME \"\$SO\" && chmod 755 \"\$SO\"'"
echo "  # 验证: python3 -c \"import sqlite3; c=sqlite3.connect(':memory:'); print(hasattr(c,'load_extension'))\""
