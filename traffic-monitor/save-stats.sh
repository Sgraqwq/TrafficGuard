#!/usr/bin/env bash
# TrafficGuard - 流量统计保存脚本
# 每小时运行一次，保存流量统计数据

set -euo pipefail

# 配置
STATS_DIR="/var/lib/trafficguard/stats"
LOG_FILE="/var/log/trafficguard/traffic-stats.log"

# 创建目录
mkdir -p "$STATS_DIR"

# 获取当前时间
NOW=$(date +%Y%m%d_%H%M%S)
TODAY=$(date +%Y%m%d)
HOUR=$(date +%H)

# 统计文件
STATS_FILE="$STATS_DIR/traffic_${TODAY}.log"

# 读取当前流量统计
echo "[$NOW] 开始保存流量统计" >> "$LOG_FILE"

# 获取 nftables 流量数据
TRAFFIC_DATA=$(nft list chain ip trafficguard TRAFFICGUARD 2>/dev/null | \
    grep -E "counter|saddr" | \
    awk '{
        for(i=1; i<=NF; i++) {
            if($i == "saddr") ip = $(i+1)
            if($i == "counter") {
                if($(i+1) == "bytes") bytes = $(i+2)
                else if($(i+1) == "packets") packets = $(i+2)
            }
        }
        if(ip != "") printf "%s %s %s\n", ip, packets, bytes
    }')

# 保存到文件
if [ -n "$TRAFFIC_DATA" ]; then
    echo "# $NOW" >> "$STATS_FILE"
    echo "$TRAFFIC_DATA" >> "$STATS_FILE"
    echo "" >> "$STATS_FILE"
    echo "[$NOW] 已保存流量统计到 $STATS_FILE" >> "$LOG_FILE"
else
    echo "[$NOW] 没有流量数据" >> "$LOG_FILE"
fi

# 重置计数器（可选，如果需要重新开始统计）
# nft reset counters table ip trafficguard

echo "[$NOW] 流量统计保存完成" >> "$LOG_FILE"
