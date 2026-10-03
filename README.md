# aria2-pro

面向 **aria2 1.37.0** 的一键安装 / 管理 / 后处理方案。

- **运行期零第三方脚本依赖**：不下载、不执行任何外部 shell 脚本，init.d 服务脚本与 Tracker 更新工具全部内嵌在仓库中
- 二进制源：[abcfy2/aria2-static-build](https://github.com/abcfy2/aria2-static-build)
- 支持架构：x86_64、aarch64/arm64、armv7、i686/i386、loongarch64
- 许可：MIT

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

也支持环境变量 `ARIA2_CONF_DIR`、`DOWNLOAD_PATH`、`ARIA2C`、`INSTALL_SRC`。

安装流程：安装依赖 → 下载 1.37.0 静态二进制 → 部署配置与钩子 → 重写配置中的路径 → 生成随机 RPC 密钥 → 安装服务 → 创建下载目录。

服务管理自动选择：已有 `/etc/init.d/aria2` 则沿用 init.d 并替换为仓库自带版本；否则有 systemd 装 systemd 单元；无 systemd 装 init.d。

安装后验证：

```bash
systemctl start aria2
systemctl status aria2                                   # active (running)
/usr/local/bin/aria2c --version | head -1                 # aria2 version 1.37.0
grep -E "on-download-complete|on-download-stop" /root/.aria2/aria2.conf
tail -5 /root/.aria2/aria2.log                            # 应无 Unknown option / Parse error
```

---

## 使用

```bash
systemctl start aria2      # 启动
systemctl enable aria2     # 开机自启
systemctl status aria2     # 状态
bash bin/aria2.sh          # 交互式管理面板
```

管理面板菜单：

```
 0. 升级脚本          7. 修改 配置
 1. 安装 Aria2        8. 查看 配置
 2. 更新 Aria2        9. 查看 日志
 3. 卸载 Aria2       10. 清空 日志
 4. 启动 Aria2       11. 手动更新 BT-Tracker
 5. 停止 Aria2       12. 自动更新 BT-Tracker
 6. 重启 Aria2
```

**RPC 密钥与端口** — 安装时随机生成，保存在 `/root/.aria2/aria2.conf`。修改用面板 7 → 1/2/3/4，会自动同步 iptables 并重启。密钥可含 `=`、`#`、空格等特殊字符（配置读写均按原文处理，不会截断或转义）。

**连接 AriaNg** — 面板选 8 会输出一键链接；或手动填：服务器 IP + `rpc-listen-port` + `rpc-secret`。可用 [AriaNg](http://ariang.js.org) 或 WebUI-Aria2。连不上时检查 `rpc-listen-all=true`、防火墙、密钥是否正确。

---

## 卸载

```bash
bash bin/aria2.sh    # 选 3
```

移除：二进制、配置目录、hooks、init.d / systemd unit、crontab 中的 tracker 任务、iptables 规则，并执行 `daemon-reload`。

---

## 脚本功能说明

| 脚本 | 触发时机 | 功能 |
|------|----------|------|
| `hooks/clean.sh` | 下载完成 | 清理 `.aria2` 控制文件、孤种 `.torrent`、空目录 |
| `hooks/upload.sh` | 下载完成 | 上传到网盘（需自行把完成钩子改为它） |
| `hooks/move.sh` | 下载完成 | 移动到本地其他目录（需自行改钩子） |
| `hooks/delete.sh` | 下载停止/出错 | 任务状态为 error/removed 时删除对应文件（含下载根目录防护，绝不删到根） |
| `hooks/core` | 被上面调用 | 共享函数库：路径推导、配置解析、RPC、安全防护 |

默认钩子绑定（`aria2.conf`）：

```ini
on-download-complete      = /root/.aria2/hooks/clean.sh
on-bt-download-complete   = /root/.aria2/hooks/clean.sh
on-download-stop          = /root/.aria2/hooks/delete.sh
on-download-error         = /root/.aria2/hooks/delete.sh
```

**安全防护** — 所有 `rm -rf` 前有两道检查：拒绝空路径 / `/` / `.`，以及拒绝删除包含下载根目录的路径（防误删整个下载目录）。尾部斜杠会被规范化，`/data/dl/` 与 `/data/dl` 等价判定。

---

## 仓库结构

```
aria2-pro/
├── install.sh              一键安装
├── bin/
│   ├── aria2.sh            交互式管理面板
│   └── tracker-update.sh   BT-Tracker 更新
├── conf/
│   ├── aria2.conf          aria2 配置(已针对 1.37.0 逐项校验)
│   ├── script.conf         钩子行为配置
│   └── rclone.env          rclone 环境变量
├── hooks/
│   ├── core                共享函数库
│   ├── clean.sh            下载完成 → 清理
│   ├── upload.sh           下载完成 → 上传网盘
│   ├── move.sh             下载完成 → 移动目录
│   └── delete.sh           下载停止/出错 → 删除
├── service/
│   ├── aria2_debian        init.d 服务脚本
│   └── aria2_centos        init.d 服务脚本(CentOS)
├── README.md
└── LICENSE
```

安装后的运行目录：

```
/root/.aria2/
├── aria2.conf          aria2 配置
├── script.conf         钩子行为配置
├── rclone.env          rclone 环境变量
├── aria2.session       会话文件
├── aria2.log           aria2 主日志
├── hooks.log           钩子日志
├── tracker-update.sh   BT-Tracker 更新工具
└── hooks/              钩子脚本
```

init.d 已内置：僵尸进程排除、按 `--conf-path` 精确匹配本实例（同机多实例不误杀）、`stop` 等待真正退出、`start` 轮询就绪替代固定 `sleep 2s`。

---

## BT-Tracker

主源 **https://cf.trackerslist.com/best.txt**（Cloudflare CDN）。

```bash
bash bin/tracker-update.sh /root/.aria2/aria2.conf   # 更新
bash bin/tracker-update.sh --test                    # 测速各源, 不写入
bash bin/aria2.sh                                    # 11 手动 / 12 自动(每日 7:00 cron)
```

自动更新通过 cron 实现，写入：

```
0 7 * * * /bin/bash /root/.aria2/tracker-update.sh 2>&1 | tee /root/.aria2/tracker.log # aria2-pro:tracker-update
```

依次尝试 4 个源并合并去重（主源优先），实测约 122 个去重 tracker，覆盖 `udp` / `http` / `https` / `wss`：

| 源 | 说明 |
|----|------|
| `https://cf.trackerslist.com/best.txt` | 主源，71 条 |
| `https://cf.trackerslist.com/all.txt` | 全量，122 条 |
| `https://raw.githubusercontent.com/XIU2/TrackersListCollection/master/best.txt` | 备用 |
| `https://trackerslist.com/best.txt` | 备用（与主源同内容） |

写入用 `awk` 而非 `sed`——tracker 列表含大量正则元字符，`sed` 替换会失败。同时若 aria2 正在运行，脚本会自动通过 JSON-RPC 调用 `aria2.changeGlobalOption` 热加载 tracker 列表，无需重启服务。crontab 删除时按 `aria2-pro:tracker-update` 标记精确匹配，不会误删你自己的其他任务。

不需要 `dht.dat`：aria2 的 DHT 路由表仅存内存，且 1.37 没有 `dht-file-path` 配置项。

---

## 上传网盘

在 `script.conf` 中配置：

```ini
drive-name=OneDrive                    # rclone 配置中的 name
drive-dir=/Backup/Downloads            # 网盘目标目录, 留空为根目录
rclone-transfers=4                     # 并发传输数
rclone-checkers=8                      # 并发检查数
```

然后把 `aria2.conf` 的完成钩子改为 `upload.sh`：

```ini
on-download-complete = /root/.aria2/hooks/upload.sh
```

行为：**`rclone copy` → `rclone check` 哈希校验 → 校验通过才删本地**。共 4 次尝试（首次 + 3 次重试），退避 5s / 10s / 15s；全部失败时保留本地文件并返回非零退出码。日志写入 `upload-log` 指定路径。

先单独测试连通性（不带参数运行时只做连接检查）：

```bash
bash /root/.aria2/hooks/upload.sh
```

若想改为「上传后移动」而非「上传后删除」，用 `rclone move` 替换 `hooks/upload.sh` 中的 `rclone copy` 并删去后续校验段即可，但不建议——校验失败时本地数据已丢失。

---

## 文件过滤

仅对多文件任务（`FILE_NUM > 1`）生效，在 `script.conf` 中配置：

```ini
min-size=10M                                   # 删除小于 10M 的文件
include-file=mp4|mkv|rmvb|mov|avi              # 只保留这些类型
exclude-file=html|url|lnk|txt|jpg|png|nfo      # 删除这些类型
include-file-regex=                            # 保留正则
exclude-file-regex="(.*/)_+(padding)(_*)(file)(.*)(_+)"
```

防护：目标路径必须存在且为目录，拒绝空路径 / `/` / 下载根目录。

---

## 日志与排查

```bash
tail -f /root/.aria2/aria2.log      # aria2 主日志
tail -f /root/.aria2/hooks.log      # 钩子日志(清理/上传/删除的详细过程)
tail -f /root/.aria2/tracker.log    # Tracker 自动更新日志
```

`log-level=warn` 为默认值，只记录警告与错误。需要更详细输出改为 `notice` 或 `info`。

常见日志输出：

```
[INFO] Cleanup finished.                                       # 钩子正常完成
[INFO] Not a BitTorrent task, skipping .torrent handling.      # HTTP 下载, 无种子
[WARNING] RPC unavailable, skipping .torrent cleanup this run. # aria2 繁忙, 降级跳过
[ERROR] Upload failed (local files kept): /path                # 上传失败, 本地已保留
```

常见问题：

| 现象 | 排查 |
|------|------|
| aria2 启动即退出，日志报 `Unknown option` | 手动加过 `retry-on-400/403/406/unknown`、`bt-lpd-port`、`dht-listen-port6` 之一，删除它们——都不是有效选项名 |
| BT 没速度 | 更新 tracker（面板 11/12）；防火墙放行 `listen-port`(TCP) 与 `dht-listen-port`(UDP) 整段范围；冷启动 DHT 需几分钟建连 |
| 上传网盘失败 | 单独跑 `bash /root/.aria2/hooks/upload.sh` 测连通性；多数是 `drive-name` 与 rclone 实际 name 不一致 |
| 钩子没执行 | `ls -l /root/.aria2/hooks/*.sh` 查可执行权限；确认 `aria2.conf` 里钩子是绝对路径；看 `hooks.log` |
| 小文件/广告没被删 | 过滤只对 `FILE_NUM > 1` 的多文件任务生效 |

---

## License

MIT
