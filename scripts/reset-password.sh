#!/bin/sh
# ============================================================================
#  修改 Octop 管理员密码
# ============================================================================
#
#  用法:
#     sh reset-password.sh <用户名> <新密码>
#     sh reset-password.sh admin 'myNewPass123'
#
#  为什么不用 octop 自带命令：
#     Octop 的 `octop admin` 子命令只有 audit / overview / providers /
#     rotate-jwt-secret，**没有** reset-password 入口。
#     所以这里直接调用 Octop 自己的 password 模块（argon2id）生成哈希后写库，
#     保证哈希格式与密码策略和官方完全一致。
#
#  该脚本会同时清除登录失败计数与锁定时间，可用于解开「账号被锁」的状态。
# ============================================================================

OCTOP_PREFIX="${OCTOP_PREFIX:-/overlay/octop}"
OCTOP_DATA="${OCTOP_DATA:-/overlay}"

USERNAME="${1:-}"
NEWPASS="${2:-}"

if [ -z "$USERNAME" ] || [ -z "$NEWPASS" ]; then
	echo "用法: $0 <用户名> <新密码>" >&2
	echo "例:   $0 admin 'myNewPass123'" >&2
	exit 1
fi

[ -d "$OCTOP_PREFIX" ] || { echo "安装目录不存在: $OCTOP_PREFIX" >&2; exit 1; }
[ -f "$OCTOP_DATA/.octop/octop.db" ] || { echo "数据库不存在: $OCTOP_DATA/.octop/octop.db" >&2; exit 1; }

PYTHONPATH="$OCTOP_PREFIX" HOME="$OCTOP_DATA" \
	python3 - "$USERNAME" "$NEWPASS" "$OCTOP_DATA/.octop/octop.db" <<'PYEOF'
import sqlite3
import sys

from octop.infra.users.password import (
    hash_password,
    validate_password_policy,
    verify_password,
)

username, newpass, dbpath = sys.argv[1], sys.argv[2], sys.argv[3]

# 1) 先按官方策略校验：>=8 位、含字母与数字、不在常见弱密码表
try:
    validate_password_policy(newpass)
except Exception as exc:  # OctopError
    sys.exit(f"密码不符合策略: {exc}")

conn = sqlite3.connect(dbpath)
row = conn.execute(
    "select id, username from users where username = ?", (username,)
).fetchone()
if row is None:
    sys.exit(f"用户不存在: {username}")

# 2) 用官方哈希函数生成，并自校验
newhash = hash_password(newpass)
if not verify_password(newpass, newhash):
    sys.exit("哈希自校验失败，未做任何修改")

# 3) 写库，同时清除失败计数与锁定
conn.execute(
    "update users set password_hash = ?, login_failed_count = 0, "
    "login_locked_until = 0 where username = ?",
    (newhash, username),
)
conn.commit()
conn.close()

print(f"✓ 已更新用户 {username} 的密码")
print("✓ 已清除登录失败计数与锁定状态")
PYEOF
