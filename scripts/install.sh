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

# ── 仓库地址 
TG_REPO="${TG_REPO:-https://github.com/Sgraqwq/TrafficGuard}"

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
AUTH_LOG=$(detect_auth_log)
info "系统环境:"
info "  初始化系统: $INIT_SYSTEM"
info "  防火墙后端: $FW_BACKEND"
info "  Fail2Ban 版本: ${F2B_VER:-未安装}"
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

ensure_cmd "fail2ban-client" "fail2ban"   "Fail2Ban 自动封禁工具"

# 如果检测到 nftables 则需要安装
if [ "$FW_BACKEND" = "nftables" ]; then
    ensure_cmd "nft" "nftables" "nftables 防火墙"
fi

echo ""
info "依赖检测完成"
echo ""


# ── 2. 收集配置参数 
info "配置参数..."

# 检测已安装的 SSH 端口
EXISTING_SSH_PORT=""
if [ -f /etc/fail2ban/jail.d/trafficguard.conf ]; then
    EXISTING_SSH_PORT=$(grep -E '^port\s*=' /etc/fail2ban/jail.d/trafficguard.conf 2>/dev/null | head -1 | awk '{print $3}' || true)
fi

SSH_PORT="ssh" # Fail2Ban 默认使用 ssh，等同于 22
if [ -t 0 ] || [ -c /dev/tty ]; then
    echo ""
    if [ -n "$EXISTING_SSH_PORT" ]; then
        info "检测到已安装的 SSH 端口: $EXISTING_SSH_PORT"
        echo -n "请输入需要防护的 SSH 端口 [直接回车保持 $EXISTING_SSH_PORT]: "
    else
        echo -n "请输入需要防护的 SSH 端口 [默认 22]: "
    fi
    read input_port < /dev/tty || true
    if [ -n "$input_port" ] && [[ "$input_port" =~ ^[0-9]+$ ]]; then
        SSH_PORT="$input_port"
    elif [ -n "$EXISTING_SSH_PORT" ]; then
        SSH_PORT="$EXISTING_SSH_PORT"
    fi
fi
if [ "$SSH_PORT" = "ssh" ] || [ "$SSH_PORT" = "22" ]; then
    info "SSH 防护端口: 22 (默认)"
    SSH_PORT="ssh"
else
    info "SSH 防护端口: $SSH_PORT"
fi
echo ""

# 自动提取当前管理员 IP
ADMIN_IP=""
if [ -n "${SSH_CLIENT:-}" ]; then
    ADMIN_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
elif [ -n "${SSH_CONNECTION:-}" ]; then
    ADMIN_IP=$(echo "$SSH_CONNECTION" | awk '{print $1}')
fi

# sudo 模式下尝试通过 who 获取真实 IP
if [ -z "$ADMIN_IP" ]; then
    ADMIN_IP=$(who -m 2>/dev/null | awk '{print $NF}' | tr -d '()' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)
fi

ADD_WHITELIST="y"
if [ -n "$ADMIN_IP" ]; then
    info "已将您的当前 IP ($ADMIN_IP) 设定为初始全局白名单"
else
    info "未检测到 SSH 登录 IP，跳过初始白名单"
fi
echo ""

# ── 3. 生成防火墙配置文件 
info "生成 TrafficGuard 核心配置文件..."
TG_CONF_DIR="/etc/trafficguard"
TG_CONF_FILE="$TG_CONF_DIR/trafficguard.conf"
mkdir -p "$TG_CONF_DIR"

if [ ! -f "$TG_CONF_FILE" ]; then
    write_file_atomic "$TG_CONF_FILE" <<'EOF_CONF'
# =========================================================
# TrafficGuard 防火墙与流量监控核心配置
# =========================================================

