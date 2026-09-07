#!/bin/bash
# =============================================================================
# ePortal 认证守护循环：周期性执行认证检查，失败指数退避
#
# 退避策略: 认证失败时间隔按 60→120→240→480→900s 指数增长（900s 封顶），
#           认证成功立即恢复 CHECK_INTERVAL，防止密码错误时高频撞库触发账号锁定
#
# 认证脚本定位: $EPORTAL_AUTH_SCRIPT 环境变量 → 脚本同目录 eportal-auth.sh
# 配置查找顺序与 eportal-auth.sh 一致（仅使用 CHECK_INTERVAL / STATE_DIR）
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTH_SCRIPT="${EPORTAL_AUTH_SCRIPT:-$SCRIPT_DIR/eportal-auth.sh}"

load_watchdog_config() {
    local conf=""
    if [ -n "${EPORTAL_CONF:-}" ]; then
        [ -f "$EPORTAL_CONF" ] && conf="$EPORTAL_CONF"
    elif [ -f "$SCRIPT_DIR/eportal.conf" ]; then
        conf="$SCRIPT_DIR/eportal.conf"
    elif [ -f /etc/eportal/eportal.conf ]; then
        conf="/etc/eportal/eportal.conf"
    fi
    [ -z "$conf" ] && return 0
    # 环境变量优先级高于配置文件：先快照，加载后回填
    local _i="${CHECK_INTERVAL:-}" _d="${STATE_DIR:-}"
    # shellcheck disable=SC1090
    . "$conf"
    [ -n "$_i" ] && CHECK_INTERVAL="$_i"
    [ -n "$_d" ] && STATE_DIR="$_d"
}

# 计算退避间隔：$1=连续失败次数 $2=基础间隔（秒）
# 失败 1 次 = 2 倍基础，逐次翻倍，900s 封顶；0 次 = 基础间隔
backoff_interval() {
    local fails=$1 base=$2 i interval
    [ "$fails" -le 0 ] && { echo "$base"; return 0; }
    interval=$base
    for ((i=0; i<fails; i++)); do
        interval=$((interval * 2))
        [ "$interval" -ge 900 ] && { echo 900; return 0; }
    done
    echo "$interval"
}

watchdog_main() {
    if [ ! -f "$AUTH_SCRIPT" ]; then
        echo "错误：未找到认证脚本 $AUTH_SCRIPT（可用 EPORTAL_AUTH_SCRIPT 环境变量指定路径）" >&2
        exit 1
    fi

    load_watchdog_config
    CHECK_INTERVAL="${CHECK_INTERVAL:-60}"

    # 状态目录（与主脚本一致的 auto 降级逻辑）
    if [ -z "${STATE_DIR:-}" ] || [ "$STATE_DIR" = "auto" ]; then
        local preferred="${EPORTAL_PREFERRED_STATE_DIR:-/var/lib/eportal}"
        if mkdir -p "$preferred" 2>/dev/null && [ -w "$preferred" ]; then
            STATE_DIR="$preferred"
        else
            STATE_DIR="$HOME/.eportal"
            mkdir -p "$STATE_DIR" 2>/dev/null
        fi
    fi
    mkdir -p "$STATE_DIR" 2>/dev/null
    LOOP_LOG="$STATE_DIR/eportal-watchdog.log"

    local child=""
    cleanup() {
        [ -n "$child" ] && kill "$child" 2>/dev/null
        exit 0
    }
    trap cleanup TERM INT EXIT

    echo "$(date '+%F %T') watchdog 启动: 间隔=${CHECK_INTERVAL}s 认证脚本=$AUTH_SCRIPT 日志=$LOOP_LOG" >> "$LOOP_LOG"

    local fail_count=0 interval
    while true; do
        bash "$AUTH_SCRIPT" >> "$LOOP_LOG" 2>&1 &
        child=$!
        if wait "$child"; then
            child=""
            if [ "$fail_count" -ne 0 ]; then
                echo "$(date '+%F %T') 认证恢复，间隔复位为 ${CHECK_INTERVAL}s" >> "$LOOP_LOG"
            fi
            fail_count=0
            sleep "$CHECK_INTERVAL"
        else
            child=""
            fail_count=$((fail_count+1))
            interval=$(backoff_interval "$fail_count" "$CHECK_INTERVAL")
            echo "$(date '+%F %T') 认证失败 ${fail_count} 次，退避 ${interval}s 后重试" >> "$LOOP_LOG"
            sleep "$interval"
        fi
    done
}

# 被其他脚本 source 时（如测试）不执行主流程
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    watchdog_main
fi
