# TrafficGuard

基于内核级 nftables 防火墙 + Fail2Ban 的轻量级流量监控和 IP 封禁工具。

**版本**: 1.3.0 | **许可证**: MIT

---

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/Sgraqwq/TrafficGuard/main/scripts/install.sh | sudo bash
```

## 一键卸载

```bash
curl -fsSL https://raw.githubusercontent.com/Sgraqwq/TrafficGuard/main/scripts/uninstall.sh | sudo bash
```

---

## 功能

- **并发连接限制** — 单 IP 最大并发连接数限制（内核级丢包）
- **速率限制** — 单 IP 每秒新建连接数限制（内核级丢包）
- **自动封禁** — 超限自动封禁，支持白名单豁免
- **流量监控** — 按 IP 查看实时/历史流量，入站/出站分别统计
- **流量自动查杀** — 单 IP 日流量超限自动封禁
- **SSH 防护** — 基于 Fail2Ban，自动检测和封禁 SSH 爆破
- **白名单管理** — 全局白名单，开机自动恢复
- **热更新** — 在线检查更新，静默升级，保留配置和封禁记录
- **数据持久化** — 原子写入 + 并发锁保护，崩溃不丢数据
- **开机自恢复** — systemd service + crontab 双保险

---

## 架构

```
TrafficGuard
├── nftables               # 内核级网络层防护（连接/速率限制 + 流量统计）
│   ├── TRAFFICGUARD       # input hook，入站流量处理
│   └── TRAFFICGUARD_OUT   # output hook，出站流量统计
├── Fail2Ban               # SSH 防护及持久化封禁（SQLite 后端）
├── tgctl                  # 交互式管理工具（CLI + 菜单）
├── traffic-monitor        # 流量统计保存与查询脚本
├── systemd service        # 开机恢复 trafficguard-restore.service
└── logrotate              # 日志轮转配置（保留 90 天）
```

---

## 安装

```bash
sudo bash scripts/install.sh
```

安装流程：
1. 检测系统环境（init 系统、防火墙后端、Fail2Ban 版本）
2. 自动安装依赖（nftables + Fail2Ban）
3. 生成防火墙配置，交互式设置 SSH 端口
4. 配置 Fail2Ban jail（SSH 防护 + recidive 持久封禁）
5. 部署 tgctl 管理工具和流量统计脚本
6. 设置 crontab（每小时流量统计 + 每日清理 90 天前旧数据）
7. 配置 logrotate（运行日志 30 天，流量数据 90 天）
8. 创建 nftables 规则链（白名单 → 黑名单 → 流量统计 → 限流）
9. 注册 systemd 开机自恢复服务

---

## 快速开始

### tgctl 管理工具

```bash
# 交互式管理界面
sudo tgctl

# CLI 命令
sudo tgctl status              # 查看状态
sudo tgctl list                # 查看封禁列表
sudo tgctl ban 1.2.3.4         # 封禁 IP
sudo tgctl unban 1.2.3.4       # 解封 IP
sudo tgctl traffic             # 实时流量统计
sudo tgctl history             # 历史流量
sudo tgctl ssh                 # SSH 防护
sudo tgctl whitelist           # 白名单管理
sudo tgctl config              # 配置管理
sudo tgctl service             # 服务管理
sudo tgctl update              # 检查更新
sudo tgctl restore             # 恢复防火墙规则（开机自动执行）
sudo tgctl uninstall           # 完全卸载
sudo tgctl version             # 显示版本
```

### 交互菜单

```
╔══════════════════════════════════════════════════════════╗
║              TrafficGuard - 流量监控和 IP 封禁管理工具    ║
╠══════════════════════════════════════════════════════════╣
║   1) 查看状态                                            ║
║   2) 查看封禁列表                                        ║
║   3) 封禁 IP                                             ║
║   4) 解封 IP                                             ║
║   5) 查看流量统计                                        ║
║   6) 查看历史流量                                        ║
║   7) SSH 防护                                            ║
║   8) 配置管理                                            ║
║   9) 服务管理                                            ║
║  10) 白名单管理                                          ║
║  11) 检查更新                                            ║
║  12) 卸载 TrafficGuard                                   ║
║   0) 退出                                                ║
╚══════════════════════════════════════════════════════════╝
```

---

## 流量监控

### 实时流量

```bash
sudo tgctl traffic
# 或 tgctl 菜单 → 5) 查看流量统计
```

### 历史流量

```bash
# 查看今天流量
sudo traffic-view-stats -t

# 查看指定日期
sudo traffic-view-stats -d 20260701

# 查看流量汇总
sudo traffic-view-stats -s

# 实时查看
sudo traffic-view-stats -r
```

### 手动保存流量统计

```bash
sudo traffic-save-stats
```

流量统计每小时由 crontab 自动保存，数据保存在 `/var/lib/trafficguard/stats/`，保留 90 天。

---

## SSH 防护

基于 Fail2Ban，安装后默认启用，3 次失败登录自动封禁 1 小时。

```bash
# 查看 SSH 防护状态
sudo fail2ban-client status sshd

# 手动封禁
sudo fail2ban-client set sshd banip 1.2.3.4

