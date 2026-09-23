#!/usr/bin/env python3
"""在宿主机上解析出目标环境的依赖真值清单（名称 + 版本 + 类型）。

产出可直接喂给 fetch-musl-wheels.sh / fetch-pure-wheels.sh。

用法:
    python3 tools/resolve-full.py ['octop[all]'] [python版本] > tools/data/pkgs.tsv

参数（均可省略）:
    1. 包规格        默认 'octop[all]'
    2. Python 版本   默认 3.14（只影响 --python-version 提示，解析本身在宿主机跑）

环境变量:
    PIP          pip 可执行文件（默认自动探测）
    PYVER        Python 版本，二选一
    INDEX        PyPI 索引 URL（默认官方）
    STUB_DIR     playwright 桩包所在目录（可选；不设则解析会因 playwright 失败）
    CONSTRAINTS  constraints 文件路径（默认 tools/constraints-min.txt）
    REPORT       中间产物 report.json 的路径（默认临时文件，用完即删）

为什么要 constraints:
    `aiobotocore==2.25.1` 要求 `boto3<1.40.62,>=1.40.46`（仅 16 个候选），
    pip 会从最新版逐版下探并反复下载 botocore（每个 14 MB），
    实测让解析从 48 秒恶化到 14 分钟。钉死区间端点即可避免。

⚠️ 不要把宿主机的完整 `pip freeze` 当 constraints:
    平台（glibc/cp313 vs musl/cp314）与 feature set 差异会让结果不通用。
    实测踩过：宿主机解出 websockets==16.1.1，但目标环境 lark-oapi 要求 <16，
    导致设备端 ResolutionImpossible。
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

PKG_SPEC = sys.argv[1] if len(sys.argv) > 1 else "octop[all]"
PYVER = os.environ.get("PYVER") or (sys.argv[2] if len(sys.argv) > 2 else "3.14")
INDEX = os.environ.get("INDEX", "")
STUB_DIR = os.environ.get("STUB_DIR", "")

CONSTRAINTS = Path(
    os.environ.get("CONSTRAINTS", REPO_ROOT / "tools" / "constraints-min.txt")
)

# 定位 pip
PIP = os.environ.get("PIP", "")
if not PIP:
    for cand in ("pip3", "pip"):
        if shutil.which(cand):
            PIP = cand
            break
if not PIP:
    PIP = f"{sys.executable} -m pip"

# report 文件：默认写临时文件
_report_env = os.environ.get("REPORT", "")
if _report_env:
    REPORT = Path(_report_env)
    _tmp_report = False
else:
    REPORT = Path(tempfile.mkdtemp()) / "report.json"
    _tmp_report = True


def build_cmd() -> list[str]:
    cmd = PIP.split() + [
        "install",
        "--dry-run",
        "--ignore-installed",
        "--report", str(REPORT),
    ]
    if CONSTRAINTS.is_file():
        cmd += ["-c", str(CONSTRAINTS)]
    if STUB_DIR and Path(STUB_DIR).is_dir():
        cmd += ["--find-links", STUB_DIR]
    if INDEX:
        host = INDEX.split("//", 1)[-1].split("/", 1)[0]
        cmd += ["-i", INDEX, "--trusted-host", host]
    cmd.append(PKG_SPEC)
    return cmd


def main() -> int:
    cmd = build_cmd()

    print("=" * 68, file=sys.stderr)
    print(f"解析依赖: {PKG_SPEC}", file=sys.stderr)
    print(f"pip     : {PIP}", file=sys.stderr)
    print(f"约束文件: {CONSTRAINTS if CONSTRAINTS.is_file() else '（未使用）'}", file=sys.stderr)
    print(f"桩包目录: {STUB_DIR or '（未指定）'}", file=sys.stderr)
    print("=" * 68, file=sys.stderr)

    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print("!! 解析失败", file=sys.stderr)
        print(r.stderr[-3000:], file=sys.stderr)
        return 1

    rep = json.loads(REPORT.read_text())
    installs = rep.get("install", [])

    rows = []
    for p in installs:
        meta = p.get("metadata", {})
        name = meta.get("name", "?")
        ver = meta.get("version", "?")
        url = p.get("download_info", {}).get("url", "")
        if "musllinux" in url:
            kind = "musl"
        elif "none-any" in url:
            kind = "pure"
        else:
            kind = "OTHER"
        rows.append((name.lower(), ver, kind, url.rsplit("/", 1)[-1]))

    rows.sort(key=lambda x: x[0])

    pure = sum(1 for r in rows if r[2] == "pure")
    musl = sum(1 for r in rows if r[2] == "musl")
    other = [r for r in rows if r[2] == "OTHER"]

    print("", file=sys.stderr)
    print(f"总包数     : {len(rows)}", file=sys.stderr)
    print(f"纯 Python  : {pure}", file=sys.stderr)
    print(f"musl wheel : {musl}（宿主机视角，通常为 0）", file=sys.stderr)
    print(f"需重新拉取 : {len(other)}  ← 这些要按 musl 平台单独下", file=sys.stderr)
    print("", file=sys.stderr)
    print("提示: 类型为 OTHER 的包，下方文件名列显示的是宿主机平台（x86_64），", file=sys.stderr)
    print("      不代表目标设备用包。名称与版本准确。", file=sys.stderr)

    # stdout 输出 TSV，便于重定向
    for n, v, k, fn in rows:
        print(f"{n}\t{v}\t{k}\t{fn}")

    if _tmp_report:
        shutil.rmtree(REPORT.parent, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
