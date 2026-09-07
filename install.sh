#!/bin/bash
# =============================================================================
# 锐捷 ePortal 自动认证脚本 - 一键安装 / 更新 / 卸载
#
# 用法:
#   sudo ./install.sh              安装或更新（更新时自动停止旧进程并重启服务）
#   sudo ./install.sh --uninstall  卸载（保留配置文件）
#
# 自动识别运行环境:
#   OpenWrt  → 安装 procd init 服务（/etc/init.d/eportal）
#   systemd  → 安装 systemd 服务（eportal.service）
#   其他     → 打印 crontab 使用示例
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTH_SRC="$SCRIPT_DIR/eportal-auth.sh"
WATCHDOG_SRC="$SCRIPT_DIR/eportal-watchdog.sh"
EXAMPLE_SRC="$SCRIPT_DIR/eportal.conf.example"
OPENWRT_INIT_SRC="$SCRIPT_DIR/init/openwrt-init-eportal"
SYSTEMD_UNIT_SRC="$SCRIPT_DIR/init/eportal.service"

info() { echo "[信息] $*"; }
warn() { echo "[警告] $*" >&2; }
die()  { echo "[错误] $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法:
  ./install.sh              安装或更新（更新时自动重启服务）
  ./install.sh --uninstall  卸载（保留配置文件）
EOF
}

detect_env() {
    if [ -f /etc/openwrt_release ]; then
        echo "openwrt"; return
    fi
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        echo "systemd"; return
    fi
    echo "generic"
}

# 配置文件中的账号密码是否已填写
conf_is_configured() {
    local f="$1"
    [ -f "$f" ] || return 1
    ( . "$f"; [ -n "${EP_USER:-}" ] && [ -n "${EP_PASS:-}" ] )
}

# 更新/卸载前：停止服务并清理所有旧 watchdog 进程
stop_and_clean() {
    if [ -x /etc/init.d/eportal ]; then
        /etc/init.d/eportal stop >/dev/null 2>&1
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop eportal >/dev/null 2>&1
    fi
    pkill -f 'eportal-watchdog' >/dev/null 2>&1
    sleep 1
}

print_cron_example() {
    local bin="$1"
    cat <<EOF

当前环境未识别出 OpenWrt/systemd，可使用 cron 托管（每分钟检查一次）:

  (crontab -l 2>/dev/null; echo '* * * * * $bin') | crontab -

或手动在 crontab (-e) 中加入一行:

  * * * * * $bin
EOF
}

print_start_hint() {
    if [ "$1" = "openwrt" ]; then
        echo "下一步: 编辑 $CONF_FILE 填写 EP_USER / EP_PASS 后，执行: /etc/init.d/eportal start"
    else
        echo "下一步: 编辑 $CONF_FILE 填写 EP_USER / EP_PASS 后，执行: systemctl start eportal"
    fi
}

# ------------------------------ 卸载 ------------------------------

do_uninstall() {
    info "开始卸载 ePortal 自动认证..."
    stop_and_clean

    rm -f /usr/bin/eportal-auth.sh /usr/bin/eportal-watchdog.sh
    info "已移除认证脚本"

    if [ -x /etc/init.d/eportal ]; then
        /etc/init.d/eportal disable >/dev/null 2>&1
        rm -f /etc/init.d/eportal
        info "已移除 OpenWrt init 服务"
    fi
    if command -v systemctl >/dev/null 2>&1 && [ -f /etc/systemd/system/eportal.service ]; then
        systemctl disable eportal >/dev/null 2>&1
        rm -f /etc/systemd/system/eportal.service
        systemctl daemon-reload >/dev/null 2>&1
        info "已移除 systemd 服务"
    fi

    local kept=0
    local f
    for f in /etc/eportal/eportal.conf "$HOME/.eportal/eportal.conf"; do
        if [ -f "$f" ]; then
            info "配置文件已保留: $f（如需彻底删除请手动移除）"
            kept=1
        fi
    done
    [ $kept -eq 0 ] && info "未发现配置文件"
    info "卸载完成"
}

# ------------------------------ 安装/更新 ------------------------------

