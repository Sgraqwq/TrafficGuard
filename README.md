# TrafficGuard

基于内核级 nftables 防火墙 + Fail2Ban 的轻量级流量监控和 IP 封禁工具。

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/Sgraqwq/TrafficGuard/main/scripts/install.sh | sudo bash
```

## 一键卸载

```bash
curl -fsSL https://raw.githubusercontent.com/Sgraqwq/TrafficGuard/main/scripts/uninstall.sh | sudo bash
```

## 功能

- **并发连接限制**：单 IP 最大并发连接数限制
- **速率限制**：单 IP 每秒请求数限制
- **自动封禁**：超过限制自动封禁 IP
- **自动解封**：封禁到期自动解封
- **流量监控**：查看每个 IP 的流量使用情况
- **历史流量**：查看指定时间窗口的流量统计
- **SSH 防护**：自动检测和封禁 SSH 攻击

## 架构

```
TrafficGuard
├── nftables           # 内核级网络层防护 (连接/速率限制)
├── Fail2Ban           # SSH 防护及持久化封禁
├── tgctl              # 命令行交互管理工具
└── traffic-monitor    # 内核级流量统计监控
```

## 安装

```bash
sudo bash scripts/install.sh
```

## 卸载

```bash
sudo bash scripts/uninstall.sh
```

## 快速开始

### 使用 tgctl 管理工具（推荐）

```bash
# 打开交互式管理界面
sudo tgctl

# 查看状态
sudo tgctl status

# 查看封禁列表
sudo tgctl list

# 封禁 IP
sudo tgctl ban 1.2.3.4

# 解封 IP
sudo tgctl unban 1.2.3.4

# SSH 防护
sudo tgctl ssh
```

### tgctl 菜单说明

```
╔══════════════════════════════════════════════════════════╗
║  _____           __  __ _       ____                     _     ║
║ |_   _| __ __ _ / _|/ _(_) ___ / ___|_   _  __ _ _ __ __| |    ║
║   | || '__/ _` | |_| |_| |/ __| |  _| | | |/ _` | '__/ _` |    ║
║   | || | | (_| |  _|  _| | (__| |_| | |_| | (_| | | | (_| |    ║
║   |_||_|  \__,_|_| |_| |_|\___|\____|\__,_|\__,_|_|  \__,_|    ║
║                                                          ║
║              流量监控和 IP 封禁管理工具                   ║
╠══════════════════════════════════════════════════════════╣
║  1) 查看状态                                            ║
║  2) 查看封禁列表                                        ║
║  3) 封禁 IP                                             ║
║  4) 解封 IP                                             ║
║  5) 查看流量统计                                        ║
║  6) 查看历史流量                                        ║
║  7) SSH 防护                                            ║
║  8) 配置管理                                            ║
║  9) 服务管理                                            ║
║  0) 退出                                                ║
╚══════════════════════════════════════════════════════════╝
```

### Fail2Ban 规则

默认生成的 Fail2Ban 配置 (`/etc/fail2ban/jail.d/trafficguard.conf`)：

```ini
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 10
banaction = nftables[type=multiport]
ignoreip = 127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16

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

## 命令参考

### Fail2Ban 命令

```bash
# 查看状态
sudo fail2ban-client status

# 手动封禁 IP (全局黑名单)
# 可以直接通过 tgctl 封禁，或者使用底层 nftables 命令:
sudo nft add element ip trafficguard manual_banned { 1.2.3.4 }

# 手动解封 IP
sudo nft delete element ip trafficguard manual_banned { 1.2.3.4 }

## 流量监控

### 实时流量

```bash
# 查看 Top 20 流量 IP
sudo tgctl

# 选择 5) 查看流量统计（实时）
```

### 历史流量

```bash
# 查看今天流量
sudo traffic-view-stats -t

# 查看指定日期流量
sudo traffic-view-stats -d 20260701

# 查看流量汇总
sudo traffic-view-stats -s

# 实时查看当前流量
sudo traffic-view-stats -r
```

### 手动保存流量统计

```bash
# 立即保存当前流量统计
sudo traffic-save-stats
```

### 定时任务

安装后会自动设置定时任务，每小时保存一次流量统计：

```bash
# 查看定时任务
crontab -l

# 手动添加定时任务（每小时保存一次）
0 * * * * /usr/local/bin/traffic-save-stats

# 手动添加定时任务（每 5 分钟保存一次）
*/5 * * * * /usr/local/bin/traffic-save-stats
```

## SSH 防护

SSH 防护默认启用，当检测到 3 次失败登录时自动封禁 IP。

### 查看 SSH 防护状态

```bash
sudo fail2ban-client status sshd
```

### 手动封禁 SSH 攻击 IP

```bash
sudo fail2ban-client set sshd banip 1.2.3.4
```

### 查看最近 SSH 失败登录

```bash
grep "Failed password" /var/log/auth.log | tail -20
```

## 依赖

- nftables (核心依赖)
- Fail2Ban (SSH 防御可选依赖)

## 安全建议

1. 使用密钥登录，禁用密码登录
2. 修改默认 SSH 端口
3. 启用 Fail2Ban SSH jail
4. 定期查看封禁列表
5. 配置白名单避免误封

## 许可证

MIT
