#!/usr/bin/env bash
# TrafficGuard - 流量统计保存脚本
# 每小时运行一次，保存流量统计数据

set -euo pipefail

# 安全配置读取
get_config_int() {
    local key="$1"
    local file="$2"
    local default_val="${3:-0}"
    if [ -f "$file" ]; then
        local val
        val=$(grep -E "^${key}=" "$file" 2>/dev/null | head -n1 | cut -d= -f2- | grep -oE '[0-9]+' | head -n1)
        if [ -n "$val" ]; then
            echo "$val"
            return
        fi
    fi
    echo "$default_val"
}

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
if ! nft list set ip trafficguard inbound_traffic >/dev/null 2>&1; then
    echo "[$NOW] 错误: nftables set 'inbound_traffic' 不存在" >> "$LOG_FILE"
    exit 1
fi
if ! nft list set ip trafficguard outbound_traffic >/dev/null 2>&1; then
    echo "[$NOW] 错误: nftables set 'outbound_traffic' 不存在" >> "$LOG_FILE"
    exit 1
fi

# 获取 nftables 入站流量数据（外部 IP 访问本机）
INBOUND_DATA=$(nft list set ip trafficguard inbound_traffic 2>/dev/null | \
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ counter packets [0-9]+ bytes [0-9]+' 2>/dev/null | \
    awk '{
        ip = $1
        for(i = 1; i <= NF; i++) {
            if($i == "packets") packets = $(i+1)
            if($i == "bytes") bytes = $(i+1)
        }
        if(ip != "" && packets != "" && bytes != "") printf "%s %s %s\n", ip, packets, bytes
    }' || true)

# 获取 nftables 出站流量数据（本机访问外部 IP）
OUTBOUND_DATA=$(nft list set ip trafficguard outbound_traffic 2>/dev/null | \
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ counter packets [0-9]+ bytes [0-9]+' 2>/dev/null | \
    awk '{
        ip = $1
        for(i = 1; i <= NF; i++) {
            if($i == "packets") packets = $(i+1)
            if($i == "bytes") bytes = $(i+1)
        }
        if(ip != "" && packets != "" && bytes != "") printf "%s %s %s\n", ip, packets, bytes
    }' || true)

# 合并入站和出站数据
# 输出格式: IP in_packets in_bytes out_packets out_bytes
TRAFFIC_DATA=""
if [ -n "$INBOUND_DATA" ] || [ -n "$OUTBOUND_DATA" ]; then
    TRAFFIC_DATA=$(paste <(echo "$INBOUND_DATA") <(echo "$OUTBOUND_DATA") 2>/dev/null | \
        awk '{
            # 入站数据
            if(NF >= 3 && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
                in_ip = $1; in_pkts = $2; in_bytes = $3
            }
            # 出站数据
            if(NF >= 6 && $4 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
                out_ip = $4; out_pkts = $5; out_bytes = $6
            }
            # 如果只有一个方向有数据
            if(in_ip != "") printf "%s %s %s 0 0\n", in_ip, in_pkts, in_bytes
            if(out_ip != "" && out_ip != in_ip) printf "%s 0 0 %s %s\n", out_ip, out_pkts, out_bytes
        }' || true)
    
    # 如果 paste 失败，使用简单的合并方式
    if [ -z "$TRAFFIC_DATA" ]; then
        # 先处理入站
        if [ -n "$INBOUND_DATA" ]; then
            while read -r ip pkts bytes; do
                echo "$ip $pkts $bytes 0 0"
            done <<< "$INBOUND_DATA"
        fi
        # 再处理出站（只添加不在入站中的 IP）
        if [ -n "$OUTBOUND_DATA" ]; then
            while read -r ip pkts bytes; do
                if ! echo "$INBOUND_DATA" | grep -q "^$ip "; then
                    echo "$ip 0 0 $pkts $bytes"
                fi
            done <<< "$OUTBOUND_DATA"
        fi > /tmp/tg_outbound_only.txt
        TRAFFIC_DATA=$(cat /tmp/tg_outbound_only.txt 2>/dev/null || true)
        rm -f /tmp/tg_outbound_only.txt
    fi
fi

# 验证数据格式
if [ -n "$TRAFFIC_DATA" ]; then
    # 检查每行是否包含 IP、入站packets、入站bytes、出站packets、出站bytes 五个字段
    if ! echo "$TRAFFIC_DATA" | awk 'NF < 5 {exit 1}'; then
        echo "[$NOW] 错误: 流量数据格式异常，跳过保存" >> "$LOG_FILE"
        exit 1
    fi
    
    # ── 大流量自动查杀（基于入站流量） ──
    TG_CONF="/etc/trafficguard/trafficguard.conf"
    LIMIT_MB=$(get_config_int "TG_DAILY_TRAFFIC_LIMIT_MB" "$TG_CONF" "0")
    
    if [ "$LIMIT_MB" -gt 0 ]; then
        LIMIT_BYTES=$(( LIMIT_MB * 1024 * 1024 ))
        
        # 获取白名单集合
        WHITELIST=""
        if nft list set ip trafficguard whitelist >/dev/null 2>&1; then
            WHITELIST=$(nft list set ip trafficguard whitelist 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)
        fi
        
        while read -r ip in_pkts in_bytes out_pkts out_bytes; do
            # 使用入站流量判断是否超限
            if [ -n "$in_bytes" ] && [ "$in_bytes" -gt "$LIMIT_BYTES" ]; then
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
                    if nft list set ip trafficguard manual_banned 2>/dev/null | grep -qE "(^|[^0-9.])${ip//./\\.}([^0-9.]|$)"; then
                        is_banned=1
                    fi
                    
                    if [ "$is_banned" -eq 0 ]; then
                        echo "[$NOW] [警告] IP $ip 入站流量超限 ($((in_bytes/1048576)) MB > $LIMIT_MB MB)，执行自动封禁！" >> "$LOG_FILE"
                        nft add element ip trafficguard manual_banned { "$ip" } 2>/dev/null || \
                            echo "[$NOW] [错误] 封禁 IP $ip 失败" >> "$LOG_FILE"
                    fi
                fi
            fi
        done <<< "$TRAFFIC_DATA"
    fi
    # ───────────────

    # 直接追加到统计文件
    {
        echo "# $NOW"
        echo "$TRAFFIC_DATA"
        echo ""
    } >> "$STATS_FILE"
    
    echo "[$NOW] 已保存流量统计到 $STATS_FILE" >> "$LOG_FILE"
else
    echo "[$NOW] 没有流量数据" >> "$LOG_FILE"
fi

# 重置计数器（可选，如果需要重新开始统计）
# nft reset counters table ip trafficguard

echo "[$NOW] 流量统计保存完成" >> "$LOG_FILE"
