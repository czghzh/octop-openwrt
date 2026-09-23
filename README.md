# octop-openwrt

在 **OpenWrt / ImmortalWrt（aarch64 + musl + Python 3.14）** 设备上部署
[Octop](https://github.com/TencentCloud/Octop) 的一键安装套件。

官方 Octop 只提供 x86_64 / glibc 的部署方式。本仓库解决它在 musl-aarch64 设备上的
三个硬伤，并打包好全部依赖，让路由器这类弱设备也能跑起来：

| 硬伤 | 表现 | 本仓库的解法 |
|---|---|---|
| **无 musl wheel** | `pip` 报 `No matching distribution found` | 预置 194 个已适配的 wheel，离线解包安装 |
| **`_sqlite3` 被裁** | `load_extension` 方法整体消失，sqlite-vec 无法加载 | 替换为重新交叉编译的 `_sqlite3` 模块 |
| **playwright 无真 wheel** | 依赖解析失败，服务起不来 | 用桩包替换（导入通过，浏览器功能禁用） |

> **上游源码零改动。** 本仓库只做安装适配，不 fork Octop。Octop 本体按官方 PyPI 版本安装。

---

## 快速开始

在设备上以 **root** 执行：

```sh
wget -qO- https://raw.githubusercontent.com/czghzh/octop-openwrt/main/install.sh | sh
```

脚本会自动下载约 145 MB 的依赖包（第一次较慢），然后完成安装、初始化与开机自启配置。
**首次启动需加载约 190 个 Python 包，大约 40~70 秒**，请耐心等待脚本提示「服务已就绪」。

### 完全离线安装

如果设备无法访问外网，在能上网的机器上下载 Release 里的
`octop-openwrt-runtime-aarch64-musl-cp314-v1.0.1.tar.gz`，然后：

```sh
scp octop-openwrt-runtime-*.tar.gz root@<设备IP>:/overlay/
ssh root@<设备IP>
cd /overlay && tar -xzf octop-openwrt-runtime-*.tar.gz
cd octop-openwrt && sh install.sh
```

---

## 安装后的访问信息

| 项目 | 值 |
|---|---|
| **端口** | `8088` |
| **用户名** | `admin` |
| **密码** | `octop@2026` |
| **本机地址** | `http://127.0.0.1:8088` |
| **局域网地址** | `http://<设备IP>:8088` |

> ⚠️ **请立即修改默认密码。** 本仓库是公开的，默认密码等同于公开凭据。
> 而且 Octop 面板默认监听 `0.0.0.0`，同一局域网内任何人都能访问。

### 修改密码

```sh
sh /overlay/reset-octop-password.sh admin '你的新密码'
```

密码策略：**至少 8 位，需同时包含字母和数字**。

也可以在安装时直接指定，无需改配置文件：

```sh
OCTOP_ADMIN_PASSWORD='myNewPass123' sh install.sh
```

### 更换用户名与端口

```sh
OCTOP_ADMIN_USER=me OCTOP_PORT=9000 sh install.sh
```

---

## 可用环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `OCTOP_ADMIN_USER` | `admin` | 管理员用户名 |
| `OCTOP_ADMIN_PASSWORD` | `octop@2026` | 管理员密码 |
| `OCTOP_PORT` | `8088` | 监听端口 |
| `OCTOP_HOST` | `0.0.0.0` | 监听地址（改成 `127.0.0.1` 可只允许本机访问） |
| `OCTOP_PREFIX` | `/overlay/octop` | 安装目录 |
| `OCTOP_DATA` | `/overlay` | 数据目录（即 `$HOME`，数据库在 `$OCTOP_DATA/.octop`） |
| `OCTOP_WHEELS_DIR` | 包内 `wheels/` | 指定本地 wheel 目录 |
| `OCTOP_BASE_URL` | GitHub Release | 自定义下载源（内网镜像可用） |
| `OCTOP_VERSION` | `1.0.1` | Octop 版本 |
| `OCTOP_FORCE` | `0` | 设为 `1` 则清空已有数据重装 |

---

## 系统要求

| 项目 | 要求 |
|---|---|
| 架构 | `aarch64`（ARMv8） |
| libc | musl（OpenWrt / ImmortalWrt 默认） |
| Python | **3.14**（wheel 是针对 cp314 构建的） |
| 可用存储 | **≥ 2.2 GB**（pip 解包峰值 = 临时 ~850 MB + 目标 ~850 MB + wheel 包 145 MB） |
| 内存 | **≥ 480 MB**（运行期约占用 280~320 MB） |
| 权限 | root |

已在 **GL-MT3000 / MT7981（4 核 Cortex-A53, 952 MB RAM）** 上实测通过，
安装后占用 833 MB 磁盘、运行期 271 MB 内存。

---

## 常用命令

```sh
/etc/init.d/octop status      # 查看运行状态
/etc/init.d/octop restart     # 重启服务
/etc/init.d/octop health      # 健康检查（输出 JSON）
/etc/init.d/octop log         # 查看最近日志
/etc/init.d/octop enable      # 开启开机自启
/etc/init.d/octop disable     # 关闭开机自启
```

服务由 OpenWrt 的 **procd** 守护，意外退出会自动重启（3600 秒内最多 5 次）。

日志文件：`/overlay/octop-server.log`

---

## 功能可用性

| 功能 | 状态 |
|---|---|
| Web 管理面板 | ✅ |
| 模型对话（需自行配置服务商） | ✅ |
| 微信 / QQ / 企业微信 / 飞书通道 | ✅ |
| 命令执行（查 CPU、内存、温度等） | ✅ |
| 知识库 / 向量检索（sqlite-vec） | ✅ |
| 定时任务（cron） | ✅ |
| **浏览器自动化（playwright）** | ❌ **不可用** |

**关于浏览器功能**：Playwright 在 PyPI 上只有 glibc 版，且其浏览器驱动是 glibc 二进制，
在 musl 设备上无法运行。本套件用桩包顶替，使服务能正常启动，但一旦真的调用浏览器
自动化会抛出明确的 `ImportError`。其余功能不受影响。

如确需浏览器自动化，请改用 x86_64 / glibc 设备或 Docker 部署。

---

## 文件位置

| 内容 | 路径 |
|---|---|
| 安装目录 | `/overlay/octop`（约 850 MB） |
| 数据目录 | `/overlay/.octop`（数据库 `octop.db`） |
| 启动脚本 | `/overlay/start-octop.sh` |
| 日志 | `/overlay/octop-server.log` |
| 改密码工具 | `/overlay/reset-octop-password.sh` |
| wheel 缓存 | `/overlay/.octop-installer/wheels`（约 145 MB，装完可删） |
| procd 服务 | `/etc/init.d/octop` |

> 装在 `/overlay` 下是因为 OpenWrt 的 `/usr` 通常是只读 squashfs。

---

## 安装后要做的三件事

1. **改密码** —— 见上文，默认密码是公开的。
2. **配置模型服务商** —— 登录面板 → 管理 → 模型服务商，填入 API Key。
3. **创建 agent 并绑定通道** —— 创建 agent 后，在面板里绑定微信 / QQ（需手机扫码）。

---

## 卸载

```sh
/etc/init.d/octop stop
/etc/init.d/octop disable
rm -f /etc/init.d/octop /overlay/start-octop.sh /overlay/reset-octop-password.sh

rm -rf /overlay/octop                    # 程序
rm -rf /overlay/.octop-installer          # wheel 缓存
# rm -rf /overlay/.octop                  # 数据（含数据库，删前请备份）

# 还原 Python 原始的 _sqlite3 模块（可选）
SO=/usr/lib/python3.14/lib-dynload/_sqlite3.cpython-314-aarch64-linux-musl.so
[ -f "$SO.orig" ] && mv -f "$SO.orig" "$SO"
```

---

## 仓库结构

```
octop-openwrt/
├── install.sh                  # 一键安装脚本（核心）
├── etc/init.d/octop            # procd 开机自启服务
├── scripts/
│   ├── start-octop.sh          # 服务启动器（环境变量集中处）
│   └── reset-password.sh       # 修改管理员密码
├── prebuilt/
│   └── _sqlite3.*.so           # 重新编译的 _sqlite3（恢复 load_extension）
├── patches/
│   └── playwright-stub/        # playwright 桩包源码与构建脚本
├── tools/                      # 宿主机侧工具（复现/重建用）
│   ├── resolve-full.py         # 在宿主机解析出精确依赖清单
│   ├── fetch-musl-wheels.sh    # 并行下载 musl wheel
│   ├── fetch-pure-wheels.sh    # 并行下载纯 Python wheel
│   ├── build-sqlite3-load-extension.sh   # 交叉编译 _sqlite3
│   ├── build-sqlite-vec-wheel.py         # 把 vec0.so 封成正式 wheel
│   ├── constraints-min.txt     # 避免 pip 回溯的版本约束
│   └── make-release.sh         # 打 Release 包
└── docs/
    ├── INSTALL.md              # 详细安装说明与故障排查
    ├── BUILD.md                # 从零重建 wheel 与预编译产物
    └── wheelhouse-manifest.txt # 194 个 wheel 的完整清单
```

---

## 许可

本仓库的脚本与适配代码以 **MIT** 许可发布。
[Octop](https://github.com/TencentCloud/Octop) 本体遵循其自身的开源许可。
预置的 wheel 来自各自的上游项目，许可随各项目。
