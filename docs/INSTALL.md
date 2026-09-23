# 安装说明与故障排查

## 一、三种安装方式

### 1. 在线安装（推荐）

```sh
wget -qO- https://raw.githubusercontent.com/czghzh/octop-openwrt/main/install.sh | sh
```

脚本会：
1. 检查架构 / Python 版本 / 磁盘 / 内存
2. 从 GitHub Release 下载运行时包（约 145 MB）
3. 离线解包安装到 `/overlay/octop`
4. 替换 `_sqlite3` 模块，恢复 `load_extension`
5. 初始化数据库与管理员账号
6. 安装 procd 服务并设置开机自启
7. 启动并等待就绪，最后打印访问地址与账号

### 2. clone 仓库安装

```sh
git clone https://github.com/czghzh/octop-openwrt
cd octop-openwrt
sh install.sh
```

与方式 1 等价（本地没有 `wheels/` 时仍会下载运行时包）。

### 3. 完全离线安装

适用于设备无法访问外网（内网设备常见）：

```sh
# ① 在能上网的机器下载
#    https://github.com/czghzh/octop-openwrt/releases/download/v1.0.1/octop-openwrt-runtime-aarch64-musl-cp314-v1.0.1.tar.gz

# ② 传到设备
scp octop-openwrt-runtime-*.tar.gz root@192.168.1.1:/overlay/

# ③ 在设备上安装
ssh root@192.168.1.1
cd /overlay
tar -xzf octop-openwrt-runtime-*.tar.gz
cd octop-openwrt
sh install.sh
```

这种方式下脚本检测到本地已有 `wheels/`，**不会**再联网下载。

---

## 二、安装耗时参考

在 4 核 Cortex-A53 / 952 MB 内存的设备上实测：

| 阶段 | 耗时 |
|---|---|
| 下载运行时包（145 MB） | 取决于网速 |
| 解包 194 个 wheel | 约 10~15 分钟（纯磁盘 IO） |
| 首次启动（加载依赖） | 40~70 秒 |

**解包阶段设备 IO 会跑满**，期间 `ls` 可能很慢 —— 这是 eMMC/SD 卡的正常表现，不是卡死。
判断进度可以看 `/overlay/octop` 的顶层条目数是否在增长。

---

## 三、故障排查

### Q1：`No space left on device`

需要至少 1.1 GB 可用空间。检查：

```sh
df -h /overlay
du -sh /overlay/octop /overlay/.octop-installer /overlay/wheelhouse 2>/dev/null
```

可清理项：

```sh
rm -rf /overlay/wheelhouse              # 早期版本遗留的 wheel 目录
rm -rf /overlay/pip-cache /overlay/tmp  # pip 缓存与临时文件
rm -rf /overlay/.octop-installer        # 安装缓存（装完可删，但重装要重新下载）
```

> **注意**：OpenWrt 的 `/tmp` 是 tmpfs，通常只有几百 MB。
> 装大量 wheel 时不要让 pip 把缓存写到 `/tmp`，本脚本已自动改用 `/overlay/.octop-installer/tmp`。

### Q2：服务起不来，端口没监听

```sh
tail -50 /overlay/octop-server.log
```

常见原因：

**① `ZoneInfoNotFoundError: 'No time zone found with key Asia/Shanghai'`**

OpenWrt 用 POSIX 时区串（`/etc/TZ = CST-8`），`/usr/share/zoneinfo/` 是空的，
而 apk/opkg 源里未必有 `tzdata` 包。本套件的 wheel 包里已包含 `tzdata`，重新安装即可。

手工验证：

```sh
PYTHONPATH=/overlay/octop python3 -c "from zoneinfo import ZoneInfo; print(ZoneInfo('Asia/Shanghai'))"
```

**② 内存不足被 OOM 杀死**

```sh
dmesg | grep -i "oom\|killed process"
free -m
```

运行期约需 300 MB。如果设备只有 256 MB，无法运行。

**③ `_sqlite3` 修补出错**

```sh
ls -la /usr/lib/python3.14/lib-dynload/_sqlite3*
```

应当看到原版备份 `*.so.orig`。如果模块损坏，还原：

```sh
SO=/usr/lib/python3.14/lib-dynload/_sqlite3.cpython-314-aarch64-linux-musl.so
mv -f "$SO.orig" "$SO"
```

### Q3：能登录但很快被锁 —— 「invalid credentials」

账号连续输错会触发防爆破锁定。**注意：失败计数归零不代表解锁**，
锁定时间戳是独立字段。

用改密码工具可一并清除锁定：

```sh
sh /overlay/reset-octop-password.sh admin '新密码'
```

