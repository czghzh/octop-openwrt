#!/bin/sh
# ============================================================================
#  Octop 一键安装脚本  —  OpenWrt / ImmortalWrt / musl-aarch64 (Python 3.14)
# ============================================================================
#
#  用法（任选其一）:
#
#    1) 从仓库直接跑（会自动下载 wheel 包，约 145 MB）:
#         wget -qO- https://raw.githubusercontent.com/czghzh/octop-openwrt/main/install.sh | sh
#
#    2) clone 仓库后本地跑:
#         git clone https://github.com/czghzh/octop-openwrt
#         cd octop-openwrt && sh install.sh
#
#    3) 已下载 Release 里的 runtime 包，解压后跑（完全离线）:
#         tar -xzf octop-openwrt-runtime-*.tar.gz && cd octop-openwrt && sh install.sh
#
#  可用环境变量覆盖默认值:
#
#    OCTOP_ADMIN_USER      管理员用户名      默认 admin
#    OCTOP_ADMIN_PASSWORD  管理员密码        默认 octop@2026   ← 强烈建议改掉
#    OCTOP_PORT            监听端口          默认 8088
#    OCTOP_HOST            监听地址          默认 0.0.0.0
#    OCTOP_PREFIX          安装目录          默认 /overlay/octop
#    OCTOP_DATA            数据目录(HOME)    默认 /overlay
#    OCTOP_WHEELS_DIR      本地 wheel 目录   默认 <包内>/wheels
#    OCTOP_BASE_URL        wheel 包下载地址  默认 GitHub Release
#    OCTOP_VERSION         目标版本          默认 1.0.1
#    OCTOP_FORCE           设为 1 则清空已有数据重装
#
#  例：装到 9000 端口并用自定义密码
#    OCTOP_PORT=9000 OCTOP_ADMIN_PASSWORD='myPassword123' sh install.sh
#
# ============================================================================

set -e

# ------------------------------ 配置 ----------------------------------------

OCTOP_VERSION="${OCTOP_VERSION:-1.0.1}"
OCTOP_PREFIX="${OCTOP_PREFIX:-/overlay/octop}"
OCTOP_DATA="${OCTOP_DATA:-/overlay}"
OCTOP_ADMIN_USER="${OCTOP_ADMIN_USER:-admin}"
OCTOP_ADMIN_PASSWORD="${OCTOP_ADMIN_PASSWORD:-octop@2026}"
OCTOP_HOST="${OCTOP_HOST:-0.0.0.0}"
OCTOP_PORT="${OCTOP_PORT:-8088}"
OCTOP_FORCE="${OCTOP_FORCE:-0}"

REPO_URL="https://github.com/czghzh/octop-openwrt"
BASE_URL="${OCTOP_BASE_URL:-$REPO_URL/releases/download/v$OCTOP_VERSION}"
RUNTIME_TARBALL="octop-openwrt-runtime-aarch64-musl-cp314-v$OCTOP_VERSION.tar.gz"

WORKDIR="${OCTOP_WORKDIR:-/overlay/.octop-installer}"
WHEELHOUSE="$WORKDIR/wheels"
PYDYNLOAD="/usr/lib/python3.14/lib-dynload"
SQLITE_SO_NAME="_sqlite3.cpython-314-aarch64-linux-musl.so"

# 本脚本所在目录，用于定位随包分发的 prebuilt/ scripts/ etc/。
#
# 注意：`sh install.sh` 运行时 $0 是 "install.sh"（**不带斜杠**），
# 而 `/path/to/install.sh` 运行时带斜杠 —— 两种写法都要匹配。
# 通过管道运行时（`wget ... | sh`）$0 是 "sh"，都不匹配，此时 SCRIPT_DIR 为空，
# 脚本会改为从 Release 下载运行时包。
SCRIPT_DIR=""
case "$0" in
	install.sh | */install.sh) SCRIPT_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd) ;;
esac

# ------------------------------ 输出工具 ------------------------------------

if [ -t 1 ]; then
	C_RESET=$(printf '\033[0m'); C_RED=$(printf '\033[31m')
	C_GRN=$(printf '\033[32m'); C_YEL=$(printf '\033[33m')
	C_BLU=$(printf '\033[36m'); C_BLD=$(printf '\033[1m')
