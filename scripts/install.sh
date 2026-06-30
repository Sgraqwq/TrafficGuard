#!/usr/bin/env bash
# TrafficGuard 安装脚本
# 基于 Fail2Ban + Nginx 的流量监控和 IP 封禁工具
#
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/Sgraqwq/TrafficGuard/main/scripts/install.sh | sudo bash
#   sudo bash scripts/install.sh
#
# 环境变量:
#   TG_REPO=https://github.com/Sgraqwq/TrafficGuard   # 自定义仓库地址

set -euo pipefail

# ── 颜色与日志 ──────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── 检查 root ────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || error "请使用 root 运行"

# ── 仓库地址 ─────────────────────────────────────────────
TG_REPO="${TG_REPO:-https://github.com/Sgraqwq/TrafficGuard}"
TG_RAW="${TG_REPO/github.com/raw.githubusercontent.com}/main"

# ── 包管理器检测 ────────────────────────────────────────
detect_package_manager() {
    for mgr in apt-get apt dnf yum zypper pacman apk; do
        if command -v "$mgr" >/dev/null 2>&1; then
            echo "$mgr"
            return 0
        fi
    done
    echo "unknown"
}

PKG_MGR=$(detect_package_manager)

install_pkg() {
    local pkg=$1
    info "安装 $pkg"
    case "$PKG_MGR" in
        apt-get|apt) apt-get update -qq && apt-get install -y -qq "$pkg" ;;
        dnf)         dnf install -y -q "$pkg" ;;
        yum)         yum install -y -q "$pkg" ;;
        zypper)      zypper install -y "$pkg" ;;
        pacman)      pacman -S --noconfirm "$pkg" ;;
        apk)         apk add "$pkg" ;;
        *)           error "无法自动安装 $pkg（未识别的包管理器），请手动安装后重试" ;;
    esac
}

ensure_cmd() {
    local cmd=$1 pkg=$2 desc=$3
    if command -v "$cmd" >/dev/null 2>&1; then
        info "$desc 已安装: $(command -v "$cmd")"
        return 0
    fi
    warn "$desc 未安装，自动安装..."
    install_pkg "$pkg"
    command -v "$cmd" >/dev/null 2>&1 || error "$desc 安装失败，请手动安装: $pkg"
    info "$desc 安装成功"
}

# ── 下载辅助函数 ────────────────────────────────────────
dl() {
    local url="$TG_RAW/$1" dst="$2"
    mkdir -p "$(dirname "$dst")"
    curl -fsSL "$url" -o "$dst" || error "下载失败: $url"
}

dl_chmod() {
    local url="$TG_RAW/$1" dst="$2"
    mkdir -p "$(dirname "$dst")"
    curl -fsSL "$url" -o "$dst" || error "下载失败: $url"
    chmod +x "$dst"
}

write_file() {
    local dst="$1"
    mkdir -p "$(dirname "$dst")"
    cat > "$dst"
}

# ═══════════════════════════════════════════════════════════
#  安装开始
# ═══════════════════════════════════════════════════════════

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}    TrafficGuard 安装程序${NC}"
echo -e "${GREEN}========================================${NC}"
echo

# ── 1. 系统依赖 ──────────────────────────────────────────
info "检测系统依赖..."
echo

ensure_cmd "nginx"          "nginx"    "Nginx Web 服务器"
ensure_cmd "fail2ban-client" "fail2ban" "Fail2Ban 自动封禁工具"
ensure_cmd "nft"             "nftables" "nftables 防火墙"

echo
info "依赖检测完成"
echo

# ── 2. Nginx 配置 ────────────────────────────────────────
info "安装 Nginx 配置"
write_file /etc/nginx/conf.d/trafficguard.conf <<'NGINX_CONF'
# TrafficGuard - Nginx 限制配置

# 连接限制：每 IP 最多 100 并发连接
limit_conn_zone $binary_remote_addr zone=perip:10m;

# 速率限制：每 IP 每秒 10 个请求
limit_req_zone $binary_remote_addr zone=req_limit:10m rate=10r/s;

# 超过限制时返回 429 (Too Many Requests)
limit_req_status 429;
limit_conn_status 429;

server {
    listen 80;
    server_name _;

    # 应用连接限制
    limit_conn perip 100;

    # 应用速率限制
    limit_req zone=req_limit burst=20 nodelay;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # 自定义 429 错误页面
    error_page 429 = @429;
    location @429 {
        return 429 "Too Many Requests\n";
    }
}
NGINX_CONF

nginx -t
if systemctl is-active --quiet nginx 2>/dev/null; then
    systemctl reload nginx
    info "Nginx 配置已重载"
else
    info "Nginx 配置已安装（Nginx 未运行，请启动后生效: systemctl start nginx）"
fi

# ── 3. Fail2Ban 配置 ────────────────────────────────────
info "安装 Fail2Ban 配置"

