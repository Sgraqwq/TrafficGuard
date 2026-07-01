#!/usr/bin/env bash
# TrafficGuard 纯净卸载脚本
# 此脚本将彻底移除 TrafficGuard 的所有组件、规则和数据，且不留备份。
# 
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/Sgraqwq/TrafficGuard/main/scripts/uninstall.sh | sudo bash
#   sudo bash scripts/uninstall.sh

set -euo pipefail

# 颜色与日志
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# 检查 root
[ "$(id -u)" -eq 0 ] || error "请使用 root 运行"

echo -e "${RED}========================================${NC}"
echo -e "${RED}    警告: 纯净卸载 TrafficGuard${NC}"
echo -e "${RED}========================================${NC}"
echo -e "${YELLOW}此操作将完全卸载 TrafficGuard，并彻底删除所有数据（不留备份）。${NC}"
echo -e "${YELLOW}包含所有的历史流量日志、已被封禁的 IP 名单等，都会被永久销毁。${NC}"
echo ""

# 卸载程序将等待 5 秒后开始执行，给用户取消的机会
info "卸载程序将在 5 秒后开始执行... (Ctrl+C 取消)"
sleep 5

echo ""
info "开始纯净卸载..."

# 1. 停止定时任务
info "[-] 清理定时任务..."
if command -v crontab >/dev/null 2>&1; then
    old_crontab=$(crontab -l 2>/dev/null || true)
    if [ -n "$old_crontab" ]; then
        new_crontab=$(echo "$old_crontab" | grep -v 'traffic-save-stats' | grep -v 'tgctl restore' | grep -v 'tg-cleanup-stats' || true)
        if [ -n "$new_crontab" ]; then
            echo "$new_crontab" | crontab - 2>/dev/null || true
        else
            crontab -r 2>/dev/null || true
        fi
    fi
fi

# 2. 停止 Fail2Ban
info "[-] 停止 Fail2Ban 服务..."
if command -v systemctl >/dev/null 2>&1; then
    systemctl stop fail2ban >/dev/null 2>&1 || true
elif command -v rc-service >/dev/null 2>&1; then
    rc-service fail2ban stop >/dev/null 2>&1 || true
else
    service fail2ban stop >/dev/null 2>&1 || true
fi

# 3. 删除 nftables 表
info "[-] 删除 nftables 规则..."
if command -v nft >/dev/null 2>&1; then
    nft delete table ip trafficguard >/dev/null 2>&1 || true
fi

# 4. 清理 Fail2Ban 配置与数据
info "[-] 清理 Fail2Ban 配置与数据..."
rm -f /etc/fail2ban/jail.d/trafficguard.conf

if [ -f /var/lib/fail2ban/fail2ban.sqlite3 ]; then
    rm -f /var/lib/fail2ban/fail2ban.sqlite3 2>/dev/null || true
fi

# 尝试重启 Fail2Ban 以恢复干净状态
if command -v systemctl >/dev/null 2>&1; then
    systemctl start fail2ban >/dev/null 2>&1 || true
elif command -v rc-service >/dev/null 2>&1; then
    rc-service fail2ban start >/dev/null 2>&1 || true
else
    service fail2ban start >/dev/null 2>&1 || true
fi

# 5. 清理配置、数据和日志
info "[-] 删除配置、数据和日志目录..."
rm -rf /etc/trafficguard
rm -rf /var/lib/trafficguard
rm -rf /var/log/trafficguard

# 6. 删除脚本
info "[-] 删除本地脚本..."
rm -f /usr/local/bin/traffic-save-stats
rm -f /usr/local/bin/traffic-view-stats
rm -f /usr/local/bin/tgctl
rm -f /usr/bin/tgctl
rm -f /etc/logrotate.d/trafficguard

if command -v systemctl >/dev/null 2>&1; then
    systemctl disable trafficguard-restore.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/trafficguard-restore.service
    systemctl daemon-reload >/dev/null 2>&1 || true
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}    卸载完成！${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "TrafficGuard 的所有组件、规则和数据都已彻底清除。"
exit 0
