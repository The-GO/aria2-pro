# aria2-pro

面向 **aria2 1.37.0** 的一键安装 / 管理 / 后处理方案。

基于 [P3TERX/aria2.sh](https://github.com/P3TERX/aria2.sh) 与 [P3TERX/aria2.conf](https://github.com/P3TERX/aria2.conf) 重写。
这两个上游项目分别停留在 **2020 年 (v2.7.4)** 和 **2021 年**，已无法用于安装当前版本的 aria2。

---

## 为什么需要这个项目

直接使用上游脚本安装最新 aria2 会**失败**：

```
$ aria2c --conf-path=/root/.aria2c/aria2.conf
Parse error in /root/.aria2c/aria2.conf
Exception: [AbstractOptionHandler.cc:69] errorCode=28 We encountered a problem
while processing the option '--max-connection-per-server'.
  -> [OptionHandlerImpl.cc:184] errorCode=1 max-connection-per-server must be between 1 and 16.
```

根因：

1. 上游脚本依赖 [P3TERX/Aria2-Pro-Core](https://github.com/P3TERX/Aria2-Pro-Core) 提供预编译二进制，而该仓库最后一个 release 是 **2021-08-22 的 1.36.0**，之后再未发布。官方 aria2 在 **2023-11-15** 发布了 **1.37.0**。
2. 上游 `aria2.conf` 把 `max-connection-per-server` 写成 `32`，aria2 自 1.36 起把上限收紧为 **16**，1.37 严格校验，导致**直接拒绝启动**（不是警告）。
3. 上游脚本注入的 `retry-on-400/403/406/unknown` 四个选项在 aria2 1.37 中已被**移除**。

---

## 修复清单

### 主脚本（bin/aria2.sh）

| # | 问题 | 影响 |
|---|------|------|
| 1 | 依赖的 Aria2-Pro-Core 停在 1.36.0 | 无法安装 1.37 |
| 2 | `max-connection-per-server=32` | **aria2 1.37 拒绝启动（致命）** |
| 3 | 注入已移除的 `retry-on-400/403/406/unknown` | 启动警告、误导 |
| 4 | `Download_aria2` 架构映射与新源命名不符、用 `tar` 解 `.zip` | 下载/解压失败 |
| 5 | 依赖缺少 `unzip` | 新版解压失败 |
| 6 | `check_pid` / `check_running` 把僵尸(Z)进程判成"正在运行" | **`restart` 后 aria2 起不来**（实测复现） |
| 7 | `do_stop` 只 `kill -9` 不等待退出 | 紧接着 `start` 端口/会话冲突 |
| 8 | `do_start` 固定 `sleep 2s` 判成败 | 慢机 / ARM 误报启动失败 |
| 9 | `Add_iptables` 用 `${aria2_RPC_port}`，`Del_iptables` 用 `${aria2_port}` | 改端口后旧放行规则**永远删不掉** |
| 10 | `Update_Shell` 自动 `wget` 覆盖本地脚本 | **把全部修复冲回旧版** |
| 11 | jsdelivr 第三备源 URL 写法错误（一直 400） | 从未生效的死代码 |
| 12 | `Set_aria2_RPC_passwd` 的 `sed` 未转义密钥中的正则元字符 | 含 `.`/`*` 的密钥替换失败 |
| 13 | `cd "${aria2_conf_dir}"` 失败不退出；`rm $(which)` 未加引号 | shellcheck 高危项 |
| 14 | `Set_iptables` 遇无 iptables 环境直接中断安装 | Oracle / 容器环境装不上 |

### 后处理脚本（hooks/）

| # | 问题 | 影响 |
|---|------|------|
| 1 | `core` 的 `DELETE_TORRENT_FILES`：`for f in "${多行变量}"` | **循环只执行一次，种子永远删不掉**；含空格文件名还会使 `rm` 参数被拆开 |
| 2 | `DELETE_EXCLUDE_FILE` 未校验 `${TASK_PATH}` | 空路径或异常值可抵达 `find \| xargs rm -vf` |
| 3 | `DELETE_EMPTY_DIR` 用 `[[ $a =~ "$b" ]]` | 引号使其变字面量；不加引号路径含正则元字符时误判 |
| 4 | `upload.sh` 的 `LOAD_RCLONE_ENV`：`export $(grep ... \| xargs -0)` | 含空格的值被截断，非法标识符直接报错导致**变量丢失** |
| 5 | `upload.sh` 用 `rclone move` | 上传一开始就删本地，失败后数据悬空 |
| 6 | `upload.sh` 上传后不校验 | 远端缺文件也照删本地 |
| 7 | `clean.sh` 每次都做无用的 RPC 往返 | 增加延迟、aria2 繁忙时钩子失败 |
| 8 | `clean.sh` RPC 不可用时 `DOWNLOAD_DIR` 为空 | 清理全部跳过 |
| 9 | `DELETE_DOT_ARIA2` 只查 `FILE_PATH`/`TASK_PATH` 两处 | 多文件 BT 任务的根控制文件残留 |
| 10 | `GET_INFO_HASH` 对 `-z` 判断在 `jq` 输出 `null` 时失效 | null 分支不可达 |
| 11 | 普通 HTTP 下载没有 infoHash 却报 `ERROR` | 误导用户以为出错 |
| 12 | `RPC_TASK_INFO` 的 `curl` 无超时、把 400 打到 stderr | 钩子日志被污染 |
| 13 | `move.sh` 的 `mv` 未加 `--` | 以 `-` 开头的路径解析失败 |
| 14 | `move.sh` 日志写 `DEST_PATH` 而实际落在 `dest/dir` | 日志与实际不符 |
| 15 | `delete.sh` 用 `-f "${TASK_PATH}.aria2"` 决定是否删除 | 已完成下载的清理被跳过 |
| 16 | `delete.sh` 布尔表达式优先级错误 | `delete-on-unknown` 在不相关状态下误触发 |
| 17 | `delete.sh` 的 `rm -vrf` 无防护 | 删到下载根目录的风险 |
| 18 | `TASK_INFO` 的 `printf` 格式串以 `-` 开头 | `printf: --: invalid option` |

---

## 安装

```bash
git clone https://github.com/The-GO/aria2-pro.git
cd aria2-pro
bash install.sh
```

自定义路径：

```bash
bash install.sh --conf-dir /root/.aria2 --downloads /data/downloads --aria2c /usr/local/bin/aria2c
```

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `--src` | 项目源目录 | 脚本所在目录 |
| `--conf-dir` | 配置/数据目录 | `/root/.aria2` |
| `--downloads` | 下载目录 | `/root/downloads` |
| `--aria2c` | aria2c 安装路径 | `/usr/local/bin/aria2c` |

环境变量：`ARIA2_CONF_DIR`、`DOWNLOAD_PATH`、`ARIA2C`、`INSTALL_SRC`。

检测到已存在 `/etc/init.d/aria2` 时**保留 init.d 管理方式**并自动打补丁（避免与 systemd unit 产生两个竞争的服务定义）。

安装过程会：安装依赖 → 下载 1.37.0 静态二进制 → 部署配置与钩子 → 重写配置中的路径 → 生成随机 RPC 密钥 → 安装服务单元 → 创建下载目录。

### 安装后验证

```bash
systemctl start aria2
systemctl status aria2                                    # active (running)
/usr/local/bin/aria2c --version | head -1                 # aria2 version 1.37.0
grep -E "on-download-complete|on-download-stop" /root/.aria2/aria2.conf   # 钩子路径已指向 /root/.aria2/hooks/
tail -5 /root/.aria2/aria2.log                            # 无 Unknown option / Parse error
```

### 从旧版 P3TERX 脚本迁移

```bash
bash bin/aria2.sh        # 选 3 卸载旧版(会清理 /root/.aria2c 与 init.d)
bash install.sh          # 安装 aria2-pro
```

旧配置会备份为 `.orig`，不会直接删除。

---

## 使用

```bash
systemctl start aria2      # 启动
systemctl enable aria2     # 开机自启
systemctl status aria2     # 状态
bash bin/aria2.sh          # 交互式管理面板
```

管理面板功能：升级脚本、安装/更新/卸载、启停重启、修改密钥/端口/目录、查看配置与日志、BT-Tracker 手动/自动更新。

面板菜单：

```
 0. 升级脚本          7. 修改 配置
 1. 安装 Aria2        8. 查看 配置
 2. 更新 Aria2        9. 查看 日志
 3. 卸载 Aria2       10. 清空 日志
 4. 启动 Aria2       11. 手动更新 BT-Tracker
 5. 停止 Aria2       12. 自动更新 BT-Tracker
 6. 重启 Aria2
```

### RPC 密钥与端口

安装时自动生成随机密钥，保存在 `conf/aria2.conf`：

```bash
grep '^rpc-secret' /root/.aria2/aria2.conf      # 查看(默认不对外暴露)
```

修改密钥 / 端口（会同步更新 iptables 并重启服务）：

```bash
bash bin/aria2.sh    # 7 → 1(密钥) / 2(端口) / 3(下载目录) / 4(全部)
```

RPC 默认端口 `6800`。密钥避免包含 `=` 和 `#`。

### 连接 AriaNg

```bash
bash bin/aria2.sh    # 8 查看配置 → 输出 AriaNg 一键链接
```

也可手动填写：地址 = 服务器 IP，端口 = `rpc-listen-port`，密钥 = `rpc-secret`。

常见 Web 前端：

- [AriaNg](https://github.com/mayswind/AriaNg) — 纯静态，`http://ariang.js.org`
- [ariang](https://github.com/P3TERX/ariang) — 同上
- [WebUI-Aria2](https://github.com/ziahamza/webui-aria2) — Node 实现

若 RPC 无法连接，检查：`rpc-listen-all=true` 是否开启、防火墙是否放行端口、`rpc-secret` 是否填写正确。

---

## 目录结构

安装后：

```
/root/.aria2/
├── aria2.conf          # aria2 配置(适配 1.37)
├── script.conf         # 钩子行为配置(上传/移动/删除/清理/过滤)
├── rclone.env          # rclone 环境变量
├── aria2.session       # 会话文件
├── aria2.log           # 日志
├── hooks.log           # 钩子专用日志
├── dht.dat / dht6.dat  # DHT 路由表
├── tracker-update.sh   # BT-Tracker 更新工具
└── hooks/
    ├── core            # 共享函数库
    ├── clean.sh        # 下载完成 → 清理
    ├── upload.sh       # 下载完成 → 上传网盘
    ├── move.sh         # 下载完成 → 移动到其他目录
    └── delete.sh       # 下载停止/出错 → 删除
```

aria2.conf 中的钩子绑定：

```ini
on-download-complete      = /root/.aria2/hooks/clean.sh
on-bt-download-complete   = /root/.aria2/hooks/clean.sh
on-download-stop          = /root/.aria2/hooks/delete.sh
on-download-error         = /root/.aria2/hooks/delete.sh
```

---

## 上传到网盘（upload.sh）

`script.conf`：

```ini
drive-name=OneDrive
drive-dir=/Backup/Downloads
rclone-transfers=4
rclone-checkers=8
```

行为：**`rclone copy` → `rclone check` 哈希校验 → 校验通过才删本地**。

与上游的关键差异：上游用 `rclone move`，上传一开始就搬走本地数据，一旦失败（或上传不完整）数据处于不一致状态。本实现保证本地数据只在远端**确认完整**后才删除。

自动重试 3 次，退避 5s / 10s / 15s，失败时保留本地并返回非零退出码。

---

## 文件过滤

仅对多文件任务（`FILE_NUM > 1`）生效：

```ini
min-size=10M                                   # 删除小于 10M 的文件
include-file=mp4|mkv|rmvb|mov|avi              # 只保留这些类型
exclude-file=html|url|lnk|txt|jpg|png|nfo      # 删除这些类型
include-file-regex=                            # 保留正则
exclude-file-regex="(.*/)_+(padding)(_*)(file)(.*)(_+)"
```

已加防护：目标路径必须存在且为目录，拒绝空路径 / `/` / 下载根目录。

---

## BT-Tracker

主源：**https://cf.trackerslist.com/best.txt**（Cloudflare CDN）

```bash
bash bin/aria2.sh         # 11 = 手动更新, 12 = 自动更新(每日 7:00  cron)
```

或直接调用（可指定配置文件路径）：

```bash
bash bin/tracker-update.sh /root/.aria2/aria2.conf
bash bin/tracker-update.sh --test        # 测速所有源, 不写入配置
```

`tracker-update.sh` 依次尝试 5 个源并合并去重（主源优先）：

| 源 | 说明 |
|----|------|
| `https://cf.trackerslist.com/best.txt` | **主源**，Cloudflare CDN，~70 条 |
| `https://cf.trackerslist.com/all.txt` | 全量列表，~120 条 |
| `https://raw.githubusercontent.com/XIU2/TrackersListCollection/master/best.txt` | 备用 |
| `https://trackerslist.com/best.txt` | 备用（与主源同内容） |
| `https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt` | 最低优先级（已过时，仅 20 条） |

实测聚合后约 122 个去重 tracker。协议覆盖 `udp` / `http` / `https` / `wss`（WebTorrent）。

写入使用 `awk` 而非 `sed`——tracker 列表含大量正则元字符（`/` `:` `.` `-`），用 `sed` 做替换会解析失败。

---

## 安全防护

hooks 中所有破坏性操作（`rm -rf`）都经过两道检查：

- `require_path`：拒绝空路径、`/`、`.`
- `is_safe_to_delete`（delete.sh）：拒绝删除包含 aria2 下载根目录的路径

```bash
$ is_safe_to_delete /tmp/e2e/downloads       # 下载根
Refusing to delete '/tmp/e2e/downloads': it contains the aria2 download root.

$ is_safe_to_delete /root                   # 根的祖先
Refusing to delete '/root': it contains the aria2 download root.

$ is_safe_to_delete /tmp/e2e/downloads/movies
(通过)
```

尾部斜杠会被规范化，`/data/dl/` 与 `/data/dl` 等价判定。

---

## 卸载

```bash
bash bin/aria2.sh    # 选 3
```

会移除：二进制、配置目录、hooks、init.d / systemd unit、crontab 中的 tracker 任务、iptables 规则并 `daemon-reload`。

---

## 日志与排查

```bash
tail -f /root/.aria2/aria2.log      # aria2 主日志(warn 级别)
tail -f /root/.aria2/hooks.log      # 钩子日志(清理/上传/删除的详细过程)
```

`log-level=warn` 是默认值，只记录警告与错误。需要更详细输出时改为 `notice` 或 `info`。

常见输出：

```
[INFO] Cleanup finished.                                        # 钩子正常完成
[INFO] Not a BitTorrent task, skipping .torrent handling.       # HTTP 下载, 无种子
[WARNING] RPC unavailable, skipping .torrent cleanup this run.  # aria2 繁忙, 降级跳过种子清理
[ERROR] Upload failed (local files kept): /path                 # 上传失败, 本地已保留
```

---

## FAQ

**Q: 安装后 aria2 无法启动，日志报 `Unknown option`？**
`aria2.conf` 中存在 aria2 1.37 已移除的选项。本项目配置已逐项针对 1.37.0 校验。若你手动加过 `retry-on-400` / `retry-on-403` / `retry-on-406` / `retry-on-unknown` / `bt-lpd-port` / `dht-listen-port6`，请删除它们——这些都不是有效的 aria2 选项名。

**Q: 下载速度慢 / BT 没速度？**
更新 tracker：`bash bin/aria2.sh` → 11。或开启自动更新（12）。同时确认 `enable-dht=true`、`listen-port` 端口已在防火墙放行。

**Q: 上传到网盘失败？**
先单独测试 rclone 连通性：`bash /root/.aria2/hooks/upload.sh`（无参数时只做连接检查）。失败会保留本地文件，不会丢数据。

**Q: 多文件 BT 任务下载完成，但小文件/广告文件还在？**
在 `script.conf` 启用过滤（`min-size` / `include-file` / `exclude-file`）。注意过滤只对 `FILE_NUM > 1` 的多文件任务生效。

**Q: 钩子没有执行？**
1. 检查钩子是否有可执行权限：`ls -l /root/.aria2/hooks/*.sh`
2. 检查 `aria2.conf` 中 `on-download-complete` 路径是否为**绝对路径**且指向实际位置
3. 查看 `hooks.log` 是否有记录

**Q: 如何指定 aria2 以非 root 用户运行？**
`install.sh --conf-dir <dir>` 时把 `<dir>` 设为该用户可写目录，并自行调整 systemd unit 的 `User=`。钩子脚本中的路径均为绝对路径，无硬编码 root。

**Q: 支持哪些架构？**
x86_64、aarch64/arm64、armv7、i686/i386、loongarch64。由 `abcfy2/aria2-static-build` 提供静态 musl 构建，无外部动态库依赖。

---

## 上游致谢

- [P3TERX/aria2.sh](https://github.com/P3TERX/aria2.sh) — 一键安装管理脚本
- [P3TERX/aria2.conf](https://github.com/P3TERX/aria2.conf) — Aria2 完美配置方案
- [abcfy2/aria2-static-build](https://github.com/abcfy2/aria2-static-build) — 提供 aria2 静态构建
- [aria2](https://github.com/aria2/aria2) — 下载工具本体

---

## 已验证环境

- **Oracle Cloud ARM (aarch64)**，Ubuntu 24.04， aria2 **1.37.0**（静态 musl 构建）
- 配置逐项校验：`aria2.conf` 全部选项对 1.37.0 有效，无 `Unknown option`
- 端到端实测：真实 HTTP 下载（10MB）→ 钩子自动触发 → `.aria2` / 空目录清理，日志零 ERROR
- 上传链路：`copy → check → 删除本地`，含校验失败时**本地数据保留**验证、4 次尝试退避 5/10/15s
- init.d 僵尸进程误判已复现并修复；systemd 与 init.d 两种服务管理方式均验证
- 安全防护实测：拒绝空路径 / `/` / 下载根目录 / 带尾斜杠的等价路径

---

## License

MIT（继承上游 P3TERX 项目）
