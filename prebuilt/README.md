# prebuilt/

存放**预编译的二进制产物**。带源码的适配组件放在 `patches/`，这里是产物本身。

## `_sqlite3.cpython-314-aarch64-linux-musl.so`

| 项目 | 值 |
|---|---|
| 大小 | 1,245,096 字节（原版约 103 KB） |
| 架构 | ARM aarch64, musl |
| 依赖 | 仅 `libc.so`（musl），**无 glibc 依赖** |
| Python ABI | cp314 |
| 安装位置 | `/usr/lib/python3.14/lib-dynload/` |

### 它解决什么

OpenWrt 编译 CPython 时没有定义 `PY_SQLITE_ENABLE_LOAD_EXTENSION`，
导致 `sqlite3.Connection` 的 `enable_load_extension()` 与 `load_extension()`
**两个方法连同方法表条目一起消失**。

后果：`sqlite-vec` 等 SQLite 扩展无法加载，Octop 的知识库/向量检索功能不可用。

本模块是用**相同的 CPython 源码 + 相同的 SQLite 版本**重新编译的，
额外定义了这个宏，并把 SQLite 本体（`sqlite3.o`）静态并入，
因此体积约为原版的 12 倍。

### 安装时会做什么

`install.sh` 的「修补 `_sqlite3`」步骤会：

1. 把设备上的原版备份为 `_sqlite3.cpython-314-aarch64-linux-musl.so.orig`
2. 用本模块覆盖原位置

已存在 `.orig` 备份时不会重复备份（幂等）。

### 还原方法

```sh
SO=/usr/lib/python3.14/lib-dynload/_sqlite3.cpython-314-aarch64-linux-musl.so
mv -f "$SO.orig" "$SO"
```

### 自行重建

见 [../docs/BUILD.md](../docs/BUILD.md) 第四节。如果需要针对别的 Python
版本（如 3.11 / 3.12）构建，**必须**改用对应版本的 CPython 源码，
并取设备上对应版本的真实 `pyconfig.h`。

## 本目录不放什么

- `sqlite_vec` 的 `vec0.so` 不在这里 —— 它已被封装进
  `sqlite_vec-0.1.9-py3-none-any.whl`，随 wheel 包一起分发
- 普通 wheel（如 numpy、cryptography）也不在这里 —— 同样在 wheel 包里
