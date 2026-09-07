# ruijie-eportal-autologin

[![CI](https://github.com/stilesloveland-cyber/ruijie-eportal-autologin/actions/workflows/ci.yml/badge.svg)](https://github.com/stilesloveland-cyber/ruijie-eportal-autologin/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

锐捷 ePortal 校园网自动认证脚本 —— 一次配置，永久在线。

适用于任何运行 Linux 的设备（OpenWrt/LEDE 路由器、树莓派、NAS、家用小主机、任意 Linux 服务器/PC），自动完成锐捷 ePortal Web 认证并持续保活，告别每次掉线手动登录。

> 本项目开发与验证于 OpenWrt 环境，协议逻辑来自浏览器认证流程还原。

## ✨ 特性

- **纯 Shell 实现**：仅依赖 `bash` `curl` `openssl`，无编译、无 Python、无 Node
- **交互式配置向导**：`--setup` 问答式完成配置，自动探测学校门户、自动抓取运营商列表，全程无需编辑文件、无需理解 URL 编码
- **跨学校自动适配**：通过门户劫持探测自动识别其他学校的锐捷 ePortal 服务器，实时抓取该校运营商/套餐列表
- **设备无关**：x86_64 / ARM / MIPS 通用，OpenWrt、Debian、Ubuntu、Armbian 等均可
- **免 root 可用**：无 root 权限时自动降级到用户目录运行
- **断电自恢复**：单实例锁带 PID 探活，断电/SIGKILL 残留锁自动接管，不会卡死
- **失败指数退避**：认证失败时间隔 60→120→240→480→900s 递增，防止密码错误高频撞库触发账号锁定
- **自动探测出口网卡**：默认按默认路由自动识别 WAN 口，也可手动指定
- **日志自动轮转**：超过 512KB 自动轮转，不会吃满内存盘/磁盘
- **一键安装**：自动识别 OpenWrt procd / systemd / cron 并注册开机自启
- **安全细节**：配置文件权限 600，登录请求体经 stdin 传递（不出现在 `ps` 进程列表），`--status` 输出自动打码

## 🔐 工作原理

认证流程还原自浏览器行为，共 8 步：

1. 访问 ePortal 首页，从 302 重定向中获取 `queryString`（含 `wlanuserip` / `wlanacname` / `nasip` / `mac` 等门户参数）
2. 携带 `queryString` 访问 `index.jsp` 建立会话并保存 Cookie
3. 调用 `pageInfo` 接口获取 RSA 公钥（模数 + 指数）
4. 将 `密码>MAC地址` 反转后使用 RSA 无填充加密（128 字节分块、零填充）
5. 双重 URL 编码后提交 `login` 接口
6. 保存返回的 `userIndex` 会话凭据
7. 对 `result=wait` 轮询直到服务器同步完成
8. 通过 `userIndex` 查询在线状态确认认证成功

watchdog 默认每 60 秒执行一次上述检查，已在线则直接跳过；失败时指数退避。

## 📦 环境要求

| 依赖 | 用途 | 安装 |
|---|---|---|
| bash | 脚本运行时 | OpenWrt: `opkg install bash`；Debian/Ubuntu: 自带 |
| curl | HTTP 请求 | `opkg install curl` / `apt install curl` |
| openssl | RSA 加密 | `opkg install openssl-util` / `apt install openssl` |
| iproute2 | 自动探测网卡（可选） | `opkg install ip` / `apt install iproute2` |

## 🚀 快速开始

### 方式一：一键安装（推荐）

```sh
git clone https://github.com/stilesloveland-cyber/ruijie-eportal-autologin.git
cd ruijie-eportal-autologin
sudo ./install.sh
```

安装器会自动复制脚本、注册服务，并进入配置向导（小白只需跟着菜单走）：

```text
====== ePortal 配置向导 ======
正在探测校园网门户 (1/4)...
✅ 自动识别到锐捷 ePortal 服务器: http://210.27.177.172
使用该服务器? [Y/n]: y
正在获取本校运营商/套餐列表...
检测到以下运营商/套餐:
  1) 校园联通
  2) 校园移动
请选择 [1]: 1
请输入学号: 2023xxxx
请输入密码: ******
请再次输入密码: ******
出口网卡 [回车默认 auto 自动探测]:
✅ 配置已保存: /etc/eportal/eportal.conf (权限 600)
```

配置完成并自检通过后，服务自动启动。

### 方式二：免安装直接运行

```sh
git clone https://github.com/stilesloveland-cyber/ruijie-eportal-autologin.git
cd ruijie-eportal-autologin
./eportal-auth.sh --setup     # 向导生成 eportal.conf
./eportal-auth.sh --check     # 环境自检
./eportal-auth.sh             # 认证一次
./eportal-watchdog.sh         # 前台循环保活
```

### 方式三：cron 托管

```sh
# 每分钟检查一次，已在线则跳过
(crontab -l 2>/dev/null; echo '* * * * * /usr/bin/eportal-auth.sh') | crontab -
```

## 🛠 常用命令

| 命令 | 说明 |
|---|---|
| `eportal-auth.sh --setup` | 交互式配置向导（重新配置/换套餐也用它） |
| `eportal-auth.sh --check` | 环境自检：配置/依赖/网卡/服务器连通性 |
| `eportal-auth.sh --status` | 在线状态 + 配置摘要（密码打码）+ 最近日志 |
| `eportal-auth.sh` | 执行一次认证检查 |
| `FORCE_AUTH=1 eportal-auth.sh` | 跳过在线检查，强制重新登录 |

## ⚙️ 配置说明

配置文件位置：root 安装为 `/etc/eportal/eportal.conf`，免 root 为 `~/.eportal/eportal.conf`（或脚本同目录）。

| 配置项 | 必填 | 默认值 | 说明 |
|---|---|---|---|
| `EP_USER` | 是 | — | 认证账号（学号） |
| `EP_PASS` | 是 | — | 认证密码（避免 `& = %` 空格） |
| `EP_SERVER` | 是 | 模板预填 | ePortal 服务器地址 |
| `WAN_IF` | 否 | `auto` | 出口网卡；`auto` = 默认路由探测 |
| `SERVICE_NAME` | 否 | 校园联通 | 认证服务名（双重 URL 编码）；向导中直接输明文套餐名即可，脚本自动编码 |
| `STATE_DIR` | 否 | `auto` | 状态目录；`auto` = `/var/lib/eportal`，不可写时降级 `~/.eportal` |
| `LOG_FILE` | 否 | `auto` | 日志文件；`auto` = `$STATE_DIR/eportal.log` |
| `CHECK_INTERVAL` | 否 | `60` | watchdog 检测间隔（秒），失败时自动指数退避 |

高级用法（环境变量，优先级高于配置文件）：

```sh
EPORTAL_CONF=/path/to/eportal.conf ./eportal-auth.sh   # 指定配置文件
FORCE_AUTH=1 ./eportal-auth.sh                          # 强制重新登录
EP_USER=xxx EP_PASS=yyy ./eportal-auth.sh               # 临时覆盖配置
```

## 🏫 适配其他学校

只要认证页是锐捷 ePortal（浏览器地址栏含 `/eportal/index.jsp`）即可尝试：

1. 设备接入校园网（**保持未认证状态**，向导探测效果最佳）
2. 运行 `--setup`，向导自动探测门户服务器并抓取该校运营商列表
3. 自动探测失败时回退手动输入：从浏览器认证页地址栏复制 `协议://IP或域名` 部分填入服务器；运营商选择“其他（手动输入名称）”，输入认证页上显示的套餐明文名称即可（无需编码）

已知边界：已认证状态的设备探测不到登录页（属正常现象），此时手动输入即可；在线抓取运营商列表失败时回退预设+手动输入，不影响使用。

## 📋 服务管理

| 操作 | OpenWrt | systemd |
|---|---|---|
| 启动 | `/etc/init.d/eportal start` | `systemctl start eportal` |
| 停止 | `/etc/init.d/eportal stop` | `systemctl stop eportal` |
| 重启 | `/etc/init.d/eportal restart` | `systemctl restart eportal` |
| 开机自启 | `/etc/init.d/eportal enable` | `systemctl enable eportal` |
| 状态 | `logread \| grep eportal` | `systemctl status eportal` |

更新版本：`git pull && sudo ./install.sh`（自动停止旧进程、替换文件、重启服务，配置保留）。

卸载：`sudo ./install.sh --uninstall`（保留配置文件）。

## 📋 日志与排障

日志位置：root 安装为 `/var/lib/eportal/eportal.log`，免 root 为 `~/.eportal/eportal.log`（超过 512KB 自动轮转）。

日志样例（含网卡、IP、服务器、接口）：

```text
2026-09-06 08:00:00 ===== 运行 ===== 网卡=eth0 IP=10.1.2.3 服务器=http://210.27.177.172
2026-09-06 08:00:00 在线检查 (getOnlineUserInfo): 网卡=eth0 IP=10.1.2.3 服务器=http://210.27.177.172
2026-09-06 08:00:01 ⚠️ 未认证，开始登录
2026-09-06 08:00:01 探测登录参数 (首页重定向): 服务器=http://210.27.177.172 网卡=eth0
2026-09-06 08:00:01 建立会话 (index.jsp): 服务器=http://210.27.177.172
2026-09-06 08:00:01 获取公钥 (pageInfo): 服务器=http://210.27.177.172
2026-09-06 08:00:02 公钥: exp=10001 mod长度=256
2026-09-06 08:00:02 提交登录 (login): 网卡=eth0 IP=10.1.2.3 服务器=http://210.27.177.172
2026-09-06 08:00:03 login 响应: {"result":"success","userIndex":"..."}
2026-09-06 08:00:03 已保存 userIndex
2026-09-06 08:00:03 ✅ 认证成功
```

常见问题：

| 现象 | 可能原因 | 处理 |
|---|---|---|
| `--check` 提示无法访问服务器 | 设备不在校园网 / EP_SERVER 配错 | 接入校园网后重试，或修改 EP_SERVER |
| `--check` 提示无法探测出口网卡 | 未装 iproute2 | `opkg install ip` / `apt install iproute2`，或手动设置 WAN_IF |
| login 响应密码错误 | 账号/密码错误，或密码含 `& = %` 空格 | 核对配置；建议修改校园网密码避开特殊字符（连续失败已自动退避，防账号锁定） |
| 向导提示识别到非锐捷门户 | 学校用的是深澜(srun)/Dr.COM 等其他认证系统 | 本脚本不支持，需要对应的认证脚本 |
| 向导探测不到门户 | 设备已认证（正常）或不在校园网 | 手动输入服务器地址 |
| 向导未抓到运营商列表 | 设备已认证拿不到登录页 | 选择“其他（手动输入名称）”，输入认证页上的套餐明文名 |
| 一直提示未认证但实际能上网 | userIndex 缓存与服务器不同步 | `FORCE_AUTH=1 ./eportal-auth.sh` 强制重登 |
| 60s 重探仍无完整登录参数 | 已在线（无门户重定向）或不在校园网 | 能上网则无需处理；否则检查网络 |
| RSA 加密失败 | openssl 缺失或版本异常 | 安装/更新 openssl 后重试（脚本自动兼容 OpenSSL 3.x 与旧版） |

## 🧪 测试

```sh
bash tests/test-basic.sh
```

覆盖：全部脚本语法检查、配置校验分支、编码行为快照（保护已验证的协议逻辑）、向导冒烟测试、门户探测/运营商解析单测、断电锁接管、日志轮转、退避计算。CI（GitHub Actions）在每次 push 时自动运行 ShellCheck + 测试。

## 📄 免责声明

本项目仅供学习研究与个人自有校园网账号的自动认证用途。请遵守所在学校网络使用规定，不得用于绕过计费策略、共享账号等违规用途。使用本脚本产生的一切后果由使用者自行承担。

## 📜 许可证

[MIT](LICENSE)
