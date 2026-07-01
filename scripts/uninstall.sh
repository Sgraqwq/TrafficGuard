#!/usr/bin/env bash
# TrafficGuard 卸载脚本
# 基于 Fail2Ban + Nginx 的流量监控和 IP 封禁工具
#
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/Sgraqwq/TrafficGuard/main/scripts/uninstall.sh | sudo bash
#   sudo bash scripts/uninstall.sh
#
# 环境变量:
#   TG_REPO=https://github.com/Sgraqwq/TrafficGuard   # 自定义仓库地址

set -euo pipefail

# 仓库地址
TG_REPO="${TG_REPO:-https://github.com/Sgraqwq/TrafficGuard}"

# URL 验证
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

# 加载公共库
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

# Trap 处理
trap cleanup_temp EXIT INT TERM

# 检查 root
[ "$(id -u)" -eq 0 ] || error "请使用 root 运行"

# 系统环境检测
INIT_SYSTEM=$(detect_init_system)
FW_BACKEND=$(detect_firewall_backend)

info "系统环境:"
info "  初始化系统: $INIT_SYSTEM"
info "  防火墙后端: $FW_BACKEND"
echo ""

# 卸载开始

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}    TrafficGuard 卸载程序${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""

# 0. 服务状态跟踪
info "检测服务运行状态..."
FAIL2BAN_WAS_ACTIVE=false
NGINX_WAS_ACTIVE=false

if service_is_active fail2ban "$INIT_SYSTEM"; then
    FAIL2BAN_WAS_ACTIVE=true
    info "  Fail2Ban 当前运行中"
else
    info "  Fail2Ban 未运行"
fi

if service_is_active nginx "$INIT_SYSTEM"; then
    NGINX_WAS_ACTIVE=true
    info "  Nginx 当前运行中"
else
    info "  Nginx 未运行"
fi
echo ""

# 1. 备份配置
info "备份配置文件..."
BACKUP_DIR="/var/backups/trafficguard-$(date +%Y%m%d_%H%M%S)"

backup_file() {
    local src="$1"
    if [ -f "$src" ]; then
        local dest_dir="${BACKUP_DIR}${src}"
        mkdir -p "$(dirname "$dest_dir")" 2>/dev/null || warn "创建备份目录失败: $(dirname "$dest_dir")"
        cp "$src" "$dest_dir" 2>/dev/null || warn "备份失败: $src"
        info "  已备份: $src"
    fi
}

backup_file /etc/nginx/conf.d/trafficguard.conf
backup_file /etc/fail2ban/jail.local
backup_file /etc/fail2ban/jail.d/trafficguard.conf
backup_file /etc/fail2ban/filter.d/nginx-limit-req.conf
backup_file /etc/fail2ban/filter.d/nginx-limit-conn.conf

info "配置已备份到 $BACKUP_DIR"
echo ""

# 2. 停止服务
info "停止服务..."
service_control stop fail2ban "$INIT_SYSTEM" 2>/dev/null || true
info "Fail2Ban 已停止"

# 3. 删除 Fail2Ban 数据库（在重启服务之前）
if [ -f /var/lib/fail2ban/fail2ban.sqlite3 ]; then
    rm -f /var/lib/fail2ban/fail2ban.sqlite3 2>/dev/null || true
    info "封禁数据库已清理"
fi

# 4. 删除 nftables 表（在重启服务之前）
nft_delete_table_safe trafficguard
info "nftables 表已移除"

# 5. 删除 Nginx 配置
NGINX_CONF_DIR=$(detect_nginx_conf_dir)
rm -f "$NGINX_CONF_DIR/trafficguard.conf" 2>/dev/null || true
info "Nginx 配置已移除"

# 仅当 Nginx 之前运行中时才测试配置并重载
if [ "$NGINX_WAS_ACTIVE" = true ]; then
    if nginx -t 2>/dev/null; then
        service_control reload nginx "$INIT_SYSTEM" 2>/dev/null || true
        info "Nginx 已重新加载"
    else
        warn "Nginx 配置测试失败，请手动检查配置"
    fi
fi

# 6. 删除 Fail2Ban 配置
# 删除 filter 文件
rm -f /etc/fail2ban/filter.d/nginx-limit-req.conf 2>/dev/null || true
rm -f /etc/fail2ban/filter.d/nginx-limit-conn.conf 2>/dev/null || true
info "Fail2Ban filter 已移除"

# 删除 jail.d/trafficguard.conf（新格式）
rm -f /etc/fail2ban/jail.d/trafficguard.conf 2>/dev/null || true
info "Fail2Ban jail.d 配置已移除"

# 清理旧的 jail.local（向后兼容）
JAIL_FILE="/etc/fail2ban/jail.local"
if [ -f "$JAIL_FILE" ]; then
    # 先备份
    cp "$JAIL_FILE" "${JAIL_FILE}.bak" 2>/dev/null || true
    # 使用 awk 注释掉 TrafficGuard 添加的配置段
    awk '
    /^\[nginx-limit-req\]/ { in_tg = 1; print; next }
    /^\[nginx-limit-conn\]/ { in_tg = 1; print; next }
    /^\[.*\]/                { in_tg = 0 }
    in_tg                    { print "# " $0; next }
    { print }
    ' "$JAIL_FILE" > "${JAIL_FILE}.tmp" 2>/dev/null && mv "${JAIL_FILE}.tmp" "$JAIL_FILE" 2>/dev/null || true

    # 如果文件只剩空行和注释则删除
    if [ -f "$JAIL_FILE" ]; then
        NON_BLANK=$(grep -cEv '^\s*(#|$)' "$JAIL_FILE" 2>/dev/null || echo "0")
        if [ "$NON_BLANK" -eq 0 ] 2>/dev/null; then
            rm -f "$JAIL_FILE" 2>/dev/null || true
        fi
    fi
    info "jail.local 已清理"
fi

# 7. 启动 Fail2Ban（仅当之前运行中）
if [ "$FAIL2BAN_WAS_ACTIVE" = true ]; then
    service_control start fail2ban "$INIT_SYSTEM" 2>/dev/null || true
    info "Fail2Ban 已重新启动"
fi
info "Fail2Ban 配置已清理"
echo ""

# 8. 删除命令行工具
rm -f /usr/local/bin/tgctl 2>/dev/null || true
rm -f /usr/bin/tgctl 2>/dev/null || true
rm -f /usr/local/bin/traffic-save-stats 2>/dev/null || true
rm -f /usr/local/bin/traffic-view-stats 2>/dev/null || true
info "命令行工具已移除"

# 9. 删除定时任务
if crontab -l 2>/dev/null | grep -q "traffic-save-stats"; then
    (crontab -l 2>/dev/null | grep -v "traffic-save-stats") | crontab - 2>/dev/null || true
    info "定时任务已移除"
else
    info "未发现 TrafficGuard 定时任务，跳过"
fi

# 10. 删除数据目录
rm -rf /var/lib/trafficguard 2>/dev/null || true
rm -rf /var/log/trafficguard 2>/dev/null || true
info "数据目录已移除"

# 完成
echo ""
info "卸载完成"
echo ""
echo "备份位于: $BACKUP_DIR"
echo ""
echo "如需恢复，请按照原始路径逐一复制:"
echo ""
for f in \
    /etc/nginx/conf.d/trafficguard.conf \
    /etc/fail2ban/jail.local \
    /etc/fail2ban/jail.d/trafficguard.conf \
    /etc/fail2ban/filter.d/nginx-limit-req.conf \
    /etc/fail2ban/filter.d/nginx-limit-conn.conf; do
    backup_path="${BACKUP_DIR}${f}"
    if [ -f "$backup_path" ]; then
        echo "  sudo cp ${backup_path} ${f}"
    fi
done
echo ""
echo "恢复后建议重启服务:"
echo "  sudo systemctl restart fail2ban"
echo "  sudo systemctl restart nginx"
