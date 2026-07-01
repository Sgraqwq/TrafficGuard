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
    
    echo -e "${BOLD}时间戳                 IP 地址              入站包    入站字节    出站包    出站字节${NC}"
    echo "------------------------------------------------------------------------"
    
    # 解析并显示数据
    awk '
    /^#/ {
        # 时间戳行：移除 "# " 前缀
        timestamp = substr($0, 3)
        next
    }
    /^[0-9]/ {
        # 数据行：IP in_pkts in_bytes out_pkts out_bytes
        # 转换为 MB
        in_mb = int($3 / 1048576)
        out_mb = int($5 / 1048576)
        printf "%-23s %-18s %-10s %-10s MB %-10s %-10s MB\n", timestamp, $1, ($2 ? $2 : "0"), in_mb, ($4 ? $4 : "0"), out_mb
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
    local date count
    for file in "$STATS_DIR"/traffic_*.log; do
        if [ -f "$file" ]; then
            date=$(basename "$file" | sed 's/traffic_//;s/\.log$//')
            count=$(grep -v "^#" "$file" | grep -v "^$" | wc -l)
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
    
    # 检查 nftables set
    if ! nft list set ip trafficguard inbound_traffic >/dev/null 2>&1; then
        echo -e "${YELLOW}nftables set 'inbound_traffic' 不存在${NC}"
        return
    fi
    if ! nft list set ip trafficguard outbound_traffic >/dev/null 2>&1; then
        echo -e "${YELLOW}nftables set 'outbound_traffic' 不存在${NC}"
        return
    fi
    
    echo -e "${BOLD}IP 地址              入站包    入站字节    出站包    出站字节${NC}"
    echo "--------------------------------------------------------------------"
    
    # 获取入站流量
    INBOUND=$(nft list set ip trafficguard inbound_traffic 2>/dev/null | \
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ counter packets [0-9]+ bytes [0-9]+' 2>/dev/null | \
    awk '{
        ip = $1
        for(i = 1; i <= NF; i++) {
            if($i == "packets") packets = $(i+1)
            if($i == "bytes") bytes = $(i+1)
        }
        if(ip != "") printf "%s %s %s\n", ip, packets, (bytes ? bytes : "0")
    }' || true)
    
    # 获取出站流量
    OUTBOUND=$(nft list set ip trafficguard outbound_traffic 2>/dev/null | \
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ counter packets [0-9]+ bytes [0-9]+' 2>/dev/null | \
    awk '{
        ip = $1
        for(i = 1; i <= NF; i++) {
            if($i == "packets") packets = $(i+1)
            if($i == "bytes") bytes = $(i+1)
        }
        if(ip != "") printf "%s %s %s\n", ip, packets, (bytes ? bytes : "0")
    }' || true)
    
    # 合并并显示（使用临时文件）
    TMPDIR=$(mktemp -d 2>/dev/null || echo "/tmp")
    INBOUND_FILE="$TMPDIR/tg_inbound.txt"
    OUTBOUND_FILE="$TMPDIR/tg_outbound.txt"
    MERGED_FILE="$TMPDIR/tg_merged.txt"
    
    echo "$INBOUND" > "$INBOUND_FILE" 2>/dev/null || true
    echo "$OUTBOUND" > "$OUTBOUND_FILE" 2>/dev/null || true
    
    # 合并数据
    while read -r ip in_pkts in_bytes; do
        out_pkts=0
        out_bytes=0
        if [ -n "$ip" ]; then
            out_line=$(grep "^$ip " "$OUTBOUND_FILE" 2>/dev/null || true)
            if [ -n "$out_line" ]; then
                out_pkts=$(echo "$out_line" | awk '{print $2}')
                out_bytes=$(echo "$out_line" | awk '{print $3}')
            fi
            echo "$ip $in_pkts $in_bytes ${out_pkts:-0} ${out_bytes:-0}"
        fi
    done < "$INBOUND_FILE" > "$MERGED_FILE" 2>/dev/null || true
    
    # 添加仅在出站中出现的 IP
    while read -r ip out_pkts out_bytes; do
        if [ -n "$ip" ] && ! grep -q "^$ip " "$MERGED_FILE" 2>/dev/null; then
            echo "$ip 0 0 $out_pkts $out_bytes"
        fi
    done < "$OUTBOUND_FILE" >> "$MERGED_FILE" 2>/dev/null || true
    
    # 显示结果
    if [ -s "$MERGED_FILE" ]; then
        sort -k3 -rn "$MERGED_FILE" | head -20 | while read -r ip in_pkts in_bytes out_pkts out_bytes; do
            # 转换为 MB
            in_mb=$((in_bytes / 1048576))
            out_mb=$((out_bytes / 1048576))
            printf "%-18s %-10s %-10s MB %-10s %-10s MB\n" "$ip" "$in_pkts" "$in_mb" "$out_pkts" "$out_mb"
        done
    fi
    
    # 清理临时文件
    rm -rf "$TMPDIR" 2>/dev/null || true
    
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
