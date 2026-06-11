#!/bin/bash

# ============================================================
# mem_alert.sh - 内存监控脚本
# 当可用内存低于总内存的 7% 时，执行指定的 curl 命令
# ============================================================

# ---- 配置项 ----
THRESHOLD=7                            # 触发阈值（百分比）
CHECK_INTERVAL=1                        # 检查间隔（秒）
CURL_LOG="/data1/log/mem_alert_curl.html"   # curl 输出日志文件

CURL_CMD='curl -XGET http://127.0.0.1:8040/memz'

# ---- 日志函数 ----
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# ---- 主循环 ----
log "内存监控启动，阈值=${THRESHOLD}%，检查间隔=${CHECK_INTERVAL}s"

while true; do
    # 读取内存信息（单位：kB）
    TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    AVAIL_KB=$(grep MemAvailable /proc/meminfo | awk '{print $2}')

    # 转换为 MB（方便日志阅读）
    AVAIL_MB=$(( AVAIL_KB / 1024 ))
    TOTAL_MB=$(( TOTAL_KB / 1024 ))

    # 计算可用百分比（整数，避免 bc 依赖）
    AVAIL_PCT=$(( AVAIL_KB * 100 / TOTAL_KB ))

    log "可用内存: ${AVAIL_MB} MB / ${TOTAL_MB} MB (${AVAIL_PCT}%)"

    if [ "$AVAIL_PCT" -lt "$THRESHOLD" ]; then
        log "⚠️  触发告警！可用内存 ${AVAIL_PCT}% < ${THRESHOLD}%，执行 curl..."
        echo "=== $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$CURL_LOG"
        eval "$CURL_CMD" >> "$CURL_LOG" 2>&1
        CURL_EXIT=$?
        if [ $CURL_EXIT -eq 0 ]; then
            log "curl 执行成功，结果已写入 $CURL_LOG，脚本退出"
        else
            log "curl 执行失败，退出码: $CURL_EXIT，详情见 $CURL_LOG"
        fi
        exit $CURL_EXIT
    fi

    sleep "$CHECK_INTERVAL"
done