else
	C_RESET=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s==>%s %s\n' "$C_BLU" "$C_RESET" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
warn() { printf '%s  ! %s%s\n' "$C_YEL" "$C_RESET" "$*"; }
die()  { printf '%s  ✗ %s%s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
step() { printf '\n%s%s[%s]%s %s\n' "$C_BLD" "$C_BLU" "$1" "$C_RESET" "$2"; }

# ------------------------------ 前置检查 ------------------------------------

step 1/8 "环境检查"

[ "$(id -u)" = "0" ] || die "需要 root 权限运行（embed 设备上请用 root）"
ok "root 权限"

[ -c /dev/null ] || die "/dev 未挂载"

ARCH=$(uname -m)
[ "$ARCH" = "aarch64" ] || die "本包只支持 aarch64，当前架构为 $ARCH"
ok "架构 aarch64"

command -v python3 >/dev/null 2>&1 || die "未找到 python3，请先安装: opkg install python3"
PYVER=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
[ "$PYVER" = "3.14" ] || die "本包 wheel 针对 Python 3.14 构建，当前为 $PYVER
  如需其他版本，请参考 docs/BUILD.md 自行构建 wheel"
ok "Python $PYVER"

if ! command -v opkg >/dev/null 2>&1 && ! command -v apk >/dev/null 2>&1; then
	warn "未找到 opkg / apk（非 OpenWrt 系统？继续）"
fi

# 磁盘空间：pip 会先把所有 wheel 解压到临时目录，全部完成后再拷到目标目录，
# 因此峰值约需 2 倍空间（临时 ~850 MB + 目标 ~850 MB），另加 wheel 包本身 145 MB。
mkdir -p "$OCTOP_DATA" 2>/dev/null || true
AVAIL_KB=$(df -k "$OCTOP_DATA" 2>/dev/null | awk 'NR==2 {print $4}')
if [ -n "$AVAIL_KB" ]; then
	NEED_KB=2200000
	if [ "$AVAIL_KB" -lt "$NEED_KB" ]; then
		warn "可用空间 $((AVAIL_KB / 1024)) MB，低于建议值 $((NEED_KB / 1024)) MB"
		warn "pip 解包需临时空间，空间不足可能在最后阶段失败"
	else
		ok "可用空间 $((AVAIL_KB / 1024)) MB"
	fi
fi

# 内存
MEM_MB=$(awk '/MemTotal/ {printf "%d", $2 / 1024}' /proc/meminfo 2>/dev/null)
if [ -n "$MEM_MB" ] && [ "$MEM_MB" -lt 480 ]; then
	warn "内存仅 ${MEM_MB} MB，运行期约需 300 MB，可能紧张"
else
	[ -n "$MEM_MB" ] && ok "内存 ${MEM_MB} MB"
fi

# ------------------------------ 获取 wheel 包 -------------------------------

step 2/8 "准备 wheel 包"

mkdir -p "$WORKDIR"
info "安装包目录: ${SCRIPT_DIR:-（管道模式，将从 Release 下载）}"

prepare_wheels() {
	# 1) 环境变量显式指定
	if [ -n "${OCTOP_WHEELS_DIR:-}" ] && [ -d "$OCTOP_WHEELS_DIR" ]; then
		info "使用指定的 wheel 目录: $OCTOP_WHEELS_DIR"
		WHEELHOUSE="$OCTOP_WHEELS_DIR"
		return 0
	fi

	# 2) 包内已带（解压 runtime 包后的场景）
	if [ -d "$SCRIPT_DIR/wheels" ] && [ -n "$(ls -A "$SCRIPT_DIR/wheels" 2>/dev/null)" ]; then
		info "使用本地 wheel 目录: $SCRIPT_DIR/wheels"
		WHEELHOUSE="$SCRIPT_DIR/wheels"
		return 0
	fi

	# 3) 已经下载过
	if [ -d "$WHEELHOUSE" ] && [ "$(ls "$WHEELHOUSE"/*.whl 2>/dev/null | wc -l)" -gt 100 ]; then
		info "复用已下载的 wheel 包: $WHEELHOUSE"
		return 0
	fi

	# 4) 从 Release 下载运行时包
	info "从 Release 下载运行时包（约 145 MB，请耐心等待）"
	info "  $BASE_URL/$RUNTIME_TARBALL"

	RUNTIME_DIR="$WORKDIR/runtime"
	rm -rf "$RUNTIME_DIR"
	mkdir -p "$RUNTIME_DIR"

	fetch "$BASE_URL/$RUNTIME_TARBALL" "$WORKDIR/runtime.tar.gz" || die "下载失败。

可手动离线安装：
  1. 在能上网的机器上下载 $RUNTIME_TARBALL
  2. 传到设备：scp $RUNTIME_TARBALL root@<设备IP>:/tmp/
  3. 在设备上执行：
       tar -xzf /tmp/$RUNTIME_TARBALL -C /overlay
       cd /overlay/octop-openwrt && sh install.sh"

	info "解压运行时包…"
	tar -xzf "$WORKDIR/runtime.tar.gz" -C "$RUNTIME_DIR" || die "解压失败"

	FOUND=$(find "$RUNTIME_DIR" -maxdepth 3 -type d -name wheels 2>/dev/null | head -1)
	[ -n "$FOUND" ] || die "包内未找到 wheels 目录"
	WHEELHOUSE="$FOUND"
}

fetch() {
	_url="$1"; _out="$2"
	if command -v curl >/dev/null 2>&1; then
		curl -fL --connect-timeout 20 --retry 2 -o "$_out" "$_url"
	elif command -v wget >/dev/null 2>&1; then
		wget -O "$_out" "$_url"
	elif command -v uclient-fetch >/dev/null 2>&1; then
		uclient-fetch -O "$_out" "$_url"
	else
		return 1
	fi
}

prepare_wheels

WHEEL_COUNT=$(ls "$WHEELHOUSE"/*.whl 2>/dev/null | wc -l)
[ "$WHEEL_COUNT" -gt 100 ] || die "wheel 目录内容异常（只有 $WHEEL_COUNT 个 .whl）"
ok "$WHEEL_COUNT 个 wheel 就绪（$(du -sh "$WHEELHOUSE" 2>/dev/null | cut -f1)）"

# 校验关键 wheel
for _p in octop playwright sqlite_vec tzdata; do
	ls "$WHEELHOUSE"/${_p}-*.whl >/dev/null 2>&1 || die "wheel 包缺少 ${_p}"
done
ok "关键 wheel 齐全（octop / playwright / sqlite_vec / tzdata）"

# ------------------------------ 安装 octop ----------------------------------

step 3/8 "安装 octop 到 $OCTOP_PREFIX"

export TMPDIR="$WORKDIR/tmp"
mkdir -p "$TMPDIR"
export PIP_CACHE_DIR="$WORKDIR/pip-cache"
export PIP_DISABLE_PIP_VERSION_CHECK=1

# 清空旧安装目录。
# 必须清空：pip 在 --target 模式下遇到已存在的同名目录只会打印警告并**跳过**，
# 不会覆盖，导致重装时「装了等于没装」。数据在 $OCTOP_DATA/.octop 不受影响。
if [ -d "$OCTOP_PREFIX" ] && [ -n "$(ls -A "$OCTOP_PREFIX" 2>/dev/null)" ]; then
	info "清空已有安装目录 $OCTOP_PREFIX（数据目录 .octop 不受影响）"
	rm -rf "$OCTOP_PREFIX"
fi
mkdir -p "$OCTOP_PREFIX"

info "离线批量解包（--no-index --no-deps，不做依赖求解）"
# 关键：--no-index 只用本地 wheel；--no-deps 跳过求解器
# 因此设备端零网络、零回溯，纯解包（弱 CPU 也不会满载）
python3 -m pip install \
	--no-index \
	--no-deps \
	--upgrade \
	--target "$OCTOP_PREFIX" \
	--disable-pip-version-check \
	--quiet \
	"$WHEELHOUSE"/*.whl || die "安装失败"

PKG_COUNT=$(ls "$OCTOP_PREFIX" | wc -l)
ok "已安装 $PKG_COUNT 个顶层条目（$(du -sh "$OCTOP_PREFIX" 2>/dev/null | cut -f1)）"

# ------------------------------ 修补 _sqlite3 -------------------------------

step 4/8 "修补 Python 的 _sqlite3（恢复 load_extension）"

# OpenWrt 编译 CPython 时未定义 PY_SQLITE_ENABLE_LOAD_EXTENSION，
# 导致 connection 对象的 load_extension()/enable_load_extension() 方法整体消失，
# 进而 sqlite-vec 等扩展无法加载。这里替换为重新编译过的版本。

SO_SRC=""
for _base in "$SCRIPT_DIR" "$WORKDIR"; do
	[ -n "$_base" ] && [ -d "$_base" ] || continue
	SO_SRC=$(find "$_base" -maxdepth 5 -name "$SQLITE_SO_NAME" 2>/dev/null | head -1)
	[ -n "$SO_SRC" ] && break
done

if [ -z "$SO_SRC" ]; then
	# 从 Release 单独下载
	info "下载 _sqlite3 增强模块"
	fetch "$BASE_URL/$SQLITE_SO_NAME" "$WORKDIR/$SQLITE_SO_NAME" \
		&& SO_SRC="$WORKDIR/$SQLITE_SO_NAME" \
		|| warn "下载失败，跳过修补（sqlite-vec 将不可用）"
fi

if [ -n "$SO_SRC" ]; then
	SO_DST="$PYDYNLOAD/$SQLITE_SO_NAME"
	if [ ! -f "$SO_DST" ]; then
		warn "未找到 $SO_DST，跳过修补（Python 安装路径可能不同）"
	elif [ -f "$SO_DST.orig" ]; then
		info "原模块备份已存在，保留不动"
		cp -f "$SO_SRC" "$SO_DST" && chmod 755 "$SO_DST"
		ok "已更新增强模块（$(wc -c < "$SO_DST") 字节）"
	else
		cp -f "$SO_DST" "$SO_DST.orig"
		ok "已备份原模块 → $(basename "$SO_DST").orig（$(wc -c < "$SO_DST.orig") 字节）"
		cp -f "$SO_SRC" "$SO_DST" && chmod 755 "$SO_DST"
		ok "已部署增强模块（$(wc -c < "$SO_DST") 字节）"
	fi

	# 校验
	if python3 -c "
import sqlite3
c = sqlite3.connect(':memory:')
assert hasattr(c, 'load_extension'), 'load_extension missing'
assert hasattr(c, 'enable_load_extension'), 'enable_load_extension missing'
" 2>/dev/null; then
		ok "load_extension / enable_load_extension 可用"
	else
		warn "修补后仍不可用，sqlite-vec 将无法加载（其余功能不受影响）"
	fi
fi

# ------------------------------ 初始化 --------------------------------------

step 5/8 "初始化 Octop 数据"

export PYTHONPATH="$OCTOP_PREFIX"
export HOME="$OCTOP_DATA"
cd "$OCTOP_DATA" || die "无法进入 $OCTOP_DATA"

if [ -f "$OCTOP_DATA/.octop/octop.db" ] && [ "$OCTOP_FORCE" != "1" ]; then
	ok "检测到已有数据（$OCTOP_DATA/.octop），保留不覆盖"
	warn "如需全新安装，请设置 OCTOP_FORCE=1 重跑"
else
	[ "$OCTOP_FORCE" = "1" ] && rm -rf "$OCTOP_DATA/.octop"
	info "创建管理员 $OCTOP_ADMIN_USER"
	python3 -m octop init \
		--admin-username "$OCTOP_ADMIN_USER" \
		--admin-password "$OCTOP_ADMIN_PASSWORD" \
		--yes || die "octop init 失败"
	ok "数据目录已初始化: $OCTOP_DATA/.octop"
fi

# ------------------------------ 安装启动脚本 --------------------------------

step 6/8 "安装启动脚本与开机自启"

SCRIPT_SRC=""
for _base in "$SCRIPT_DIR" "$WORKDIR"; do
	[ -n "$_base" ] && [ -d "$_base" ] || continue
	SCRIPT_SRC=$(find "$_base" -maxdepth 5 -name "start-octop.sh" 2>/dev/null | head -1)
	[ -n "$SCRIPT_SRC" ] && break
done
[ -n "$SCRIPT_SRC" ] || die "找不到 start-octop.sh。
  如果是以管道方式运行（wget ... | sh），脚本需要先从 Release 下载运行时包；
  请确认网络可用，或改为：下载 Release 里的 runtime 包 → 解压 → 进入目录运行 sh install.sh"

# 写入安装目录定制后的默认值，使手动启动与服务启动行为一致
sed \
	-e "s|^OCTOP_PREFIX=.*|OCTOP_PREFIX=\"\${OCTOP_PREFIX:-$OCTOP_PREFIX}\"|" \
	-e "s|^OCTOP_DATA=.*|OCTOP_DATA=\"\${OCTOP_DATA:-$OCTOP_DATA}\"|" \
	-e "s|^OCTOP_HOST=.*|OCTOP_HOST=\"\${OCTOP_HOST:-$OCTOP_HOST}\"|" \
	-e "s|^OCTOP_PORT=.*|OCTOP_PORT=\"\${OCTOP_PORT:-$OCTOP_PORT}\"|" \
	"$SCRIPT_SRC" > "$OCTOP_DATA/start-octop.sh"
chmod 755 "$OCTOP_DATA/start-octop.sh"
ok "启动脚本 → $OCTOP_DATA/start-octop.sh"

# 配套的改密码工具（Octop 没有内置的 reset-password 子命令）
PW_SRC=""
for _base in "$SCRIPT_DIR" "$WORKDIR"; do
	[ -n "$_base" ] && [ -d "$_base" ] || continue
	PW_SRC=$(find "$_base" -maxdepth 5 -name "reset-password.sh" 2>/dev/null | head -1)
	[ -n "$PW_SRC" ] && break
done
if [ -n "$PW_SRC" ]; then
	cp -f "$PW_SRC" "$OCTOP_DATA/reset-octop-password.sh"
	chmod 755 "$OCTOP_DATA/reset-octop-password.sh"
	ok "改密码工具 → $OCTOP_DATA/reset-octop-password.sh"
fi

INITD_SRC=""
for _base in "$SCRIPT_DIR" "$WORKDIR"; do
	[ -n "$_base" ] && [ -d "$_base" ] || continue
	INITD_SRC=$(find "$_base" -maxdepth 6 -path "*/etc/init.d/octop" -type f 2>/dev/null | head -1)
	[ -n "$INITD_SRC" ] && break
done

if [ -n "$INITD_SRC" ] && [ -d /etc/init.d ]; then
	# 把实际路径写进服务脚本，使其支持自定义 OCTOP_DATA
	sed \
		-e "s|^PROG=.*|PROG=\"$OCTOP_DATA/start-octop.sh\"|" \
		-e "s|^LOGFILE=.*|LOGFILE=\"$OCTOP_DATA/octop-server.log\"|" \
		-e "s|^PIDFILE=.*|PIDFILE=\"$OCTOP_DATA/octop-server.pid\"|" \
		"$INITD_SRC" > /etc/init.d/octop
	chmod 755 /etc/init.d/octop
	ok "procd 服务 → /etc/init.d/octop"
	ENABLE_OK=1
else
	warn "未安装 procd 服务（找不到 init.d 脚本或系统无 /etc/init.d）"
	ENABLE_OK=0
fi

# ------------------------------ 启动服务 ------------------------------------

step 7/8 "启动服务"

# 清理旧实例
for _p in /proc/[0-9]*; do
	_pid=${_p#/proc/}
	_cmd=$(tr '\0' ' ' < "$_p/cmdline" 2>/dev/null) || continue
	case "$_cmd" in
		python3*-m\ octop\ run*) kill -9 "$_pid" 2>/dev/null || true ;;
	esac
done
sleep 1

if [ "$ENABLE_OK" = "1" ]; then
	/etc/init.d/octop enable >/dev/null 2>&1 && ok "已设置开机自启"
	/etc/init.d/octop start >/dev/null 2>&1 || warn "服务启动命令返回非零，稍后请看日志"
else
	OCTOP_LOG="$OCTOP_DATA/octop-server.log" sh "$OCTOP_DATA/start-octop.sh" >/dev/null 2>&1 &
	ok "已手动后台启动"
fi

info "等待服务就绪（首次启动需加载约 190 个包，约 40~70 秒）"
_i=0
READY=0
while [ "$_i" -lt 24 ]; do
	sleep 5
	_i=$((_i + 1))
	if python3 -c "
import urllib.request, sys
try:
    urllib.request.urlopen('http://127.0.0.1:$OCTOP_PORT/api/health', timeout=4).read()
except Exception:
    sys.exit(1)
" 2>/dev/null; then
		READY=1
		break
	fi
done

if [ "$READY" = "1" ]; then
	HEALTH=$(python3 -c "
import urllib.request
print(urllib.request.urlopen('http://127.0.0.1:$OCTOP_PORT/api/health', timeout=6).read().decode())
" 2>/dev/null)
	ok "服务已就绪"
	say "     $HEALTH"
else
	warn "服务在 $(( _i * 5 )) 秒内未就绪，请查看日志："
	say "     tail -50 $OCTOP_DATA/octop-server.log"
fi

# 记录 PID
for _p in /proc/[0-9]*; do
	_pid=${_p#/proc/}
	_cmd=$(tr '\0' ' ' < "$_p/cmdline" 2>/dev/null) || continue
	case "$_cmd" in
		python3*-m\ octop\ run*) echo "$_pid" > "$OCTOP_DATA/octop-server.pid" ;;
	esac
done

# ------------------------------ 完成 ----------------------------------------

step 8/8 "安装完成"

LAN_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
[ -z "$LAN_IP" ] && LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null | cut -d/ -f1)
[ -z "$LAN_IP" ] && LAN_IP="<设备IP>"

say ""
say "${C_BLD}════════════════════════════════════════════════${C_RESET}"
say "${C_BLD}  Octop 已安装完成${C_RESET}"
say "${C_BLD}════════════════════════════════════════════════${C_RESET}"
say ""
say "   ${C_BLD}访问地址${C_RESET}"
say "     本机   http://127.0.0.1:$OCTOP_PORT"
say "     局域网 http://$LAN_IP:$OCTOP_PORT"
say ""
say "   ${C_BLD}登录账号${C_RESET}"
say "     用户名 ${C_GRN}$OCTOP_ADMIN_USER${C_RESET}"
say "     密码   ${C_GRN}$OCTOP_ADMIN_PASSWORD${C_RESET}"
say ""
say "   ${C_YEL}⚠ 请尽快修改默认密码（见下方命令）${C_RESET}"
say ""
say "   ${C_BLD}常用命令${C_RESET}"
say "     /etc/init.d/octop status     查看状态"
say "     /etc/init.d/octop restart    重启服务"
say "     /etc/init.d/octop health     健康检查"
say "     /etc/init.d/octop log        查看日志"
say "     /etc/init.d/octop disable    关闭开机自启"
say ""
say "   ${C_BLD}文件位置${C_RESET}"
say "     安装目录 $OCTOP_PREFIX  ($(du -sh "$OCTOP_PREFIX" 2>/dev/null | cut -f1))"
say "     数据目录 $OCTOP_DATA/.octop"
say "     日志     $OCTOP_DATA/octop-server.log"
say "     wheel 包 $WHEELHOUSE  ($(du -sh "$WHEELHOUSE" 2>/dev/null | cut -f1))"
say ""
say "   ${C_BLD}下一步：配置模型服务商${C_RESET}"
say "     浏览器打开上面的地址 → 登录 → 管理 → 模型服务商"
say "     填入你的 API Key 后即可创建 agent 并绑定微信 / QQ"
say ""
say "   ${C_BLD}修改密码${C_RESET}"
say "     sh $OCTOP_DATA/reset-octop-password.sh $OCTOP_ADMIN_USER '你的新密码'"
say "     （密码策略：至少 8 位，需同时含字母和数字）"
say ""
say "   ${C_BLD}重装 / 卸载${C_RESET}"
say "     全新重装  OCTOP_FORCE=1 sh install.sh"
say "     卸载服务  /etc/init.d/octop stop; /etc/init.d/octop disable"
say "               rm -f /etc/init.d/octop $OCTOP_DATA/start-octop.sh"
say "     清理文件  rm -rf $OCTOP_PREFIX $WHEELHOUSE"
say "     （数据保留在 $OCTOP_DATA/.octop，删除前请先备份）"
say ""
say "${C_BLD}════════════════════════════════════════════════${C_RESET}"
