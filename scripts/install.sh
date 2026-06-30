#!/usr/bin/env bash
# TrafficGuard 安装脚本
# 基于 Fail2Ban + Nginx 的流量监控和 IP 封禁工具
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
prompt() { echo -e "${CYAN}[PROMPT]${NC} $*"; }

[ "$(id -u)" -eq 0 ] || error "请使用 root 运行"

# 检测包管理器
detect_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v yum >/dev/null 2>&1; then
        echo "yum"
    else
        echo "unknown"
    fi
}

PKG_MGR=$(detect_package_manager)

# 安装包的函数
install_package() {
    local pkg=$1
    info "安装 $pkg"
    case "$PKG_MGR" in
        apt) apt-get update -qq && apt-get install -y -qq "$pkg" ;;
        dnf) dnf install -y -q "$pkg" ;;
        yum) yum install -y -q "$pkg" ;;
        *) error "无法自动安装 $pkg，请手动安装" ;;
    esac
}

# 检查并安装依赖的函数
check_dependency() {
    local cmd=$1
    local pkg=$2
    local desc=$3

    if command -v "$cmd" >/dev/null 2>&1; then
        info "$desc 已安装: $(command -v $cmd)"
        return 0
    fi

    warn "$desc 未安装"

    # 检测是否为交互式终端（curl | bash 管道模式无法使用 read）
    if [ -t 0 ]; then
        # 交互式终端，通过 /dev/tty 读取用户输入
        local answer
        prompt "是否安装 $desc? (y/n, 默认 y): "
        read -r answer </dev/tty
        answer=${answer:-y}
        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
            error "$desc 是必需的依赖，无法继续安装"
        fi
    else
        # 非交互式（curl | bash），自动安装
        info "非交互式模式，自动安装 $desc..."
    fi

    install_package "$pkg"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        error "安装 $desc 失败，请手动安装后重试"
    fi
    info "$desc 安装成功"
}

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}    TrafficGuard 安装程序${NC}"
echo -e "${GREEN}========================================${NC}"
echo

# 检测并安装依赖
info "检测系统依赖..."
echo

check_dependency "nginx" "nginx" "Nginx Web 服务器"
check_dependency "fail2ban-client" "fail2ban" "Fail2Ban 自动封禁工具"
check_dependency "nft" "nftables" "nftables 防火墙"

echo
info "依赖检测完成"
echo

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 安装 Nginx 配置
info "安装 Nginx 配置"
cp "$SCRIPT_DIR/nginx-limit.conf" /etc/nginx/conf.d/trafficguard.conf
nginx -t && systemctl reload nginx
info "Nginx 配置已安装并重载"

# 安装 Fail2Ban 配置
info "安装 Fail2Ban 配置"
cp "$SCRIPT_DIR/fail2ban-jail.conf" /etc/fail2ban/jail.local
cp "$SCRIPT_DIR/fail2ban-filter/"*.conf /etc/fail2ban/filter.d/
systemctl restart fail2ban
info "Fail2Ban 配置已安装并重启"

# 安装命令行工具
info "安装命令行工具"
chmod +x "$SCRIPT_DIR/../traffic-monitor/tgctl"
cp "$SCRIPT_DIR/../traffic-monitor/tgctl" /usr/local/bin/tgctl
info "命令行工具已安装到 /usr/local/bin/tgctl"

# 安装流量统计脚本
info "安装流量统计脚本"
chmod +x "$SCRIPT_DIR/../traffic-monitor/save-stats.sh"
chmod +x "$SCRIPT_DIR/../traffic-monitor/view-stats.sh"
cp "$SCRIPT_DIR/../traffic-monitor/save-stats.sh" /usr/local/bin/traffic-save-stats
cp "$SCRIPT_DIR/../traffic-monitor/view-stats.sh" /usr/local/bin/traffic-view-stats
info "流量统计脚本已安装"

# 创建统计目录
info "创建统计目录"
mkdir -p /var/lib/trafficguard/stats
mkdir -p /var/log/trafficguard
info "统计目录已创建"

# 设置定时任务
info "设置定时任务（每小时保存一次流量统计）"
(crontab -l 2>/dev/null | grep -v "traffic-save-stats"; echo "0 * * * * /usr/local/bin/traffic-save-stats") | crontab -
info "定时任务已设置"

# 创建 nftables 表（用于流量统计）
info "创建 nftables 流量统计表"
nft add table ip trafficguard 2>/dev/null || true
nft add chain ip trafficguard TRAFFICGUARD 2>/dev/null || true
# 添加 counter 规则，统计所有流量（按源 IP 区分）
nft add rule ip trafficguard TRAFFICGUARD counter 2>/dev/null || true
# 可选：如果需要按源 IP 单独统计，可添加以下规则
# nft add rule ip trafficguard TRAFFICGUARD ip saddr 0.0.0.0/0 counter
info "nftables 表已创建并添加 counter 规则"

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
echo