查看锁定状态：

```sh
sqlite3 /overlay/.octop/octop.db \
  "select username, login_failed_count, login_locked_until from users;"
```

`login_locked_until` 是 Unix 时间戳，`0` 表示未锁定。

### Q4：某个 CPU 核心持续满载

很可能是**孤儿进程**。通过 `ssh` 跑长脚本时，如果脚本派生了子进程，
**ssh 断开后子进程不会自动退出**。

排查（busybox 没有 `ps -aux`，用 `/proc` 遍历）：

```sh
# 按累计 CPU tick 倒序（stat 第 14、15 字段 = utime + stime）
for p in /proc/[0-9]*; do
  pid=${p#/proc/}
  t=$(awk '{print $14+$15}' $p/stat 2>/dev/null) || continue
  echo "$t $pid $(tr '\0' ' ' < $p/cmdline 2>/dev/null)"
done | sort -rn | head -20
```

辅助判据：

```sh
cat /proc/<pid>/wchan          # blk_mq_get_tag = 等磁盘 IO；空 = 纯 CPU 空转
grep -E 'State|PPid' /proc/<pid>/status   # PPid=1 多为孤儿
```

清理：

```sh
kill -9 <pid>
```

> **坑**：不要用 `ps | while read; do case "$l" in *pip*) kill ...;; esac; done` ——
> `case` 会匹配到循环自身（因为循环的命令行里含 "pip"），造成「杀完还有」的假象。
> 用 `python3*-m\ octop\ run*` 这类精确模式。

### Q5：`sqlite-vec` 加载失败

先确认 `_sqlite3` 修补是否生效：

```sh
python3 -c "
import sqlite3
c = sqlite3.connect(':memory:')
print('load_extension:', hasattr(c, 'load_extension'))
"
```

如果 `False`，说明增强模块没装上，重新跑 `install.sh`。

再确认 vec0.so 能否加载：

```sh
PYTHONPATH=/overlay/octop python3 -c "
import sqlite3, sqlite_vec
c = sqlite3.connect(':memory:')
c.enable_load_extension(True)
sqlite_vec.load(c)
print('vec_version:', sqlite_vec.vec_version())
"
```

> KNN 查询必须带 `LIMIT` 或 `k = ?` 约束，否则报
> `A LIMIT or 'k = ?' constraint is required` —— 这是 sqlite-vec 的设计，不是故障。

### Q6：`playwright` 相关报错

这是预期行为。桩包只在**导入**时通过，真正调用浏览器会抛：

```
ImportError: playwright is not available on this platform (musl/aarch64 stub).
Browser automation features are disabled.
```

如果这个错误影响了你要用的功能，说明该功能依赖浏览器自动化，在本设备上无法使用。
详见仓库 `patches/playwright-stub/README.md`。

### Q7：Python 版本不匹配

```
本包 wheel 针对 Python 3.14 构建，当前为 3.11
```

检查设备 Python 版本：

```sh
python3 -V
ls /usr/lib/python3.14/ 2>/dev/null
```

如果设备是其他 Python 版本，需要自行重建 wheel，见 [BUILD.md](BUILD.md)。

---

## 四、日常维护

### 备份数据

数据都在 `/overlay/.octop/`：

```sh
/etc/init.d/octop stop
tar -czf /tmp/octop-backup-$(date +%Y%m%d).tar.gz -C /overlay .octop
/etc/init.d/octop start
```

Octop 自带的备份命令（导出到指定位置）：

```sh
PYTHONPATH=/overlay/octop HOME=/overlay python3 -m octop backup --help
```

### 轮到新设备

把 `octop-openwrt-runtime-*.tar.gz` 拷过去跑一遍 `install.sh`，
然后把 `.octop/` 目录恢复过去即可。

### 恢复出厂（清空所有数据重装）

```sh
OCTOP_FORCE=1 sh install.sh
```

或者只清数据：

```sh
/etc/init.d/octop stop
rm -rf /overlay/.octop
cd /overlay && sh start-octop.sh     # 首次启动会重新初始化
```

---

## 五、安全建议

1. **立即改掉默认密码** —— 本仓库公开，`octop@2026` 等同于公开凭据。
2. **不要把 8088 端口暴露到公网**。如只在局域网使用，可把监听地址改为
   `OCTOP_HOST=127.0.0.1` 并配合反代；或直接用防火墙限制来源 IP。
3. **定期轮换 JWT secret**：

   ```sh
   PYTHONPATH=/overlay/octop HOME=/overlay python3 -m octop admin rotate-jwt-secret
   ```

4. 面板登录后可在「管理 → 安全」中查看审计日志。
