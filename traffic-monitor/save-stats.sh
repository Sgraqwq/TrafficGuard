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

# 并发锁：防止多个实例同时执行导致统计文件损坏
mkdir -p /var/lock 2>/dev/null || true
LOCK_FILE="/var/lock/tg-save-stats.lock"
if command -v flock >/dev/null 2>&1; then
    exec 9>>"$LOCK_FILE"
    flock -n 9 2>/dev/null || { echo "[$(date +%Y%m%d_%H%M%S)] 另一个实例正在运行，跳过本次执行" >> "$LOG_FILE"; exit 0; }
else
    # flock 不可用时（比如 busybox）用 mkdir 实现原子锁
    LOCK_DIR="/var/run/tg-save-stats.lock"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "[$(date +%Y%m%d_%H%M%S)] 另一个实例正在运行，跳过本次执行" >> "$LOG_FILE"
        exit 0
    fi
    trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
fi

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
    TMPDIR_STATS=$(mktemp -d /tmp/tg_stats_XXXXXX 2>/dev/null) || { TMPDIR_STATS="/tmp/tg_stats_$$"; mkdir -p "$TMPDIR_STATS" 2>/dev/null || true; }
    INBOUND_FILE="$TMPDIR_STATS/inbound.txt"
    OUTBOUND_FILE="$TMPDIR_STATS/outbound.txt"
    MERGED_FILE="$TMPDIR_STATS/merged.txt"
    
    echo "$INBOUND_DATA" > "$INBOUND_FILE" 2>/dev/null || true
    echo "$OUTBOUND_DATA" > "$OUTBOUND_FILE" 2>/dev/null || true
    
    # 合并数据：以入站为主，匹配出站
    if [ -s "$INBOUND_FILE" ]; then
        while read -r ip in_pkts in_bytes; do
            out_pkts=0
            out_bytes=0
            if [ -n "$ip" ]; then
                out_line=$(grep -F "$ip " "$OUTBOUND_FILE" 2>/dev/null | head -1 || true)
                if [ -n "$out_line" ]; then
                    out_pkts=$(echo "$out_line" | awk '{print $2}')
                    out_bytes=$(echo "$out_line" | awk '{print $3}')
                fi
                echo "$ip ${in_pkts:-0} ${in_bytes:-0} ${out_pkts:-0} ${out_bytes:-0}"
            fi
        done < "$INBOUND_FILE" > "$MERGED_FILE" 2>/dev/null || true
    fi
    
    # 添加仅在出站中出现的 IP
    if [ -s "$OUTBOUND_FILE" ]; then
        while read -r ip out_pkts out_bytes; do
            if [ -n "$ip" ] && ! grep -qF "$ip " "$MERGED_FILE" 2>/dev/null; then
                echo "$ip 0 0 ${out_pkts:-0} ${out_bytes:-0}"
            fi
        done < "$OUTBOUND_FILE" >> "$MERGED_FILE" 2>/dev/null || true
    fi
    
    if [ -s "$MERGED_FILE" ]; then
        TRAFFIC_DATA=$(cat "$MERGED_FILE")
    fi
    
    rm -rf "$TMPDIR_STATS" 2>/dev/null || true
fi

# 验证数据格式
if [ -n "$TRAFFIC_DATA" ]; then
    # 检查每行是否包含 IP、入站packets、入站bytes、出站packets、出站bytes 五个字段
    if ! echo "$TRAFFIC_DATA" | awk 'NF < 5 {exit 1}'; then
        echo "[$NOW] 错误: 流量数据格式异常，跳过保存" >> "$LOG_FILE"
        exit 1
    fi
    
    # ── 大流量自动查杀（基于今日入站流量增量） ──
    TG_CONF="/etc/trafficguard/trafficguard.conf"
    LIMIT_MB=$(get_config_int "TG_DAILY_TRAFFIC_LIMIT_MB" "$TG_CONF" "0")
    
    if [ "$LIMIT_MB" -gt 0 ]; then
        LIMIT_BYTES=$(( LIMIT_MB * 1024 * 1024 ))
        
        # 获取白名单集合（失败时保持为空，不封禁任何人）
        WHITELIST=""
        if nft list set ip trafficguard whitelist >/dev/null 2>&1; then
            WHITELIST=$(nft list set ip trafficguard whitelist 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)
        fi
        
        # 读取今日已记录的历史快照，计算本次增量
        # 今日统计文件中的最后一次记录作为基准
        PREV_SNAPSHOT=""
        if [ -f "$STATS_FILE" ]; then
            # 找到今天文件中每个 IP 的最大 in_bytes（最近一次记录）
            PREV_SNAPSHOT=$(awk '/^[0-9]/{
                if (!seen[$1] || $3 > max_bytes[$1]) {
                    seen[$1] = 1; max_bytes[$1] = $3
                }
            } END {
                for (ip in max_bytes) printf "%s %s\n", ip, max_bytes[ip]
            }' "$STATS_FILE" 2>/dev/null || true)
        fi
        
        while read -r ip in_pkts in_bytes out_pkts out_bytes; do
            # 验证 in_bytes 是整数
            if [ -z "$in_bytes" ] || ! [[ "$in_bytes" =~ ^[0-9]+$ ]]; then
                continue
            fi
            
            # 计算今日增量（当前值 - 上次快照值）
            prev_bytes=0
            if [ -n "$PREV_SNAPSHOT" ]; then
                prev_line=$(echo "$PREV_SNAPSHOT" | grep -F "$ip " | head -1 || true)
                if [ -n "$prev_line" ]; then
                    prev_bytes=$(echo "$prev_line" | awk '{print $2}')
                    [[ "$prev_bytes" =~ ^[0-9]+$ ]] || prev_bytes=0
                fi
            fi
            delta_bytes=$(( in_bytes - prev_bytes ))
            [ "$delta_bytes" -lt 0 ] && delta_bytes="$in_bytes"  # 计数器重置后差值为负，用绝对值
            
            if [ "$delta_bytes" -gt "$LIMIT_BYTES" ]; then
                # 检查是否在白名单中（精确匹配）
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
                    if nft list set ip trafficguard manual_banned 2>/dev/null | grep -qF "$ip"; then
                        is_banned=1
                    fi
                    
                    if [ "$is_banned" -eq 0 ]; then
                        echo "[$NOW] [警告] IP $ip 今日入站流量超限 ($((delta_bytes/1048576)) MB > $LIMIT_MB MB)，执行自动封禁！" >> "$LOG_FILE"
                        nft add element ip trafficguard manual_banned { "$ip" } 2>/dev/null || \
                            echo "[$NOW] [错误] 封禁 IP $ip 失败" >> "$LOG_FILE"
                        # 原子写入持久化黑名单（防止崩溃导致文件损坏）
                        _banned_tmp=$(mktemp "/etc/trafficguard/manual_banned.XXXXXX" 2>/dev/null) || true
                        if [ -n "$_banned_tmp" ]; then
                            if nft list set ip trafficguard manual_banned 2>/dev/null \
                                    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' > "$_banned_tmp" 2>/dev/null; then
                                mv -f "$_banned_tmp" /etc/trafficguard/manual_banned.txt 2>/dev/null || rm -f "$_banned_tmp"
                            else
                                rm -f "$_banned_tmp"
                            fi
                        fi
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
