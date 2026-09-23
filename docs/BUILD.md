# 从零重建依赖包

本仓库预置的 194 个 wheel 与 `_sqlite3` 模块都是**构建产物**。
当出现以下情况时，需要按本文重新构建：

- 官方 Octop 发新版，依赖变了
- 目标设备的 Python 版本不是 3.14
- 想自己编译 `_sqlite3` 而不是使用预置的二进制

**核心原则：一切编译都在 x86_64 宿主机做，不在设备上做。**
交叉编译 `sqlite3.c` 在 8 核宿主机上约 60 秒；在 4 核 A53 设备上要几十分钟，
而且容易因 ssh 断开留下孤儿进程。

---

## 零、为什么需要这些步骤

直接把 `pip install octop` 放到设备上跑会很惨：

1. **pip 的依赖求解器是单线程的** —— 4 核设备上表现为「一核满载、三核空闲」，
   且无法并行化。
2. **窄版本区间触发暴力回溯** —— 例如 `aiobotocore==2.25.1` 要求
   `boto3<1.40.62,>=1.40.46`（只有 16 个候选），pip 从最新版逐版下探，
   每个候选都要下载 14 MB 的 `botocore`。实测 14 分钟 + 547 MB 下载量。
3. **`/tmp` 是 tmpfs** —— 默认几百 MB，pip 缓存直接把它撑爆。

所以正确架构是：

```
宿主机（x86_64 / 8 核 / 大内存）
  ├─ 解析出精确的依赖清单（name + version）
  ├─ 并行下载全部 wheel
  └─ 交叉编译 C 扩展 → 打包
          ↓ scp / Release
设备（aarch64 musl / 弱机）
  └─ pip install --no-index --no-deps   ← 零求解、零网络、纯解包
```

---

## 一、准备宿主机

```sh
# 1. musl 交叉工具链（约 103 MB）
cd ~
wget https://musl.cc/aarch64-linux-musl-cross.tgz
tar -xzf aarch64-linux-musl-cross.tgz
export CROSS=$HOME/aarch64-linux-musl-cross
export CC=$CROSS/bin/aarch64-linux-musl-gcc
$CC --version        # 应为 GCC 11.2.1, target: aarch64-linux-musl

# 2. 工作目录
mkdir -p ~/octop-build && cd ~/octop-build
mkdir -p wheels work build
```

---

## 二、解析精确依赖清单

用与**目标设备一致**的平台参数解析，产出 `pkgs.tsv`：

```sh
python3 tools/resolve-full.py 'octop[all]' > tools/data/pkgs.tsv

# 从清单拆出两类（fetch 脚本会读它们）
awk -F'\t' '$3=="OTHER" {print $1"=="$2}' tools/data/pkgs.tsv > tools/data/needs-musl.txt
awk -F'\t' '$3=="pure"  {print $1"=="$2}' tools/data/pkgs.tsv > tools/data/pure-list.txt
```

关键点：必须指定 `--platform musllinux_1_2_aarch64 --only-binary=:all:`，
否则 pip 会按宿主机的 glibc 平台解析，拿到的版本号在设备上不适用。

`pkgs.tsv` 的格式为 `name<TAB>version<TAB>kind<TAB>filename`，`kind` 为
`wheel` 或 `sdist`。

### 先做 extra 审计

`octop[all]` 的 `[all]` 会额外拉进大量无关依赖。实测
`orcakit-harness-agent[all]` 多拉了 **33 个依赖**（AWS S3、阿里 OSS、华为 OBS、
Docker、桌面 GUI 等），对最小可用毫无用处。

```sh
python3 - <<'PY'
import json, urllib.request
d = json.load(urllib.request.urlopen('https://pypi.org/pypi/orcakit-harness-agent/json'))
for r in d['info'].get('requires_dist') or []:
    print(r)
PY
```

先弄清哪些能砍掉，再决定要不要装。

---

## 三、并行下载 wheel

**这是提速的关键**：一个包一个独立的 `pip` 进程，用 `xargs -P8` 拉满多核。

```sh
# 3.1 确定哪些包需要 musl 版 wheel
grep -P '\twheel\t' pkgs.tsv | cut -f1 > want-all.txt

# 3.2 分两批：含 C/Rust 扩展的（需平台参数）与纯 Python 的
sh tools/fetch-musl-wheels.sh tools/data/needs-musl.txt ./wheels-musl
sh tools/fetch-pure-wheels.sh tools/data/pure-list.txt ./wheels-pure
```

