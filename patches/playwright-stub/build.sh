#!/bin/sh
# 构建 playwright 桩包 wheel。
#
# 用法: sh build.sh [输出目录]     默认 dist/
#
# 依赖: Python 3 + setuptools + pip（在任意机器上都能构建，产物是纯 py3 wheel）
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-"$HERE/dist"}

mkdir -p "$OUT"
cd "$HERE"

echo "=== 构建 playwright 桩包 ==="
python3 -m pip wheel . --no-deps -w "$OUT" -q

echo
echo "=== 产物 ==="
ls -la "$OUT"/playwright-*.whl

echo
echo "=== 自校验 ==="
TMPD=$(mktemp -d)
python3 -m pip install --no-deps --target "$TMPD" "$OUT"/playwright-*.whl -q
PYTHONPATH="$TMPD" python3 - <<'PYEOF'
import importlib.metadata as m
import importlib.util as iu
import playwright

print("  version          =", playwright.__version__)
print("  dist version     =", m.version("playwright"))
print("  is stub          =", getattr(playwright, "__is_octop_stub__", False))
print("  find_spec 可见   =", iu.find_spec("playwright") is not None)

from playwright.sync_api import sync_playwright
from playwright.async_api import async_playwright
print("  sync/async 可导入 = OK")

try:
    sync_playwright()
except ImportError as exc:
    print("  调用时正确报错   = OK")
    print("  错误信息         =", str(exc)[:70], "...")
else:
    raise SystemExit("!! 桩包调用时没有报错，不符合预期")

if playwright.__version__ < "1.40":
    raise SystemExit("!! 版本号低于 1.40，无法满足 Octop 的 playwright>=1.40")
print("  版本满足 >=1.40  = OK")
PYEOF
rm -rf "$TMPD"

echo
echo "✅ 桩包构建完成: $OUT"
