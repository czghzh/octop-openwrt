#!/bin/bash
# 加上 PY_SQLITE_ENABLE_LOAD_EXTENSION 重新交叉编译
set -e

CROSS=$HOME/octop-cross/aarch64-linux-musl-cross
CC=$CROSS/bin/aarch64-linux-musl-gcc
WORK=$HOME/octop-cross/work
BUILD=$HOME/octop-cross/build

cd "$BUILD"

echo "===== 1. 确认宏名（源码证据）====="
SQLDIR=$WORK/src/_sqlite
grep -n "PY_SQLITE_ENABLE_LOAD_EXTENSION" "$SQLDIR/connection.c" | head -5
echo "--- 方法表里的条件编译 ---"
grep -n "PY_SQLITE_ENABLE_LOAD_EXTENSION" "$SQLDIR/connection.c" | wc -l
echo "--- module.c 里是否也用到 ---"
grep -n "PY_SQLITE_ENABLE_LOAD_EXTENSION" "$SQLDIR/module.c" | head -5

echo
echo "===== 2. 重新编译模块（关键：加 -DPY_SQLITE_ENABLE_LOAD_EXTENSION=1）====="
CFLAGS_MOD="-fPIC -O2 -Os -pipe -mcpu=cortex-a53 -fno-plt -fno-strict-overflow \
 -Wsign-compare -Wformat -DNDEBUG -Wall -fstack-protector -D_FORTIFY_SOURCE=1 \
 -DPY_SQLITE_ENABLE_LOAD_EXTENSION=1 \
 -DSQLITE_ENABLE_LOAD_EXTENSION=1 \
 -I$WORK/inc -I$WORK/inc/internal \
 -I$SQLDIR -I$WORK/sqlite-amalg"

rm -f connection.o cursor.o module.o prepare_protocol.o statement.o util.o row.o blob.o microprotocols.o
for c in connection cursor module prepare_protocol statement util row blob microprotocols; do
  echo "  CC $c.c"
  $CC $CFLAGS_MOD -c "$SQLDIR/$c.c" -o "$c.o"
done

echo
echo "===== 3. 链接 ====="
rm -f _sqlite3.so
$CC -shared -fPIC -o _sqlite3.so \
  connection.o cursor.o module.o prepare_protocol.o statement.o util.o row.o blob.o microprotocols.o \
  sqlite3.o \
  -Wl,--allow-shlib-undefined -Wl,-z,now -Wl,-z,relro -Wl,-z,max-page-size=4096

ls -la _sqlite3.so

echo
echo "===== 4. 验证新模块确实带了 load_extension 字符串 ====="
echo "--- 从 rodata 找方法名 ---"
strings -a _sqlite3.so | grep -xE "load_extension|enable_load_extension" | head
echo "--- 确认 PyInit ---"
objdump -T _sqlite3.so | grep -i PyInit
echo "--- NEEDED ---"
objdump -p _sqlite3.so | grep NEEDED

echo
echo "===== 5. 准备好设备用的文件名 ====="
cp -f _sqlite3.so _sqlite3.cpython-314-aarch64-linux-musl.so
ls -la _sqlite3.cpython-314-aarch64-linux-musl.so
echo "完成"