> **注意**：两个 `-P8` 批次不要写同一个目录，会互相踩。

实测成绩：40 个 musl 包秒级拿到 35 个；157 个纯 Python 包成功 156 个。

### constraints：只钉真正窄的区间

如果某次解析很慢，找出那个窄区间单独钉住：

```sh
# tools/constraints-min.txt
aiobotocore==2.25.1
boto3==1.40.61
botocore==1.40.61
s3transfer==0.14.0
```

```sh
pip download -c constraints-min.txt ...
```

实测这一项把解析从 **14 分钟降到 48 秒**。

> **不要**把宿主机的完整 `pip freeze` 当 constraints。踩过的坑：
> 宿主机（glibc / cp313）解析出 `websockets==16.1.1`，
> 但目标环境里 `lark-oapi 1.7.3` 要求 `websockets<16`，
> 导致设备端直接 `ResolutionImpossible`。
> **平台差异 + feature set 差异会让解析结果不通用。**

---

## 四、交叉编译 `_sqlite3`（恢复 `load_extension`）

### 问题根源

CPython 的 `Modules/_sqlite/connection.c` 里，方法与方法表条目都由
`PY_SQLITE_ENABLE_LOAD_EXTENSION` 宏保护：

```c
// Modules/_sqlite/connection.c
#ifdef PY_SQLITE_ENABLE_LOAD_EXTENSION
    ... pysqlite_connection_enable_load_extension_impl ...
    ... pysqlite_connection_load_extension_impl ...
#endif
```

OpenWrt 编译时没定义这个宏，于是 `load_extension()` 和
`enable_load_extension()` **整体消失**，sqlite-vec 之类扩展无法加载。

**三个极易混淆的宏：**

| 宏 | 作用域 | 处理 |
|---|---|---|
| `PY_SQLITE_ENABLE_LOAD_EXTENSION` | CPython wrapper | **必须定义**，否则 Python 方法消失 |
| `SQLITE_ENABLE_LOAD_EXTENSION` | SQLite 本体 | 定义（`compile_options()` 会多一项） |
| `SQLITE_OMIT_LOAD_EXTENSION` | SQLite 本体 | **绝不能定义**（`=0` 也算定义，用 `#ifdef` 判定） |

### 构建步骤

```sh
# 4.1 取设备上真实生成的 pyconfig.h（源码包里没有！）
scp root@<设备IP>:/usr/include/python3.14/pyconfig.h work/inc/pyconfig.h

# 4.2 取 CPython 源码（版本必须与设备完全一致）
wget https://www.python.org/ftp/python/3.14.5/Python-3.14.5.tgz
tar -xzf Python-3.14.5.tgz Python-3.14.5/Modules/_sqlite Python-3.14.5/Include
cp -r Python-3.14.5/Include/* work/inc/
mkdir -p work/inc/internal && cp -r Python-3.14.5/Include/internal/* work/inc/internal/

# 4.3 取 SQLite amalgamation（版本对齐设备的 sqlite_version）
wget https://www.sqlite.org/2026/sqlite-amalgamation-3530400.zip
unzip -o sqlite-amalgamation-3530400.zip -d work/sqlite-amalg

# 4.4 编译 sqlite3.o（静态并入，避免链接到 glibc）
$CC -fPIC -O2 -Os -pipe -mcpu=cortex-a53 -fno-plt -fstack-protector -DNDEBUG \
  -DSQLITE_ENABLE_LOAD_EXTENSION=1 -DSQLITE_ENABLE_FTS5=1 -DSQLITE_ENABLE_RTREE=1 \
  -DSQLITE_ENABLE_COLUMN_METADATA=1 -DSQLITE_ENABLE_JSON1=1 \
  -DSQLITE_ENABLE_MATH_FUNCTIONS=1 -DSQLITE_THREADSAFE=1 \
  -Iwork/sqlite-amalg -c work/sqlite-amalg/sqlite3.c -o build/sqlite3.o

# 4.5 编译 _sqlite3 的 9 个源文件并链接
sh tools/build-sqlite3-load-extension.sh ~/octop-build ./out
```

脚本已封装上述逻辑，产物为
`build/_sqlite3.cpython-314-aarch64-linux-musl.so`。

### 验证（必做两层）