do_install() {
    # ---- 1. 依赖检查 ----
    local miss=""
    command -v curl >/dev/null 2>&1    || miss="$miss curl"
    command -v openssl >/dev/null 2>&1 || miss="$miss openssl"
    [ -n "$miss" ] && die "缺少依赖:$miss —— OpenWrt: opkg install curl openssl-util; Debian/Ubuntu: apt install$miss"
    command -v ip >/dev/null 2>&1 || warn "未检测到 ip 命令(iproute2): 自动探测出口网卡不可用，稍后请在配置中手动设置 WAN_IF"
    command -v bash >/dev/null 2>&1 || warn "未检测到 bash —— OpenWrt 需先执行: opkg install bash"

    local ENV_TYPE
    ENV_TYPE=$(detect_env)
    info "运行环境: $ENV_TYPE"

    # ---- 2. 更新场景：先停止旧进程再替换文件 ----
    if [ -f /usr/bin/eportal-auth.sh ] || [ -x /etc/init.d/eportal ] || [ -f /etc/systemd/system/eportal.service ]; then
        info "检测到已有安装，先停止旧进程再更新（配置文件将保留）"
        stop_and_clean
    fi

    # ---- 3. 安装脚本 ----
    local AUTH_BIN WATCHDOG_BIN BIN_INSTALLED=0
    if cp "$AUTH_SRC" /usr/bin/eportal-auth.sh 2>/dev/null && cp "$WATCHDOG_SRC" /usr/bin/eportal-watchdog.sh 2>/dev/null; then
        chmod 755 /usr/bin/eportal-auth.sh /usr/bin/eportal-watchdog.sh
        AUTH_BIN=/usr/bin/eportal-auth.sh
        WATCHDOG_BIN=/usr/bin/eportal-watchdog.sh
        BIN_INSTALLED=1
        info "认证脚本已安装: $AUTH_BIN"
    else
        AUTH_BIN="$AUTH_SRC"
        WATCHDOG_BIN="$WATCHDOG_SRC"
        chmod +x "$AUTH_BIN" "$WATCHDOG_BIN" 2>/dev/null
        warn "/usr/bin 不可写（建议用 root 运行）。脚本将从仓库目录运行: $SCRIPT_DIR"
    fi

    # ---- 4. 配置文件（已存在则保留）----
    local CONF_FILE
    if mkdir -p /etc/eportal 2>/dev/null && [ -w /etc/eportal ]; then
        CONF_FILE=/etc/eportal/eportal.conf
    else
        mkdir -p "$HOME/.eportal" 2>/dev/null || die "无法创建配置目录 $HOME/.eportal"
        CONF_FILE="$HOME/.eportal/eportal.conf"
        warn "使用用户级配置文件: $CONF_FILE"
    fi
    if [ -f "$CONF_FILE" ]; then
        info "配置文件已存在，保留不动: $CONF_FILE"
    else
        cp "$EXAMPLE_SRC" "$CONF_FILE" || die "复制配置模板失败"
        info "已生成配置文件: $CONF_FILE"
    fi

    # ---- 5. 服务注册（不立即启动，待配置完成后统一启动）----
    local CONFIGURED=0 SERVICE_REGISTERED=""
    conf_is_configured "$CONF_FILE" && CONFIGURED=1

    if [ "$ENV_TYPE" = "openwrt" ]; then
        if [ $BIN_INSTALLED -eq 1 ] && cp "$OPENWRT_INIT_SRC" /etc/init.d/eportal 2>/dev/null; then
            chmod +x /etc/init.d/eportal
            /etc/init.d/eportal enable >/dev/null 2>&1
            info "已注册 procd 服务并设置开机自启"
            SERVICE_REGISTERED="openwrt"
        else
            warn "无法安装 procd 服务（脚本未装入 /usr/bin 或无权限），请使用 cron 托管"
            print_cron_example "$AUTH_BIN"
        fi
    elif [ "$ENV_TYPE" = "systemd" ]; then
        if [ $BIN_INSTALLED -eq 1 ] && cp "$SYSTEMD_UNIT_SRC" /etc/systemd/system/eportal.service 2>/dev/null; then
            systemctl daemon-reload >/dev/null 2>&1
            systemctl enable eportal >/dev/null 2>&1
            info "已注册 systemd 服务并设置开机自启"
            SERVICE_REGISTERED="systemd"
        else
            warn "无法安装 systemd 服务（脚本未装入 /usr/bin 或无权限），请使用 cron 托管"
            print_cron_example "$AUTH_BIN"
        fi
    else
        print_cron_example "$AUTH_BIN"
    fi

    # ---- 6. 配置向导（交互式且未配置时自动进入）----
    if [ $CONFIGURED -eq 0 ]; then
        if [ -t 0 ]; then
            echo
            info "首次使用：启动配置向导"
            EPORTAL_CONF="$CONF_FILE" bash "$AUTH_SRC" --setup
            conf_is_configured "$CONF_FILE" && CONFIGURED=1
        else
            print_start_hint "$ENV_TYPE"
        fi
    fi

    # ---- 7. 启动服务（配置就绪且已注册时）----
    if [ $CONFIGURED -eq 1 ]; then
        case "$SERVICE_REGISTERED" in
            openwrt)
                /etc/init.d/eportal start >/dev/null 2>&1 && info "服务已启动" ;;
            systemd)
                systemctl start eportal >/dev/null 2>&1 && info "服务已启动" ;;
        esac
    fi

    # ---- 8. 汇总 ----
    echo
    info "===== 安装完成 ====="
    if [ $CONFIGURED -eq 0 ]; then
        echo "下一步: 运行 $AUTH_BIN --setup 完成配置"
    else
        info "查看状态: $AUTH_BIN --status"
    fi
}

# ------------------------------ 入口 ------------------------------

case "${1:-}" in
    --uninstall) do_uninstall ;;
    -h|--help)   usage ;;
    "")          do_install ;;
    *)           die "未知参数: $1（--help 查看用法）" ;;
esac
