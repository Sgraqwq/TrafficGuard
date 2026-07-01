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

# ── 环境变量 
export DEBIAN_FRONTEND=noninteractive

# ── 仓库地址及参数 
TG_REPO="${TG_REPO:-https://github.com/Sgraqwq/TrafficGuard}"
TG_BACKEND_PORT="${TG_BACKEND_PORT:-8080}"

# URL 验证：防止恶意 URL 注入
validate_tg_repo() {
    local url="$1"
    if ! echo "$url" | grep -qE '^https?://[a-zA-Z0-9]'; then
        echo "[ERROR] TG_REPO 地址必须以 http:// 或 https:// 开头" >&2
        exit 1
    fi
    # 检测危险字符：空格、Tab、分号、管道、反引号、美元符号、括号、花括号、与号
    if echo "$url" | grep -qE '[[:space:];|&`$(){}]' ; then
        echo "[ERROR] TG_REPO 地址包含非法字符" >&2
        exit 1
    fi
}
validate_tg_repo "$TG_REPO"

TG_RAW="${TG_REPO/github.com/raw.githubusercontent.com}/main"

# ── 加载公共库 
load_common_lib() {
    # 优先级 1: 本地文件系统
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null || true)"
    if [ -n "$script_dir" ] && [ -f "$script_dir/lib/common.sh" ]; then
        # shellcheck source=lib/common.sh
        source "$script_dir/lib/common.sh"
        return 0
    fi

    # 优先级 2: 从仓库下载（curl pipe 模式）
    echo "[INFO] 正在加载公共库..."
    local tmp
    tmp=$(mktemp) || { echo "[ERROR] 创建临时文件失败" >&2; exit 1; }
    curl -fsSL --connect-timeout 10 --max-time 30 "${TG_RAW}/scripts/lib/common.sh" -o "$tmp" || {
        rm -f "$tmp"
        echo "[ERROR] 下载公共库失败，请检查网络连接" >&2
        exit 1
    }
    # shellcheck source=/dev/null
    source "$tmp"
    rm -f "$tmp"
    echo "[INFO] 公共库加载完成"
}
load_common_lib

# ── Trap 处理 
trap cleanup_temp EXIT INT TERM

# ── 检查 root 
[ "$(id -u)" -eq 0 ] || error "请使用 root 运行"

# ── 系统环境检测 
INIT_SYSTEM=$(detect_init_system)
FW_BACKEND=$(detect_firewall_backend)
F2B_VER=$(detect_fail2ban_version)
NGINX_CONF_DIR=$(detect_nginx_conf_dir)
AUTH_LOG=$(detect_auth_log)

info "系统环境:"
info "  初始化系统: $INIT_SYSTEM"
info "  防火墙后端: $FW_BACKEND"
info "  Fail2Ban 版本: ${F2B_VER:-未安装}"
info "  Nginx 配置目录: $NGINX_CONF_DIR"
info "  认证日志路径: $AUTH_LOG"
info ""

# ── 版本兼容性检查 
if [ "$F2B_VER" != "not_installed" ] && [ "$F2B_VER" != "unknown" ]; then
    # Fail2Ban 0.9.x 不支持 nftables 后端语法
    if echo "$F2B_VER" | grep -qE '^0\.'; then
        warn "Fail2Ban 版本 $F2B_VER 可能不支持 nftables 后端"
        warn "建议升级到 1.0+ 或手动配置 iptables 后端"
    fi
fi

# ── 包管理器检测 
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
info "包管理器: $PKG_MGR"
echo ""

# ── 安装辅助函数 
install_pkg() {
    local pkg=$1
    info "安装 $pkg"
    case "$PKG_MGR" in
        apt-get|apt)  apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" ;;
        dnf)          dnf install -y -q "$pkg" ;;
        yum)          yum install -y -q "$pkg" ;;
        zypper)       zypper install -y "$pkg" ;;
        pacman)       pacman -S --noconfirm "$pkg" ;;
        apk)          apk add "$pkg" ;;
        *)            error "无法自动安装 $pkg（未识别的包管理器），请手动安装后重试" ;;
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