# 【单IP每日流量上限 (单位: MB)】
# 防御类型: 防止代理节点被白嫖偷跑流量、恶意刷流
# 运作机制: 后台监控程序会定期计算单 IP 累计流量，一旦超限，将自动把该 IP 永久打入内核黑名单。
# 设置为 0 表示不限制流量。建议值: 个人独享代理(10000 即 10GB)、共享节点(2000 即 2GB)
TG_DAILY_TRAFFIC_LIMIT_MB=0

# 【单IP最大并发连接数限制】
# 防御类型: 慢速连接耗尽攻击、恶意多线程下载
# 运作机制: 瞬时超过此连接数的包将被内核静默丢弃。
# 建议值: 代理服务器(50~200)、Web服务器(100~300)
TG_CONN_LIMIT=100

# 【单IP新建连接频率限制】
# 防御类型: CC攻击、高频端口扫描
# 运作机制: 纯新建连接 (State New) 每秒超过设定值后进行丢包。
TG_RATE_LIMIT=50

# 【单IP频率限制的容忍度 (Burst)】
# 解释: 允许瞬间爆发的新连接数。
TG_RATE_BURST=100
EOF_CONF
    info "配置文件已生成: $TG_CONF_FILE"
else
    info "检测到现有的配置文件，保留原配置"
fi

# 加载配置变量以便后续使用
TG_CONN_LIMIT=$(get_config_int "TG_CONN_LIMIT" "$TG_CONF_FILE" "100")
TG_RATE_LIMIT=$(get_config_int "TG_RATE_LIMIT" "$TG_CONF_FILE" "50")
TG_RATE_BURST=$(get_config_int "TG_RATE_BURST" "$TG_CONF_FILE" "100")
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


[sshd]
enabled = true
port = __TG_SSH_PORT__
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

# 替换配置中的动态变量
sed -i "s/__TG_SSH_PORT__/$SSH_PORT/g" /etc/fail2ban/jail.d/trafficguard.conf 2>/dev/null || true

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