# 查看 SSH 失败登录
grep "Failed password" /var/log/auth.log | tail -20
```

### Recidive 规则

对 1 天内被封禁 5 次以上的 IP，实施 1 周长封禁。

---

## 数据持久化

| 数据 | 存储位置 | 保护机制 |
|---|---|---|
| IP 白名单 | `/etc/trafficguard/whitelist.txt` | 原子写入（mktemp + mv） |
| IP 黑名单 | `/etc/trafficguard/manual_banned.txt` | 原子写入（mktemp + mv） |
| 流量统计 | `/var/lib/trafficguard/stats/traffic_*.log` | logrotate 轮转，保留 90 天 |
| 配置 | `/etc/trafficguard/trafficguard.conf` | 安装时一次性写入 |
| Fail2Ban 封禁 | `/var/lib/fail2ban/fail2ban.sqlite3` | Fail2Ban 原生 SQLite |
| 运行日志 | `/var/log/trafficguard/` | logrotate，保留 30 天 |
| 开机恢复 | systemd service + crontab @reboot | 双保险 |

---

## Fail2Ban 规则

默认安装的 Fail2Ban 配置 (`/etc/fail2ban/jail.d/trafficguard.conf`)：

```ini
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 10
banaction = nftables[type=multiport]
ignoreip = 127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16
logtarget = /var/log/fail2ban.log

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
findtime = 600
bantime = 3600

[recidive]
enabled = true
logpath = /var/log/fail2ban.log
banaction = nftables[type=allports]
bantime = 1w
findtime = 1d
maxretry = 5
```

---

## 依赖

| 依赖 | 版本要求 | 说明 |
|---|---|---|
| nftables | ≥ 0.9.0 | 核心防火墙，inet 表族支持 |
| Fail2Ban | ≥ 0.10 (推荐 ≥ 1.0) | SSH 防护，可选但推荐 |
| systemd | 可选 | 开机自恢复 service，优先使用 |
| logrotate | 可选 | 日志轮转 |

---

## 安全建议

1. 使用密钥登录 SSH，禁用密码登录
2. 修改默认 SSH 端口
3. 启用 Fail2Ban SSH jail（安装后默认已启用）
4. 配置白名单避免误封管理员 IP
5. 定期查看封禁列表：`sudo tgctl list`
6. 定期检查更新：`sudo tgctl update`

---

## 变更历史

### v1.3.0 — 核心自动封禁逻辑修复
- **修复午夜误杀**：改用基线算法（取今日日志第一条记录为基线），避免把累计历史流量当成今日流量
- **修复小时增量 vs 日限额不匹配**：`daily_total = 当前 nftables 计数器 - 今日基线值`，确保对比的是今日累计值而非上一小时增量
- 今日首次运行自动跳过检查（建立基线），下一周期开始正常查杀
- 兼容现有日志格式，`view-stats.sh` 不受影响

### v1.2.10 — tgctl 菜单与更新模块修复
- 修复热更新 `mktemp` 崩溃（P0）
- 内置卸载与 `uninstall.sh` 同步，补齐 logrotate/systemd/symlink 清理
- 去除热更新路径多余的 `sudo`
- CLI 新增 `whitelist`、`uninstall` 命令
- 服务开关操作增加失败反馈

### v1.2.9 — 关键脚本崩溃修复
- 修复 `save-stats.sh` 自动封禁时 `local` 在函数外导致崩溃
- 修复 `flock`/`mkdir` 双锁竞态
- 新增 `TRAFFICGUARD_OUT` output hook 链，修复出站流量统计

### v1.2.8 — 安装/卸载生命周期修复
- OpenRC 初始化系统支持
- logrotate 配置部署与卸载清理
- 卸载时清理 `/usr/bin/tgctl` 符号链接
- Fail2Ban 重启改为 `reload || restart`，不丢封禁
- `apt-get update` 仅在首次安装时运行一次
- SSH 端口增加范围校验（1-65535）
- crontab 空覆盖 bug 修复
- systemd service + crontab 双保险开机恢复

### v1.2.7 — 持久化存储修复
- IP 列表保存改为原子写入（mktemp + mv）
- 统计脚本添加 flock 并发锁
- logrotate 配置
- `restore_nft_rules` 规则顺序与 install.sh 对齐

### v1.2.6 — 关键自动封禁修复
- nftables 规则顺序修正（白名单优先放行 → 黑名单拦截 → 流量统计）
- 流量超限按日增量计算，而非累计值
- `quick_unban_ip` 补齐 jail 存在性检查

### v1.2.5 — 外部审计修复
- `tgctl restore` 绕过 fail2ban 依赖检查
- 整数类型验证（`[[ $var =~ ^[0-9]+$ ]]`）
- `TMPDIR` 重命名为 `TG_TMPDIR`，避免污染系统变量
- nginx jail 跳过不存在项

### v1.2.4 — crontab 管道路竞态修复
- `@reboot` crontab pipefail 竞态
- 更新模式下跳过 tgctl exec

### v1.2.1 ~ v1.2.3 — 稳定性和热更新修复
- sed 注入 TG_IS_UPDATE 热更新标识
- sudo 下 SSH 环境变量穿透
- 卸载时 crontab 完整清理
- `grep -F` 替代 `grep` 原始匹配

---

## 许可证

MIT
