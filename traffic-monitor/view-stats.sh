#!/usr/bin/env bash
# TrafficGuard - 查看历史流量统计

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# 配置
STATS_DIR="/var/lib/trafficguard/stats"

# 显示帮助
usage() {
    echo "用法: $0 [选项]"
    echo
    echo "选项:"
    echo "  -h, --help      显示帮助信息"
    echo "  -t, --today     查看今天流量"
    echo "  -d, --date DATE 查看指定日期流量 (格式: YYYYMMDD)"
    echo "  -s, --summary   查看流量汇总"
    echo "  -r, --realtime  实时查看当前流量"
    echo
    echo "示例:"
    echo "  $0              # 查看今天流量"
    echo "  $0 -t           # 查看今天流量"
    echo "  $0 -d 20260701  # 查看 2026-07-01 的流量"
    echo "  $0 -s           # 查看流量汇总"
}

# 查看指定日期的流量
show_date_traffic() {
    local date=${1:-$(date +%Y%m%d)}
    local stats_file="$STATS_DIR/traffic_${date}.log"
    
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}    流量统计 - $date${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo
    
    if [ ! -f "$stats_file" ]; then
        echo -e "${YELLOW}没有找到 $date 的流量数据${NC}"
        echo "统计文件: $stats_file"
        return
    fi
    
    echo -e "${BOLD}时间戳                 IP 地址              数据包            字节数${NC}"
    echo "--------------------------------------------------------------------"
    
    # 解析并显示数据
    awk '
    /^#/ {
        # 时间戳行
        timestamp = substr($0, 2)
        next
    }
    /^[0-9]/ {
        # 数据行：IP packets bytes
        printf "%-20s %-20s %-15s %-15s\n", timestamp, $1, $2, $3
    }
    ' "$stats_file"
    
    echo
}

# 查看流量汇总
show_summary() {
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}    流量汇总${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo
    
    if [ ! -d "$STATS_DIR" ] || [ -z "$(ls -A "$STATS_DIR" 2>/dev/null)" ]; then
        echo -e "${YELLOW}没有流量统计数据${NC}"
        echo "请先运行: sudo bash save-stats.sh"
        return
    fi
    
    echo -e "${BOLD}日期                  记录数${NC}"
    echo "----------------------------------------"
    
    # 统计每个日期的记录数
    for file in "$STATS_DIR"/traffic_*.log; do
        if [ -f "$file" ]; then
            local date=$(basename "$file" | sed 's/traffic_//;s/.log//')
            local count=$(grep -v "^#" "$file" | grep -v "^$" | wc -l)
            echo "  $date                  $count"
        fi
    done
    
    echo
}

# 实时查看当前流量
show_realtime() {
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}    实时流量统计${NC}"
    echo -e "${CYAN}    $(date)${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo
    
    # 检查 nftables 表
    if ! nft list table ip trafficguard >/dev/null 2>&1; then
        echo -e "${YELLOW}nftables 表 'trafficguard' 不存在${NC}"
        return
    fi
    
    echo -e "${BOLD}IP 地址              数据包            字节数${NC}"
    echo "----------------------------------------------------"
    
    # 获取当前流量
    nft list chain ip trafficguard TRAFFICGUARD 2>/dev/null | \
    grep -E "counter|saddr" | \
    awk '{
        for(i=1; i<=NF; i++) {
            if($i == "saddr") ip = $(i+1)
            if($i == "counter") {
                if($(i+1) == "bytes") bytes = $(i+2)
                else if($(i+1) == "packets") packets = $(i+2)
            }
        }
        if(ip != "") printf "%-20s %-15s %-15s\n", ip, packets, bytes
    }' | sort -k3 -rn | head -20
    
    echo
}

# 主函数
main() {
    case "${1:-}" in
        -h|--help)
            usage
            ;;
        -t|--today)
            show_date_traffic "$(date +%Y%m%d)"
            ;;
        -d|--date)
            if [ -z "${2:-}" ]; then
                echo -e "${RED}请指定日期${NC}"
                usage
                exit 1
            fi
            show_date_traffic "$2"
            ;;
        -s|--summary)
            show_summary
            ;;
        -r|--realtime)
            show_realtime
            ;;
        "")
            show_date_traffic "$(date +%Y%m%d)"
            ;;
        *)
            echo -e "${RED}未知选项: $1${NC}"
            usage
            exit 1
            ;;
    esac
}

# 运行主函数
main "$@"
