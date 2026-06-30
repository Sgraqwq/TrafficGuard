#!/usr/bin/env bash
# TrafficGuard 卸载脚本
#
# 用法:
#   sudo bash scripts/uninstall.sh          # 交互式
#   sudo bash scripts/uninstall.sh -y       # 自动确认，无需交互
#   curl -fsSL ... | sudo bash -s -- -y     # 管道模式

set -euo pipefail

# ── 颜色与日志 ──────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── 检查 root ────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || error "请使用 root 运行"

# ── 解析参数 ─────────────────────────────────────────────
AUTO_YES=false
for arg in "$@"; do
    case "$arg" in
        -y|--yes) AUTO_YES=true ;;
    esac
done

# ── 确认函数（兼容管道模式） ──────────────────────────────
confirm() {
    local prompt="$1"
    if [ "$AUTO_YES" = true ]; then
        return 0
    fi
    # 检测是否为交互式终端
    if [ -t 0 ]; then
        local ans
        read -p "$prompt [y/N]: " ans </dev/tty
        [[ "$ans" =~ ^[Yy]$ ]] && return 0 || return 1
    else
        # curl | bash 管道模式：无法交互
        warn "非交互式模式，使用 -y 参数跳过确认"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════
#  主流程
# ═══════════════════════════════════════════════════════════

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}    TrafficGuard 卸载程序${NC}"
echo -e "${YELLOW}========================================${NC}"
echo
echo "以下组件将被移除:"
echo "  - Nginx 配置: /etc/nginx/conf.d/trafficguard.conf"
echo "  - Fail2Ban 配置: /etc/fail2ban/filter.d/nginx-limit-*.conf"
echo "  - Fail2Ban Jail 配置（TrafficGuard 相关部分）"
echo "  - 命令行工具: /usr/local/bin/tgctl"
echo "  - 流量统计脚本: /usr/local/bin/traffic-*"
echo "  - 流量统计目录: /var/lib/trafficguard/"
echo "  - 日志目录: /var/log/trafficguard/"
echo "  - 定时任务: traffic-save-stats"
echo "  - nftables 表: ip trafficguard"
echo "  - Fail2Ban 封禁列表"
echo

if ! confirm "确定要卸载 TrafficGuard 吗?"; then
    info "已取消卸载"
    exit 0
fi

echo

# ── 1. 停止服务 ──────────────────────────────────────────
info "停止相关服务..."
systemctl stop fail2ban 2>/dev/null || true
info "Fail2Ban 已停止"

# ── 2. 备份配置（可选） ──────────────────────────────────
BACKUP_DIR="/var/backups/trafficguard-$(date +%Y%m%d_%H%M%S)"
if confirm "是否备份当前配置到 $BACKUP_DIR ?"; then
    mkdir -p "$BACKUP_DIR"
    for f in \
        /etc/nginx/conf.d/trafficguard.conf \
        /etc/fail2ban/jail.local \
        /etc/fail2ban/filter.d/nginx-limit-req.conf \
        /etc/fail2ban/filter.d/nginx-limit-conn.conf; do
        if [ -f "$f" ]; then
            cp "$f" "$BACKUP_DIR/" 2>/dev/null || true
            info "已备份: $f"
        fi
    done
    echo
fi

# ── 3. 移除 Nginx 配置 ──────────────────────────────────
info "移除 Nginx 配置"
if [ -f /etc/nginx/conf.d/trafficguard.conf ]; then
    rm -f /etc/nginx/conf.d/trafficguard.conf
    # 仅剩余 Nginx 配置时再 reload
    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
    info "Nginx 配置已移除"
else
    info "Nginx 配置不存在，跳过"
fi

# ── 4. 移除 Fail2Ban 配置 ────────────────────────────────
info "移除 Fail2Ban Filter"
REMOVED_FILTER=false
for f in /etc/fail2ban/filter.d/nginx-limit-req.conf /etc/fail2ban/filter.d/nginx-limit-conn.conf; do
    if [ -f "$f" ]; then
        rm -f "$f"
        REMOVED_FILTER=true
    fi