# jail.local
write_file /etc/fail2ban/jail.local <<'FAIL2BAN_JAIL'
# TrafficGuard - Fail2Ban Jail 配置

[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 10
banaction = iptables-multiport
ignoreip = 127.0.0.1/8 ::1
logtarget = /var/log/fail2ban.log
dbbackend = sqlite
dbfilename = /var/lib/fail2ban/fail2ban.sqlite3

[nginx-limit-req]
enabled = true
port = http,https
filter = nginx-limit-req
logpath = /var/log/nginx/error.log
maxretry = 10
findtime = 60
bantime = 600
action = iptables-multiport[name=nginx-limit-req, port="http,https", protocol=tcp]

[nginx-limit-conn]
enabled = true
port = http,https
filter = nginx-limit-conn
logpath = /var/log/nginx/error.log
maxretry = 5
findtime = 60
bantime = 1800
action = iptables-multiport[name=nginx-limit-conn, port="http,https", protocol=tcp]

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
findtime = 600
bantime = 3600
FAIL2BAN_JAIL

# nginx-limit-req filter
write_file /etc/fail2ban/filter.d/nginx-limit-req.conf <<'FLTR_REQ'
# TrafficGuard - Fail2Ban Filter: nginx-limit-req
# 参考官方 fail2ban filter: nginx-limit-req.conf

[Definition]

__prefix_line = \s*\[error\] \d+#\d+: \*\d+\s+

failregex = ^%(__prefix_line)s(?:limiting|delaying) requests(?:, excess: [\d\.]+)? by zone "[^"]*", client: <HOST>

ignoreregex =

datepattern = {^LN-BEG}
FLTR_REQ

# nginx-limit-conn filter
write_file /etc/fail2ban/filter.d/nginx-limit-conn.conf <<'FLTR_CONN'
# TrafficGuard - Fail2Ban Filter: nginx-limit-conn
# 参考官方 fail2ban filter: nginx-limit-req.conf

[Definition]

__prefix_line = \s*\[error\] \d+#\d+: \*\d+\s+

failregex = ^%(__prefix_line)slimiting connections by zone "[^"]*", client: <HOST>

ignoreregex =

datepattern = {^LN-BEG}
FLTR_CONN

if systemctl is-active --quiet fail2ban 2>/dev/null; then
    systemctl restart fail2ban
    info "Fail2Ban 配置已重载"
else
    systemctl start fail2ban 2>/dev/null || true
    info "Fail2Ban 配置已安装（Fail2Ban 已启动）"
fi

# ── 4. 命令行工具 ────────────────────────────────────────
info "安装命令行工具"
dl_chmod "traffic-monitor/tgctl" /usr/local/bin/tgctl
info "命令行工具已安装到 /usr/local/bin/tgctl"

# ── 5. 流量统计脚本 ──────────────────────────────────────
info "安装流量统计脚本"
dl_chmod "traffic-monitor/save-stats.sh" /usr/local/bin/traffic-save-stats
dl_chmod "traffic-monitor/view-stats.sh" /usr/local/bin/traffic-view-stats
info "流量统计脚本已安装"

# ── 6. 创建目录 ──────────────────────────────────────────
info "创建目录"
mkdir -p /var/lib/trafficguard/stats
mkdir -p /var/log/trafficguard
info "目录已创建"

# ── 7. 定时任务 ──────────────────────────────────────────
info "设置定时任务（每小时保存一次流量统计）"
(crontab -l 2>/dev/null | grep -v "traffic-save-stats"; echo "0 * * * * /usr/local/bin/traffic-save-stats") | crontab -
info "定时任务已设置"

# ── 8. nftables 流量统计 ────────────────────────────────
info "创建 nftables 流量统计表"
nft add table ip trafficguard 2>/dev/null || true
nft add chain ip trafficguard TRAFFICGUARD 2>/dev/null || true
nft add rule ip trafficguard TRAFFICGUARD counter 2>/dev/null || true
info "nftables 表已创建并添加 counter 规则"

# ── 完成 ─────────────────────────────────────────────────
echo
info "安装完成"
echo
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}    TrafficGuard 已安装${NC}"
echo -e "${GREEN}========================================${NC}"
echo
echo "Nginx 配置: /etc/nginx/conf.d/trafficguard.conf"
echo "Fail2Ban 配置: /etc/fail2ban/jail.local"
echo "Fail2Ban Filter: /etc/fail2ban/filter.d/nginx-limit-*.conf"
echo
echo "快速开始:"
echo "  tgctl                    # 打开管理界面"
echo "  tgctl status             # 查看状态"
echo "  tgctl list               # 查看封禁列表"
echo
echo "管理命令:"
echo "  tgctl ban <IP>           # 手动封禁"
echo "  tgctl unban <IP>         # 手动解封"
echo "  tgctl ssh                # SSH 防护"
echo "  tgctl config             # 配置管理"
