#!/usr/bin/env python3
"""在宿主机上完整解析 octop（带 playwright 桩），产出正确的版本清单。

关键调整：
  - 不用之前那份不可信的 constraints（它是 orcakit[all] 单独解析的产物，不含 lark-oapi）
  - 只用一条真正必要的 constraints：钉住 aiobotocore 的窄区间（boto3/botocore）
  - 加 --report 拿结构化解析结果
  - 加 --find-links 指向 playwright 桩
"""
import json
import subprocess
import sys
from pathlib import Path

PIP = "/home/wen/.workbuddy/binaries/python/envs/default/bin/pip"
STUB = "/home/wen/octop-cross/stub"
CONSTRAINTS = "/home/wen/octop-cross/constraints-min.txt"
REPORT = "/home/wen/octop-cross/report-full.json"

# 只钉真正必要的窄区间（aiobotocore 链），其余交给 pip 解
Path(CONSTRAINTS).write_text(
    "aiobotocore==2.25.1\n"
    "boto3==1.40.61\n"
    "botocore==1.40.61\n"
    "s3transfer==0.14.0\n"
)

cmd = [
    PIP, "install",
    "--dry-run",
    "--ignore-installed",
    "--report", REPORT,
    "-c", CONSTRAINTS,
    "--find-links", STUB,
    "-i", "https://mirrors.cloud.tencent.com/pypi/simple",
    "--trusted-host", "mirrors.cloud.tencent.com",
    "octop==1.0.1",
]

print("=" * 70)
print("宿主机完整解析 octop 1.0.1（真实平台 = x86_64/glibc/cp313）")
print("=" * 70)
print("命令:", " ".join(cmd))
print()

r = subprocess.run(cmd, capture_output=True, text=True)
print(r.stdout[-4000:])
if r.returncode != 0:
    print("!!! 失败 !!!")
    print(r.stderr[-3000:])
    sys.exit(1)

print()
print("=" * 70)
print("解析结果")
print("=" * 70)
rep = json.loads(Path(REPORT).read_text())
installs = rep.get("install", [])
print(f"总包数: {len(installs)}")

rows = []
for p in installs:
    n = p["metadata"]["name"]
    v = p["metadata"]["version"]
    url = p.get("download_info", {}).get("url", "")
    kind = "musl" if "musllinux" in url else ("pure" if "none-any" in url else "OTHER")
    rows.append((n.lower(), v, kind, url.rsplit("/", 1)[-1]))

rows.sort()
musl = sum(1 for r in rows if r[2] == "musl")
pure = sum(1 for r in rows if r[2] == "pure")
other = [r for r in rows if r[2] == "OTHER"]

print(f"  musllinux: {musl}")
print(f"  纯 Python: {pure}")
print(f"  其他(需注意): {len(other)}")
for r in other:
    print(f"     ⚠️ {r[0]:24} {r[1]:12} {r[3]}")

# 写完整清单
with open("/home/wen/octop-cross/pkgs.tsv", "w") as f:
    for n, v, k, fn in rows:
        f.write(f"{n}\t{v}\t{k}\t{fn}\n")
print()
print("已写 /home/wen/octop-cross/pkgs.tsv")