```sh
# 宿主机层：确认方法名进了 rodata
strings -a build/_sqlite3.cpython-314-aarch64-linux-musl.so | grep -x load_extension
nm -D  build/_sqlite3.cpython-314-aarch64-linux-musl.so | grep PyInit
readelf -dW build/_sqlite3.cpython-314-aarch64-linux-musl.so | grep NEEDED
# NEEDED 应只有 libc.so（musl），不能出现 libc.so.6（glibc）

# 设备层：传过去后确认真的可用
python3 -c "import sqlite3; c=sqlite3.connect(':memory:'); print(hasattr(c,'load_extension'))"
```

> **踩坑**：宿主机上 `strings` 有方法名 ≠ 设备上能 import，两层都要验。
> 另外曾遇到「方法仍为 False」，追查发现是**部署的还是旧文件** ——
> 传完文件一定核对 md5。

---

## 五、交叉编译 sqlite-vec 并封装成 wheel

`sqlite-vec` 上游没有 musl wheel。自己编出 `vec0.so` 后，
**不能直接拷进 site-packages**（pip 不认，会报 `No matching distribution found`），
必须包成正式 wheel。

```sh
# 5.1 取源码（主仓的 sqlite-vec.h 是 404，需自建）
for f in sqlite-vec.c sqlite-vec-diskann.c sqlite-vec-ivf.c \
         sqlite-vec-rescore.c sqlite-vec-ivf-kmeans.c; do
  curl -sLO https://raw.githubusercontent.com/asg017/sqlite-vec/main/$f
done

# 5.2 补上构建系统才生成的头文件
cat > sqlite-vec.h <<'EOF'
#define SQLITE_VEC_VERSION "v0.1.9"
#define SQLITE_VEC_VERSION_MAJOR 0
#define SQLITE_VEC_VERSION_MINOR 1
#define SQLITE_VEC_VERSION_PATCH 9
#define SQLITE_VEC_DATE "2026-09-23"
#define SQLITE_VEC_SOURCE "asg017/sqlite-vec@main"
#define SQLITE_VEC_API
EOF

# 5.3 编译（GCC 11 编 NEON 路径需要 -flax-vector-conversions）
$CC -fPIC -O2 -Os -mcpu=cortex-a53 -fno-plt -fstack-protector -DNDEBUG \
  -DSQLITE_VEC_ENABLE_NEON=1 -flax-vector-conversions -I. \
  -shared sqlite-vec.c -o vec0.so -lm

# 5.4 封装成 wheel
python3 tools/build-sqlite-vec-wheel.py vec0.so ./wheels-musl
```

> **输出文件名必须是 `vec0.so`**：SQLite 按文件名推导入口符号
> （`vec0-musl.so` 会期望 `sqlite3_vec0musl_init`，报 `Symbol not found`）。

### wheel 构造要点

- `WHEEL` 文件里 `Tag: py3-none-any`（自己编的，无需挂 abi tag）
- `RECORD` 每行格式：`路径,sha256=<urlsafe_b64 无填充>,<字节数>`
- `dist-info` 目录名与 `METADATA` 里的 `Name` 必须一致（`-` ↔ `_`）

---

## 六、构建 playwright 桩包

```sh
cd patches/playwright-stub
sh build.sh          # 产物在 dist/
```

设计三要点（详细说明见该目录的 README）：

1. **版本号要够高** —— 必须满足下游的 `>=1.40`
2. **不要用模块级 `__getattr__` 抛错** —— 会拦掉 `from X import Y`
3. **仅调用时抛错** —— 保证 `import` 与 `find_spec` 都正常

---

## 七、打包发布

```sh
WHEELS_SRC=./all-wheels sh tools/make-release.sh
```

产物：

```
dist/octop-openwrt-runtime-aarch64-musl-cp314-v1.0.1.tar.gz      约 140 MB
dist/octop-openwrt-runtime-aarch64-musl-cp314-v1.0.1.tar.gz.sha256
```

把 `.tar.gz` 上传为 GitHub Release 附件即可。

---

## 八、当前版本的实际数据

| 项目 | 数值 |
|---|---|
| 依赖轮子总数 | 194 |
| 其中 musl（含 C/Rust 扩展） | 35 |
| 其中纯 Python | 159 |
| 被跳过的只发 sdist 的包 | `esdk-obs-python`、`oss2`、`evdev`、`crcmod`（属无关 extra） |
| 安装后体积 | 833.5 MB |
| 运行期内存 | 271 MB RSS |
| 设备 | GL-MT3000 / MT7981，4 核 Cortex-A53，952 MB |

完整清单见 [wheelhouse-manifest.txt](wheelhouse-manifest.txt)。