# ── 8. nftables 流量统计与纯网络层限流 (幂等创建) 
info "创建 nftables 底层防护与流量统计规则"
if [ "$FW_BACKEND" = "nftables" ]; then
    nft_create_table_safe trafficguard

    # 创建带 hook 的链（必须有 hook 才能拦截流量进行统计）
    if ! nft_chain_exists trafficguard TRAFFICGUARD; then
        nft add chain ip trafficguard TRAFFICGUARD \
            '{ type filter hook input priority 0 ; policy accept ; }' 2>/dev/null || \
            warn "创建 nftables 链 'TRAFFICGUARD' 失败"
    fi

    # === 1. 流量统计集合（入站/出站分别统计） ===
    # 入站流量统计（外部 IP 访问本机）
    if ! nft list set ip trafficguard inbound_traffic >/dev/null 2>&1; then
        nft add set ip trafficguard inbound_traffic \
            '{ type ipv4_addr ; flags dynamic ; counter ; size 65535 ; }' 2>/dev/null || \
            warn "创建 nftables 入站流量统计 set 失败"
    fi
    # 出站流量统计（本机访问外部 IP）
    if ! nft list set ip trafficguard outbound_traffic >/dev/null 2>&1; then
        nft add set ip trafficguard outbound_traffic \
            '{ type ipv4_addr ; flags dynamic ; counter ; size 65535 ; }' 2>/dev/null || \
            warn "创建 nftables 出站流量统计 set 失败"
    fi
    # 添加统计规则
    RULE_INBOUND="add @inbound_traffic { ip daddr counter }"
    if ! nft_rule_exists trafficguard TRAFFICGUARD "$RULE_INBOUND"; then
        nft add rule ip trafficguard TRAFFICGUARD "$RULE_INBOUND" 2>/dev/null || \
            warn "添加 nftables 入站流量统计规则失败"
    fi
    RULE_OUTBOUND="add @outbound_traffic { ip saddr counter }"
    if ! nft_rule_exists trafficguard TRAFFICGUARD "$RULE_OUTBOUND"; then
        nft add rule ip trafficguard TRAFFICGUARD "$RULE_OUTBOUND" 2>/dev/null || \
            warn "添加 nftables 出站流量统计规则失败"
    fi

    # === 2. 白名单集合 ===
    if ! nft list set ip trafficguard whitelist >/dev/null 2>&1; then
        nft add set ip trafficguard whitelist '{ type ipv4_addr ; size 65535 ; }' 2>/dev/null || \
            warn "创建 nftables 白名单 set 失败"
    fi
    # 自动加入管理员 IP
    if [ "$ADD_WHITELIST" = "y" ] && [ -n "$ADMIN_IP" ]; then
        nft add element ip trafficguard whitelist { "$ADMIN_IP" } 2>/dev/null || warn "添加管理员 IP 到白名单失败"
    fi
    RULE_WHITELIST="ip saddr @whitelist accept"
    if ! nft_rule_exists trafficguard TRAFFICGUARD "$RULE_WHITELIST"; then
        nft add rule ip trafficguard TRAFFICGUARD "$RULE_WHITELIST" 2>/dev/null || warn "添加白名单放行规则失败"
    fi

    # === 3. 手动黑名单集合 ===
    if ! nft list set ip trafficguard manual_banned >/dev/null 2>&1; then
        nft add set ip trafficguard manual_banned '{ type ipv4_addr ; size 65535 ; }' 2>/dev/null || \
            warn "创建 nftables 手动黑名单 set 失败"
    fi
    RULE_MANUAL="ip saddr @manual_banned drop"
    if ! nft_rule_exists trafficguard TRAFFICGUARD "$RULE_MANUAL"; then
        nft add rule ip trafficguard TRAFFICGUARD "$RULE_MANUAL" 2>/dev/null || warn "添加手动黑名单规则失败"
    fi

    # === 4. 并发连接数限制 ===
    # 单 IP 超出指定个 TCP 状态，直接丢弃新连接 (类似 limit_conn)
    if ! nft list set ip trafficguard conn_limit >/dev/null 2>&1; then
        nft add set ip trafficguard conn_limit '{ type ipv4_addr ; flags dynamic ; size 65535 ; }' 2>/dev/null
    fi
    if [ "${TG_CONN_LIMIT:-0}" -gt 0 ]; then
        RULE_CONN="ct state new add @conn_limit { ip saddr ct count over ${TG_CONN_LIMIT} } drop"
        if ! nft_rule_exists trafficguard TRAFFICGUARD "$RULE_CONN"; then
            nft add rule ip trafficguard TRAFFICGUARD "$RULE_CONN" 2>/dev/null || warn "添加并发限制规则失败"
        fi
    fi

    # === 5. 新建连接频率限制 ===
    # 单 IP 发起新连接超过速率，直接丢弃 (类似 limit_req)
    if ! nft list set ip trafficguard rate_limit >/dev/null 2>&1; then
        nft add set ip trafficguard rate_limit '{ type ipv4_addr ; flags dynamic ; size 65535 ; }' 2>/dev/null
    fi
    if [ "${TG_RATE_LIMIT:-0}" -gt 0 ]; then
        RULE_RATE="ct state new update @rate_limit { ip saddr limit rate over ${TG_RATE_LIMIT}/second burst ${TG_RATE_BURST:-100} packets } drop"
        if ! nft_rule_exists trafficguard TRAFFICGUARD "$RULE_RATE"; then
            nft add rule ip trafficguard TRAFFICGUARD "$RULE_RATE" 2>/dev/null || warn "添加频率限制规则失败"
        fi
    fi

    info "nftables 底层防护墙与统计规则配置完毕"
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
echo "Fail2Ban 配置: /etc/fail2ban/jail.d/trafficguard.conf"
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
echo ""

# 如果在交互式终端中，安装完成后自动启动管理台
if [ -t 0 ] || [ -c /dev/tty ]; then
    if command -v tgctl >/dev/null 2>&1; then
        exec tgctl < /dev/tty
    else
        exec /usr/local/bin/tgctl < /dev/tty
    fi
fi
