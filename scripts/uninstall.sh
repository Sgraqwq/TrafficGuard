#!/usr/bin/env bash
# TrafficGuard 卸载脚本 - 自动卸载，无需确认

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || error "请使用 root 运行"

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}    TrafficGuard 卸载程序${NC}"
echo -e "${YELLOW}========================================${NC}"
echo

# 备份
BACKUP_DIR="/var/backups/trafficguard-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
for f in \
    /etc/nginx/conf.d/trafficguard.conf \
    /etc/fail2ban/jail.local \
    /etc/fail2ban/filter.d/nginx-limit-req.conf \
    /etc/fail2ban/filter.d/nginx-limit-conn.conf; do
    [ -f "$f" ] && cp "$f" "$BACKUP_DIR/" 2>/dev/null || true
done
info "配置已备份到 $BACKUP_DIR"

# 停服务
systemctl stop fail2ban 2>/dev/null || true
info "服务已停止"

# 删 Nginx 配置
rm -f /etc/nginx/conf.d/trafficguard.conf
nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
info "Nginx 配置已移除"

# 删 Fail2Ban filter
rm -f /etc/fail2ban/filter.d/nginx-limit-req.conf /etc/fail2ban/filter.d/nginx-limit-conn.conf

# 清理 jail.local 中的 TG 段
JAIL_FILE="/etc/fail2ban/jail.local"
if [ -f "$JAIL_FILE" ]; then
    cp "$JAIL_FILE" "${JAIL_FILE}.bak" 2>/dev/null || true
    awk '
    /^\[nginx-limit-req\]/ { in_tg = 1; print; next }
    /^\[nginx-limit-conn\]/ { in_tg = 1; print; next }
    /^\[.*\]/ { in_tg = 0 }
    in_tg { print "# " $0; next }
    { print }
    ' "$JAIL_FILE" > "${JAIL_FILE}.tmp" && mv "${JAIL_FILE}.tmp" "$JAIL_FILE"
fi
systemctl start fail2ban 2>/dev/null || true
info "Fail2Ban 配置已清理"

# 删命令行工具
rm -f /usr/local/bin/tgctl /usr/local/bin/traffic-save-stats /usr/local/bin/traffic-view-stats
info "命令行工具已移除"

# 删定时任务
(crontab -l 2>/dev/null | grep -v "traffic-save-stats") | crontab - 2>/dev/null || true
info "定时任务已移除"

# 删目录
rm -rf /var/lib/trafficguard /var/log/trafficguard
info "数据目录已移除"

# 删 nftables 表
nft delete table ip trafficguard 2>/dev/null || true
info "nftables 表已移除"

# 删封禁数据库
rm -f /var/lib/fail2ban/fail2ban.sqlite3 2>/dev/null || true
info "封禁数据库已清理"

echo
info "卸载完成"
echo
echo "备份位于: $BACKUP_DIR"
echo "如需恢复: sudo cp $BACKUP_DIR/* /etc/nginx/conf.d/  && sudo cp $BACKUP_DIR/* /etc/fail2ban/"
