#!/usr/bin/env bash
# TrafficGuard - 流量统计保存脚本
# 每小时运行一次，保存流量统计数据

set -euo pipefail

# 配置
STATS_DIR="/var/lib/trafficguard/stats"
LOG_FILE="/var/log/trafficguard/traffic-stats.log"

# 创建目录
mkdir -p "$STATS_DIR"
mkdir -p "$(dirname "$LOG_FILE")"

# 获取当前时间（单次调用确保一致性）
NOW_FULL=$(date +%Y%m%d_%H%M%S)
TODAY="${NOW_FULL:0:8}"
NOW="${NOW_FULL}"

# 统计文件
STATS_FILE="$STATS_DIR/traffic_${TODAY}.log"

# 读取当前流量统计
echo "[$NOW] 开始保存流量统计" >> "$LOG_FILE"

# 检查 nftables 表是否存在
if ! nft list table ip trafficguard >/dev/null 2>&1; then
    echo "[$NOW] 错误: nftables 表 'trafficguard' 不存在" >> "$LOG_FILE"
    exit 1
fi

# 检查 nftables set 是否存在
if ! nft list set ip trafficguard per_ip_traffic >/dev/null 2>&1; then
    echo "[$NOW] 错误: nftables set 'per_ip_traffic' 不存在" >> "$LOG_FILE"
    exit 1
fi

# 获取 nftables 流量数据（从动态 set 中解析 per-IP 计数）
# 输出格式: elements = { IP1 counter packets X bytes Y, IP2 counter packets Z bytes W }
TRAFFIC_DATA=$(nft list set ip trafficguard per_ip_traffic 2>/dev/null | \
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ counter packets [0-9]+ bytes [0-9]+' 2>/dev/null | \
    awk '{
        ip = $1
        for(i = 1; i <= NF; i++) {
            if($i == "packets") packets = $(i+1)
            if($i == "bytes") bytes = $(i+1)
        }
        if(ip != "" && packets != "" && bytes != "") printf "%s %s %s\n", ip, packets, bytes
    }' || true)

# 验证数据格式
if [ -n "$TRAFFIC_DATA" ]; then
    # 检查每行是否包含 IP、packets、bytes 三个字段
    if ! echo "$TRAFFIC_DATA" | awk 'NF < 3 {exit 1}'; then
        echo "[$NOW] 错误: 流量数据格式异常，跳过保存" >> "$LOG_FILE"
        exit 1
    fi
    
    # ── 大流量自动查杀 ──
    TG_CONF="/etc/trafficguard/trafficguard.conf"
    if [ -f "$TG_CONF" ]; then
        # shellcheck source=/dev/null
        source "$TG_CONF"
    fi
    
    LIMIT_MB="${TG_DAILY_TRAFFIC_LIMIT_MB:-0}"
    if [ "$LIMIT_MB" -gt 0 ]; then
        LIMIT_BYTES=$(( LIMIT_MB * 1024 * 1024 ))
        
        # 获取白名单集合
        WHITELIST=""
        if nft list set ip trafficguard whitelist >/dev/null 2>&1; then
            WHITELIST=$(nft list set ip trafficguard whitelist 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)
        fi
        
        while read -r ip packets bytes; do
            if [ -n "$bytes" ] && [ "$bytes" -gt "$LIMIT_BYTES" ]; then
                # 检查是否在白名单中
                is_whitelisted=0
                for w_ip in $WHITELIST; do
                    if [ "$w_ip" = "$ip" ]; then
                        is_whitelisted=1
                        break
                    fi
                done
                
                if [ "$is_whitelisted" -eq 0 ]; then
                    # 检查是否已经被封禁
                    is_banned=0
                    if nft list set ip trafficguard manual_banned 2>/dev/null | grep -q "$ip"; then
                        is_banned=1
                    fi
                    
                    if [ "$is_banned" -eq 0 ]; then
                        echo "[$NOW] [警告] IP $ip 流量超限 ($((bytes/1048576)) MB > $LIMIT_MB MB)，执行自动封禁！" >> "$LOG_FILE"
                        nft add element ip trafficguard manual_banned { "$ip" } 2>/dev/null || \
                            echo "[$NOW] [错误] 封禁 IP $ip 失败" >> "$LOG_FILE"
                    fi
                fi
            fi
        done <<< "$TRAFFIC_DATA"
    fi
    # ───────────────

    # 原子追加：先写临时文件，再追加到统计文件
    TMPFILE=$(mktemp "$STATS_DIR/.tmp.XXXXXX")
    echo "# $NOW" > "$TMPFILE"
    echo "$TRAFFIC_DATA" >> "$TMPFILE"
    echo "" >> "$TMPFILE"
    cat "$TMPFILE" >> "$STATS_FILE"
    rm -f "$TMPFILE"
    echo "[$NOW] 已保存流量统计到 $STATS_FILE" >> "$LOG_FILE"
else
    echo "[$NOW] 没有流量数据" >> "$LOG_FILE"
fi

# 重置计数器（可选，如果需要重新开始统计）
# nft reset counters table ip trafficguard

echo "[$NOW] 流量统计保存完成" >> "$LOG_FILE"