# ── 下载辅助函数
# 优先从本地相对路径复制，不存在时再去远程下载
dl_or_copy() {
    local rel_path="$1" dst="$2"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null || true)"
    # 安装脚本通常在 scripts/ 目录下，所以项目根目录是上级目录
    local local_file="$(dirname "$script_dir")/$rel_path"

    mkdir -p "$(dirname "$dst")" || error "创建目录失败: $(dirname "$dst")"

    if [ -n "$script_dir" ] && [ -f "$local_file" ]; then
        cp "$local_file" "$dst" || error "复制本地文件失败: $local_file"
    else
        local url="$TG_RAW/$rel_path"
        curl -fsSL --connect-timeout 10 --max-time 30 "$url" -o "$dst" || error "下载失败: $url"
    fi
}

dl() {
    dl_or_copy "$1" "$2"
}

dl_chmod() {
    dl_or_copy "$1" "$2"
    chmod +x "$2"
}


#  安装开始

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}    TrafficGuard 安装程序${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# ── 0. 前置检查 
info "前置环境检查..."
echo ""

# 检查 nftables 可用性
if [ "$FW_BACKEND" = "nftables" ]; then
    check_nftables_available
else
    warn "未检测到 nftables，部分功能可能不可用"
fi

echo ""
info "前置检查通过"
echo ""

# ── 1. 系统依赖 
info "检测系统依赖..."
echo ""

ensure_cmd "nginx"           "nginx"      "Nginx Web 服务器"
ensure_cmd "fail2ban-client" "fail2ban"   "Fail2Ban 自动封禁工具"

# 如果检测到 nftables 则需要安装
if [ "$FW_BACKEND" = "nftables" ]; then
    ensure_cmd "nft" "nftables" "nftables 防火墙"
fi

echo ""
info "依赖检测完成"
echo ""

# ── 2. Nginx 配置 
info "安装 Nginx 配置"
write_file_atomic "$NGINX_CONF_DIR/trafficguard.conf" <<'NGINX_CONF'
# TrafficGuard - Nginx 限制配置

# 连接限制：每 IP 最多 100 并发连接
limit_conn_zone $binary_remote_addr zone=perip:10m;

# 速率限制：放宽至每 IP 每秒 50 个请求（兼容代理服务器流量爆发）
limit_req_zone $binary_remote_addr zone=req_limit:10m rate=50r/s;

# 超过限制时返回 429 (Too Many Requests)
limit_req_status 429;
limit_conn_status 429;

server {
    listen 80;
    server_name _;

    # 应用连接限制
    limit_conn perip 100;

    # 应用速率限制
    limit_req zone=req_limit burst=100 nodelay;

    location / {
        proxy_pass http://127.0.0.1:__TG_BACKEND_PORT__;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
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

# 替换动态端口
sed -i "s/__TG_BACKEND_PORT__/$TG_BACKEND_PORT/g" "$NGINX_CONF_DIR/trafficguard.conf"

# 测试 Nginx 配置并启动/重载
if nginx -t 2>/dev/null; then
    info "Nginx 配置测试通过"
    if service_is_active nginx "$INIT_SYSTEM"; then
        service_control reload nginx "$INIT_SYSTEM" && info "Nginx 已重新加载" || warn "Nginx 重载失败"
    else
        if service_control start nginx "$INIT_SYSTEM"; then
            info "Nginx 已启动"
        else
            warn "Nginx 启动失败，请手动检查:"
            warn "  nginx -t"
            warn "  systemctl start nginx"
        fi
    fi
else
    warn "Nginx 配置测试失败，请检查配置后手动启动:"
    warn "  配置文件: $NGINX_CONF_DIR/trafficguard.conf"
    warn "  nginx -t"
    warn "  systemctl start nginx"
fi
info "Nginx 已就绪"
echo ""

# ── 3. Fail2Ban 配置 
info "安装 Fail2Ban 配置"

# 写入 jail.d/trafficguard.conf（不再覆盖 jail.local）
write_file_atomic /etc/fail2ban/jail.d/trafficguard.conf <<'FAIL2BAN_JAIL'
# TrafficGuard - Fail2Ban Jail 配置
# 由 TrafficGuard 安装脚本自动生成

[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 10
banaction = nftables[type=multiport]
# 忽略本地回环和内网网段，防止内部服务通信被误封
ignoreip = 127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16
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
# 触发后执行全端口封禁，防止继续探测隐藏的代理端口
action = nftables[type=allports]

[nginx-limit-conn]
enabled = true
port = http,https
filter = nginx-limit-conn
logpath = /var/log/nginx/error.log
maxretry = 5
findtime = 60
bantime = 1800
# 触发后执行全端口封禁，防止继续探测隐藏的代理端口
action = nftables[type=allports]

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
findtime = 600
bantime = 3600

# Recidive jail: 对重复攻击者实施更长封禁
[recidive]
enabled = true
logpath = /var/log/fail2ban.log
banaction = nftables[type=allports]
bantime = 1w
findtime = 1d
maxretry = 5
FAIL2BAN_JAIL

# 更新日志路径为实际检测值（如果默认路径不对）
AUTH_LOG_REAL=$(detect_auth_log)
if [ "$AUTH_LOG_REAL" != "/var/log/auth.log" ]; then
    info "检测到认证日志路径: $AUTH_LOG_REAL"
    # 替换 jail.d 中的日志路径
    if [ -f /etc/fail2ban/jail.d/trafficguard.conf ]; then
        sed -i "s|logpath = /var/log/auth.log|logpath = $AUTH_LOG_REAL|g" \
            /etc/fail2ban/jail.d/trafficguard.conf 2>/dev/null || true
    fi
fi

# Nginx 错误日志路径检测
NGINX_LOG="/var/log/nginx/error.log"
if [ ! -f "$NGINX_LOG" ]; then
    # 尝试从 nginx 配置中提取 error_log 路径
    ALT_LOG=$(nginx -T 2>/dev/null | grep -m1 'error_log' | awk '{print $2}' | tr -d ';')
    if [ -n "$ALT_LOG" ] && [ "$ALT_LOG" != "stderr" ] && [ -f "$ALT_LOG" ]; then
        NGINX_LOG="$ALT_LOG"
    else
        # 尝试常见备选路径
        for candidate in /var/log/nginx/error.log /var/log/error.log /var/log/nginx/errors.log; do
            if [ -f "$candidate" ]; then
                NGINX_LOG="$candidate"
                break
            fi
        done
    fi
fi
# 如果 nginx 日志不在标准位置，更新 Fail2Ban 配置
if [ -f /etc/fail2ban/jail.d/trafficguard.conf ]; then
    if [ "$NGINX_LOG" != "/var/log/nginx/error.log" ]; then
        info "检测到 Nginx 错误日志路径: $NGINX_LOG"
        sed -i "s|logpath = /var/log/nginx/error.log|logpath = $NGINX_LOG|g" \
            /etc/fail2ban/jail.d/trafficguard.conf 2>/dev/null || true
    fi
fi

# nginx-limit-req filter
write_file_atomic /etc/fail2ban/filter.d/nginx-limit-req.conf <<'FLTR_REQ'
# TrafficGuard - Fail2Ban Filter: nginx-limit-req
# 参考官方 fail2ban filter: nginx-limit-req.conf

[Definition]

__prefix_line = \s*\[error\] \d+#\d+: \*\d+\s+

failregex = ^%(__prefix_line)s(?:limiting|delaying) requests(?:, excess: [\d\.]+)? by zone "[^"]*", client: <HOST>

ignoreregex =

datepattern = {^LN-BEG}
FLTR_REQ

# nginx-limit-conn filter
write_file_atomic /etc/fail2ban/filter.d/nginx-limit-conn.conf <<'FLTR_CONN'
# TrafficGuard - Fail2Ban Filter: nginx-limit-conn
# 参考官方 fail2ban filter: nginx-limit-req.conf

[Definition]

__prefix_line = \s*\[error\] \d+#\d+: \*\d+\s+

failregex = ^%(__prefix_line)slimiting connections by zone "[^"]*", client: <HOST>

ignoreregex =

datepattern = {^LN-BEG}
FLTR_CONN

# 启动/重启 fail2ban
info "启动 Fail2Ban..."
if service_is_active fail2ban "$INIT_SYSTEM"; then
    if service_control restart fail2ban "$INIT_SYSTEM"; then
        info "Fail2Ban 已重启"
    else
        warn "Fail2Ban 重启失败，尝试手动启动..."
        service_control start fail2ban "$INIT_SYSTEM" || {
            warn "Fail2Ban 启动失败，请手动检查:"
            warn "  fail2ban-client -t  # 测试配置"
            warn "  fail2ban-server     # 前台运行查看错误"
        }
    fi
else
    if service_control start fail2ban "$INIT_SYSTEM"; then
        info "Fail2Ban 已启动"
    else
        warn "Fail2Ban 启动失败，请手动检查:"
        warn "  fail2ban-client -t  # 测试配置"
        warn "  fail2ban-server     # 前台运行查看错误"
    fi
fi

# 验证 fail2ban 运行状态
if service_is_active fail2ban "$INIT_SYSTEM"; then
    info "Fail2Ban 运行中"
    fail2ban-client status 2>/dev/null | sed 's/^/  /' || true
else
    warn "Fail2Ban 未运行"
fi
echo ""

# ── 4. 命令行工具 
info "安装命令行工具"
dl_chmod "traffic-monitor/tgctl" /usr/local/bin/tgctl

# 创建符号链接到 /usr/bin，解决 sudo secure_path 问题
if [ ! -f /usr/bin/tgctl ]; then
    ln -sf /usr/local/bin/tgctl /usr/bin/tgctl 2>/dev/null || true
fi

info "命令行工具已安装到 /usr/local/bin/tgctl"

# ── 5. 流量统计脚本 
info "安装流量统计脚本"
dl_chmod "traffic-monitor/save-stats.sh" /usr/local/bin/traffic-save-stats
dl_chmod "traffic-monitor/view-stats.sh" /usr/local/bin/traffic-view-stats
info "流量统计脚本已安装"

# ── 6. 创建目录 
info "创建目录"
mkdir -p /var/lib/trafficguard/stats || warn "创建 /var/lib/trafficguard/stats 失败"
mkdir -p /var/log/trafficguard || warn "创建 /var/log/trafficguard 失败"
info "目录已创建"

# ── 7. 定时任务 
info "设置定时任务（每小时保存一次流量统计）"
if (crontab -l 2>/dev/null | grep -v "traffic-save-stats"; echo "0 * * * * /usr/local/bin/traffic-save-stats") | crontab - 2>/dev/null; then
    info "定时任务已设置"
else
    warn "定时任务设置失败，请手动添加:"
    warn "  echo '0 * * * * /usr/local/bin/traffic-save-stats' | crontab -"
fi

# ── 8. nftables 流量统计（幂等创建） 
info "创建 nftables 流量统计表"
if [ "$FW_BACKEND" = "nftables" ]; then
    nft_create_table_safe trafficguard

    # 创建带 hook 的链（必须有 hook 才能拦截流量进行统计）
    if ! nft_chain_exists trafficguard TRAFFICGUARD; then
        nft add chain ip trafficguard TRAFFICGUARD \
            '{ type filter hook input priority 0 ; policy accept ; }' 2>/dev/null || \
            warn "创建 nftables 链 'TRAFFICGUARD' 失败"
    fi

    # 使用动态 set 统计每个 IP 的流量
    if ! nft list set ip trafficguard per_ip_traffic >/dev/null 2>&1; then
        nft add set ip trafficguard per_ip_traffic \
            '{ type ipv4_addr ; flags dynamic ; counter ; size 65535 ; }' 2>/dev/null || \
            warn "创建 nftables set 失败"
    fi

    # 规则幂等性：检查规则是否已存在
    RULE_CHECK_STR="add @per_ip_traffic { ip saddr counter }"
    if ! nft_rule_exists trafficguard TRAFFICGUARD "$RULE_CHECK_STR"; then
        nft add rule ip trafficguard TRAFFICGUARD "$RULE_CHECK_STR" 2>/dev/null || \
            warn "添加 nftables 规则失败"
    fi
    info "nftables 表已创建并添加 per-IP 流量统计规则"
else
    warn "未检测到 nftables，跳过流量统计规则创建"
fi

# ── 完成 
echo ""
info "安装完成"
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}    TrafficGuard 已安装${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Nginx 配置: $NGINX_CONF_DIR/trafficguard.conf"
echo "Fail2Ban 配置: /etc/fail2ban/jail.d/trafficguard.conf"
echo "Fail2Ban Filter: /etc/fail2ban/filter.d/nginx-limit-*.conf"
echo ""
echo "快速开始:"
echo "  tgctl                    # 打开管理界面"
echo "  tgctl status             # 查看状态"
echo "  tgctl list               # 查看封禁列表"
echo ""
echo "管理命令:"
echo "  tgctl ban <IP>           # 手动封禁"
echo "  tgctl unban <IP>         # 手动解封"
echo "  tgctl ssh                # SSH 防护"
echo "  tgctl config             # 配置管理"
