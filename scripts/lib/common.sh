#!/usr/bin/env bash
# TrafficGuard 公共函数库
# 被 install.sh 和 uninstall.sh 加载

# ── 颜色与日志 ──────────────────────────────────────────
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[0;33m'
export CYAN='\033[0;36m'
export NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── 临时文件追踪 ────────────────────────────────────────
TEMP_FILES=""

# 清理临时文件，脚本退出时自动调用
cleanup_temp() {
    local exit_code=$?
    for f in $TEMP_FILES; do
        rm -f "$f" 2>/dev/null || true
    done
    if [ $exit_code -ne 0 ] && [ $exit_code -ne 130 ] && [ $exit_code -ne 143 ]; then
        # 非正常退出（非 0、非 INT(130)、非 TERM(143)）时提示
        warn "脚本执行失败 (退出码: $exit_code)"
    fi
}

# ── 原子写入 ─────────────────────────────────────────────
# 使用 mktemp + mv 模式，避免中断留下部分配置
write_file_atomic() {
    local dst="$1"
    local tmp_dir
    tmp_dir="$(dirname "$dst")"
    local tmp

    tmp=$(mktemp) || error "创建临时文件失败"
    TEMP_FILES="$TEMP_FILES $tmp"

    cat > "$tmp" || { error "写入临时文件失败: $dst"; }
    mkdir -p "$tmp_dir" || { error "创建目录失败: $tmp_dir"; }
    mv "$tmp" "$dst" || { error "移动文件失败: $dst"; }

    # 已成功移至目标路径，从追踪列表移除
    TEMP_FILES="${TEMP_FILES// "$tmp"/}"
}

# ── 初始化系统检测 ──────────────────────────────────────
# 返回值: systemd / openrc / sysvinit / unknown
detect_init_system() {
    # 方法1: 检查 /run/systemd/system 目录（最可靠）
    if [ -d /run/systemd/system ]; then
        echo "systemd"
        return 0
    fi
    
    # 方法2: 检查 systemctl 命令
    if command -v systemctl >/dev/null 2>&1; then
        echo "systemd"
        return 0
    fi
    
    # 方法3: 检查 OpenRC
    if command -v rc-service >/dev/null 2>&1; then
        echo "openrc"
        return 0
    fi
    
    # 方法4: 检查 SysVinit
    if command -v service >/dev/null 2>&1; then
        echo "sysvinit"
        return 0
    fi
    
    echo "unknown"
}

# ── 防火墙后端检测 ──────────────────────────────────────
# 返回值: nftables / iptables / unknown
detect_firewall_backend() {
    if command -v nft >/dev/null 2>&1; then
        echo "nftables"
    elif command -v iptables >/dev/null 2>&1; then
        echo "iptables"
    else
        echo "unknown"
    fi
}

# ── Fail2Ban 版本检测 ──────────────────────────────────
# 返回值: 版本号 (如 "0.9", "1.0") / unknown / not_installed
detect_fail2ban_version() {
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        echo "not_installed"
        return 0
    fi
    local ver
    ver=$(fail2ban-client --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' || echo "unknown")
    echo "$ver"
}

# ── Nginx 配置目录检测 ─────────────────────────────────
# 返回值: 目录路径，默认 /etc/nginx/conf.d
detect_nginx_conf_dir() {
    for dir in /etc/nginx/conf.d /etc/nginx/sites-enabled /etc/nginx/http.d; do
        if [ -d "$dir" ]; then
            echo "$dir"
            return 0
        fi
    done
    echo "/etc/nginx/conf.d"
}

# ── 认证日志路径检测 ────────────────────────────────────
# 返回值: 日志文件路径，默认 /var/log/auth.log
detect_auth_log() {
    for f in /var/log/auth.log /var/log/secure /var/log/messages; do
        if [ -f "$f" ]; then
            echo "$f"
            return 0
        fi
    done
    echo "/var/log/auth.log"
}

# ── 统一服务管理 ────────────────────────────────────────
# 参数: <action> <service> [init_system]
#   action: start|stop|restart|reload|status|enable|disable
#   service: 服务名称
#   init_system: 自动检测（可选覆盖）
service_control() {
    local action=$1
    local service=$2
    local init_system="${3:-}"

    if [ -z "$init_system" ]; then
        init_system=$(detect_init_system)
    fi

    case "$init_system" in
        systemd)
            case "$action" in
                enable|disable) systemctl "$action" "$service" ;;
                *)              systemctl "$action" "$service" ;;
            esac
            ;;
        openrc)
            rc-service "$service" "$action"
            ;;
        sysvinit)
            service "$service" "$action"
            ;;
        *)
            warn "不支持的 init 系统: $init_system"
            return 1
            ;;
    esac
}

# 检查服务是否运行中
# 参数: <service> [init_system]
service_is_active() {
    local service=$1
    local init_system="${2:-}"
    local result

    if [ -z "$init_system" ]; then
        init_system=$(detect_init_system)
    fi

    case "$init_system" in
        systemd)
            systemctl is-active --quiet "$service" 2>/dev/null
            result=$?
            ;;
        *)
            service_control status "$service" "$init_system" >/dev/null 2>&1
            result=$?
            ;;
    esac
    return $result
}

# ── nftables 安全操作 ─────────────────────────────────
# 检查 nftables 表是否存在
nft_table_exists() {
    local table=$1
    nft list tables 2>/dev/null | grep -q "^table ip ${table}$" 2>/dev/null
}

# 检查 nftables 链是否存在
nft_chain_exists() {
    local table=$1
    local chain=$2
    nft list chain ip "$table" "$chain" >/dev/null 2>&1
}

# 检查 nftables 规则是否已存在
nft_rule_exists() {
    local table=$1
    local chain=$2
    local rule=$3
    if nft_chain_exists "$table" "$chain"; then
        nft list chain ip "$table" "$chain" 2>/dev/null | grep -qFe "$rule"
        return $?
    fi
    return 1
}

# 安全创建 nftables 表（已存在则跳过）
nft_create_table_safe() {
    local table=$1
    if ! nft_table_exists "$table"; then
        nft add table ip "$table" 2>/dev/null || warn "创建 nftables 表 '$table' 失败"
    fi
}

# 安全创建 nftables 链（已存在则跳过）
nft_create_chain_safe() {
    local table=$1
    local chain=$2
    if ! nft_chain_exists "$table" "$chain"; then
        nft add chain ip "$table" "$chain" 2>/dev/null || warn "创建 nftables 链 '$chain' 失败"
    fi
}

# 安全删除 nftables 表（不存在则跳过）
nft_delete_table_safe() {
    local table=$1
    if nft_table_exists "$table"; then
        nft delete table ip "$table" 2>/dev/null || warn "删除 nftables 表 '$table' 失败"
    fi
}

# ── nftables 可用性检查 ────────────────────────────────
check_nftables_available() {
    if ! command -v nft >/dev/null 2>&1; then
        error "nftables 未安装，请安装 nftables 后重试"
    fi
    # 检查 nftables 内核模块是否可用
    if ! nft list tables >/dev/null 2>&1; then
        warn "nftables 内核模块未加载，尝试加载..."
        modprobe nf_tables 2>/dev/null || true
        sleep 1
        if ! nft list tables >/dev/null 2>&1; then
            error "nftables 不可用（内核可能不支持），请检查后重试"
        fi
        info "nftables 内核模块加载成功"
    fi
}
