#!/usr/bin/env bash
# TrafficGuard 卸载脚本
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || error "请使用 root 运行"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}    TrafficGuard 卸载程序${NC}"
echo -e "${GREEN}========================================${NC}"
echo

# 确认卸载
read -p "确定要卸载 TrafficGuard 吗? (y/n): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    info "已取消卸载"
    exit 0
fi

# 移除 Nginx 配置
info "移除 Nginx 配置"
rm -f /etc/nginx/conf.d/trafficguard.conf
nginx -t && systemctl reload nginx
info "Nginx 配置已移除"

# 移除 Fail2Ban 配置
info "移除 Fail2Ban 配置"
rm -f /etc/fail2ban/filter.d/nginx-limit-req.conf
rm -f /etc/fail2ban/filter.d/nginx-limit-conn.conf
# 注意：不删除 jail.local，因为可能有用户自定义配置
warn "请手动检查 /etc/fail2ban/jail.local 中的 TrafficGuard 相关配置"
systemctl restart fail2ban
info "Fail2Ban 配置已移除"

# 移除命令行工具
info "移除命令行工具"
rm -f /usr/local/bin/tgctl
rm -f /usr/local/bin/traffic-save-stats
rm -f /usr/local/bin/traffic-view-stats
info "命令行工具已移除"

# 移除定时任务
info "移除定时任务"
(crontab -l 2>/dev/null | grep -v "traffic-save-stats") | crontab - 2>/dev/null || true
info "定时任务已移除"

# 移除统计目录
info "移除统计目录"
rm -rf /var/lib/trafficguard/stats
info "统计目录已移除"

# 移除 nftables 表
info "移除 nftables 表"
nft delete table ip trafficguard 2>/dev/null || true
info "nftables 表已移除"

# 清空封禁列表
info "清空 Fail2Ban 封禁列表"
for jail in $(fail2ban-client status 2>/dev/null | grep "Jail list" | cut -d: -f2 | tr ',' ' '); do
    jail=$(echo "$jail" | xargs)
    if [ -n "$jail" ]; then
        fail2ban-client set "$jail" unbanip --all 2>/dev/null || true
    fi
done
info "封禁列表已清空"

echo
info "卸载完成"
echo
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}    TrafficGuard 已卸载${NC}"
echo -e "${GREEN}========================================${NC}"
echo
echo "已移除:"
echo "  - Nginx 配置: /etc/nginx/conf.d/trafficguard.conf"
echo "  - Fail2Ban Filter: /etc/fail2ban/filter.d/nginx-limit-*.conf"
echo "  - 命令行工具: /usr/local/bin/tgctl"
echo "  - nftables 表: trafficguard"
echo
echo "请手动检查:"
echo "  - /etc/fail2ban/jail.local (可能有自定义配置)"
echo
