#!/bin/sh
# Octop server launcher (OpenWrt / musl-aarch64).
#
# 所有环境变量集中在这里，供 procd 服务与手动启动共用。
# 可通过环境变量覆盖默认值，例如：
#   OCTOP_PORT=9000 sh start-octop.sh
#
#   OCTOP_PREFIX  安装目录（默认 /overlay/octop）
#   OCTOP_DATA    数据目录，即 $HOME（默认 /overlay）
#   OCTOP_HOST    监听地址（默认 0.0.0.0）
#   OCTOP_PORT    监听端口（默认 8088）
#   OCTOP_LOG     若设置，输出追加到该文件；未设置则输出到 stdout
#   TMPDIR        临时目录（默认 $OCTOP_DATA/tmp）

OCTOP_PREFIX="${OCTOP_PREFIX:-/overlay/octop}"
OCTOP_DATA="${OCTOP_DATA:-/overlay}"
OCTOP_HOST="${OCTOP_HOST:-0.0.0.0}"
OCTOP_PORT="${OCTOP_PORT:-8088}"
TMPDIR="${TMPDIR:-$OCTOP_DATA/tmp}"

export PYTHONPATH="$OCTOP_PREFIX"
export HOME="$OCTOP_DATA"
export TMPDIR
export OCTOP_PREFIX OCTOP_DATA OCTOP_HOST OCTOP_PORT

mkdir -p "$TMPDIR"
cd "$OCTOP_DATA" || exit 1

if [ -n "${OCTOP_LOG:-}" ]; then
    exec python3 -m octop run --host "$OCTOP_HOST" --port "$OCTOP_PORT" >> "$OCTOP_LOG" 2>&1
else
    exec python3 -m octop run --host "$OCTOP_HOST" --port "$OCTOP_PORT"
fi
