# TrafficGuard

基于 Fail2Ban + Nginx 的流量监控和 IP 封禁工具。

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
├── Nginx              # 速率/连接限制
├── Fail2Ban           # 自动封禁
├── tgctl              # 命令行管理工具
└── traffic-monitor    # 流量统计脚本
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

## 配置

### Nginx 限制

编辑 `/etc/nginx/conf.d/trafficguard.conf`：

```nginx
# 连接限制：每 IP 最多 100 并发连接
limit_conn_zone $binary_remote_addr zone=perip:10m;

# 速率限制：每 IP 每秒 10 个请求
limit_req_zone $binary_remote_addr zone=req_limit:10m rate=10r/s;

server {
    limit_conn perip 100;
    limit_req zone=req_limit burst=20 nodelay;
}
```

### Fail2Ban 规则

编辑 `/etc/fail2ban/jail.local`：

```ini
[nginx-limit-req]
enabled = true
port = http,https
filter = nginx-limit-req
logpath = /var/log/nginx/error.log
maxretry = 10
findtime = 60
bantime = 600

[nginx-limit-conn]
enabled = true
port = http,https
filter = nginx-limit-conn
logpath = /var/log/nginx/error.log
maxretry = 5
findtime = 60
bantime = 1800

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
findtime = 600
bantime = 3600
```

## 命令参考

### Fail2Ban 命令

```bash
# 查看状态
sudo fail2ban-client status

# 查看特定 jail
sudo fail2ban-client status nginx-limit-req

# 手动封禁 IP
sudo fail2ban-client set nginx-limit-req banip 1.2.3.4

# 手动解封 IP
sudo fail2ban-client set nginx-limit-req unbanip 1.2.3.4

# 重载配置
sudo fail2ban-client reload

# 查看日志
sudo tail -f /var/log/fail2ban.log
```

### Nginx 命令

```bash
# 测试配置
sudo nginx -t

# 重载配置
sudo systemctl reload nginx
```

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

- Nginx
- Fail2Ban
- nftables 或 iptables

## 安全建议

1. 使用密钥登录，禁用密码登录
2. 修改默认 SSH 端口
3. 启用 Fail2Ban SSH jail
4. 定期查看封禁列表
5. 配置白名单避免误封

## 许可证

MIT