done
$REMOVED_FILTER && info "Fail2Ban Filter 已移除" || info "Fail2Ban Filter 不存在，跳过"

# 移除 jail.local 中的 TrafficGuard 相关 jail 段
info "清理 Fail2Ban Jail 配置"
JAIL_FILE="/etc/fail2ban/jail.local"
if [ -f "$JAIL_FILE" ]; then
    # 备份原文件
    cp "$JAIL_FILE" "${JAIL_FILE}.bak" 2>/dev/null || true
    # 只注释 TrafficGuard 专属的 jail 段（nginx-limit-req、nginx-limit-conn）
    # [sshd] 是标准 jail，保留不动
    awk '
    /^\[nginx-limit-req\]/ { in_tg = 1; print; next }
    /^\[nginx-limit-conn\]/ { in_tg = 1; print; next }
    /^\[.*\]/ { in_tg = 0 }
    in_tg { print "# " $0; next }
    { print }
    ' "$JAIL_FILE" > "${JAIL_FILE}.tmp" && mv "${JAIL_FILE}.tmp" "$JAIL_FILE"
    info "Jail 配置已清理（TrafficGuard 专属段已注释，原文件备份为 jail.local.bak）"
fi

# 重启 Fail2Ban
systemctl start fail2ban 2>/dev/null || true
info "Fail2Ban 已重启"

# ── 5. 移除命令行工具 ────────────────────────────────────
info "移除命令行工具"
REMOVED_BIN=false
for f in /usr/local/bin/tgctl /usr/local/bin/traffic-save-stats /usr/local/bin/traffic-view-stats; do
    if [ -f "$f" ]; then
        rm -f "$f"
        REMOVED_BIN=true
    fi
done
$REMOVED_BIN && info "命令行工具已移除" || info "命令行工具不存在，跳过"

# ── 6. 移除定时任务 ──────────────────────────────────────
info "移除定时任务"
if crontab -l 2>/dev/null | grep -q "traffic-save-stats"; then
    (crontab -l 2>/dev/null | grep -v "traffic-save-stats") | crontab - 2>/dev/null || true
    info "定时任务已移除"
else
    info "定时任务不存在，跳过"
fi

# ── 7. 移除目录 ──────────────────────────────────────────
info "移除数据目录"
for d in /var/lib/trafficguard /var/log/trafficguard; do
    if [ -d "$d" ]; then
        rm -rf "$d"
        info "已移除: $d"
    fi
done

# ── 8. 移除 nftables 表 ─────────────────────────────────
info "移除 nftables 表"
if nft list table ip trafficguard >/dev/null 2>&1; then
    nft delete table ip trafficguard 2>/dev/null || true
    info "nftables 表已移除"
else
    info "nftables 表不存在，跳过"
fi

# ── 9. 清空 Fail2Ban 封禁列表 ────────────────────────────
# 注意: Jail 已停，只需清理数据库
info "清理 Fail2Ban 封禁数据库"
rm -f /var/lib/fail2ban/fail2ban.sqlite3 2>/dev/null || true
info "封禁数据库已清理"

# ── 完成 ─────────────────────────────────────────────────
echo
info "卸载完成"
echo
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}    TrafficGuard 已卸载${NC}"
echo -e "${GREEN}========================================${NC}"
echo
echo "已移除:"
echo "  - Nginx 配置"
echo "  - Fail2Ban 配置（TrafficGuard 相关）"
echo "  - 命令行工具"
echo "  - 流量统计脚本和定时任务"
echo "  - 数据目录"
echo "  - nftables 表"
echo "  - Fail2Ban 封禁数据"
echo
if [ -d "$BACKUP_DIR" ]; then
    echo "备份位于: $BACKUP_DIR"
    echo "需要恢复请执行:"
    echo "  sudo cp $BACKUP_DIR/* /etc/nginx/conf.d/"
    echo "  sudo cp $BACKUP_DIR/* /etc/fail2ban/"
    echo
fi
echo "注意:"
echo "  - Nginx 和 Fail2Ban 包未卸载（如需: apt remove nginx fail2ban）"
echo "  - /etc/fail2ban/jail.local.bak 保留以防需要恢复"
