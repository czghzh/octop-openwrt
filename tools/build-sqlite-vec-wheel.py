#!/usr/bin/env python3
"""在宿主机上，把交叉编译好的 aarch64/musl vec0.so 打包成正式的 sqlite_vec wheel。

背景：
  - sqlite-vec 在 PyPI 上没有 musllinux_aarch64/cp314 的 wheel
  - 我们已用 musl 交叉工具链编出了 vec0.so（152728 字节，导出 sqlite3_vec_init）
  - 但 langgraph-checkpoint-sqlite 要求 `sqlite-vec>=0.1.6`，pip 需要能"看见"这个包
  - 所以造一个 py3-none-any wheel，里面带上 aarch64 的 vec0.so

预期结构（参照上游 sqlite_vec wheel）：
  sqlite_vec/__init__.py
  sqlite_vec/vec0.so
  sqlite_vec-0.1.9.dist-info/{METADATA,WHEEL,RECORD}
"""
import base64
import hashlib
import os
import shutil
import zipfile
from pathlib import Path

SRC_SO = Path("/home/wen/octop-cross/build-vec/vec0.so")
OUT_DIR = Path("/home/wen/octop-cross/wheels-musl")
OUT = OUT_DIR / "sqlite_vec-0.1.9-py3-none-any.whl"

assert SRC_SO.exists(), f"找不到 {SRC_SO}，请先交叉编译 vec0.so"
size = SRC_SO.stat().st_size
print(f"vec0.so: {size} 字节")

INIT_PY = '''"""Python bindings for sqlite-vec (aarch64/musl build for Octop)."""

import os
import sqlite3
import struct as _struct

__version__ = "0.1.9"

_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
_SO_PATH = os.path.join(_THIS_DIR, "vec0.so")

__all__ = ["load", "loadable_path", "vec_version", "sqlite_version",
           "serialize_float32", "serialize_int8", "serialize_bit"]


def loadable_path() -> str:
    """Return the absolute path to the compiled vec0 extension."""
    return _SO_PATH


def load(conn: "sqlite3.Connection") -> None:
    """Load the sqlite-vec extension into the given connection."""
    conn.enable_load_extension(True)
    conn.load_extension(loadable_path())


def vec_version() -> str:
    """Query the version of the loaded sqlite-vec extension."""
    import sqlite3 as _s
    c = _s.connect(":memory:")
    try:
        load(c)
        return c.execute("select vec_version()").fetchone()[0]
    finally:
        c.close()


def sqlite_version() -> str:
    import sqlite3 as _s
    return _s.sqlite_version


def serialize_float32(vector) -> bytes:
    """Serialize a list of floats into the sqlite-vec f32 blob format."""
    return b"".join(_struct.pack("<f", float(v)) for v in vector)


def serialize_int8(vector) -> bytes:
    return bytes(bytearray((int(v) & 0xFF) for v in vector))


def serialize_bit(vector) -> bytes:
    import numpy as _np
    return _np.packbits(_np.array(vector, dtype=_np.uint8)).tobytes()
'''

METADATA = """Metadata-Version: 2.1
Name: sqlite-vec
Version: 0.1.9
Summary: A vector search SQLite extension (aarch64/musl cross-build for Octop)
Home-page: https://github.com/asg017/sqlite-vec
License: MIT
Requires-Python: >=3.7
Description-Content-Type: text/markdown

sqlite-vec
==========

This is a locally cross-compiled build of `sqlite-vec` for
``aarch64-linux-musl`` / CPython 3.14, produced because PyPI does not ship
a ``musllinux_aarch64`` wheel upstream.

The bundled ``vec0.so`` is statically linked against the SQLite
amalgamation and only depends on musl libc.
"""

WHEEL = """Wheel-Version: 1.0
Generator: octop-cross-build
Root-Is-Purelib: true
Tag: py3-none-any
"""

VER = "0.1.9"
dist = f"sqlite_vec-{VER}.dist-info"

files = {
    "sqlite_vec/__init__.py": INIT_PY.encode(),
    "sqlite_vec/vec0.so": SRC_SO.read_bytes(),
    f"{dist}/METADATA": METADATA.encode(),
    f"{dist}/WHEEL": WHEEL.encode(),
}


def urlsafe_b64_nopad(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


records = []
for name, data in files.items():
    h = urlsafe_b64_nopad(hashlib.sha256(data).digest())
    records.append(f"{name},sha256={h},{len(data)}")
records.append(f"{dist}/RECORD,,")
files[f"{dist}/RECORD"] = ("\n".join(records) + "\n").encode()

OUT_DIR.mkdir(parents=True, exist_ok=True)
if OUT.exists():
    OUT.unlink()
with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
    for name, data in files.items():
        z.writestr(name, data)

print(f"已生成: {OUT}  ({OUT.stat().st_size} 字节)")
