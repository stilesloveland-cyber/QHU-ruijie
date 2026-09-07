#!/bin/bash
# =============================================================================
# 锐捷 ePortal 校园网自动认证脚本（通用 Linux 版）
#
# 依赖: bash / curl / openssl（WAN_IF=auto 自动探测出口网卡时还需 iproute2）
#
# 配置优先级: 环境变量 > 配置文件 > 默认值
# 配置文件查找顺序:
#   1. $EPORTAL_CONF 指定的路径
#   2. 脚本同目录下的 eportal.conf
#   3. /etc/eportal/eportal.conf
#
# 用法:
#   eportal-auth.sh            执行一次认证检查（未配置时进入向导）
#   eportal-auth.sh --setup    交互式配置向导（自动探测学校/抓取运营商列表）
#   eportal-auth.sh --check    环境自检（配置/依赖/网络），不做认证
#   eportal-auth.sh --status   查看在线状态与配置摘要（密码打码）
#   eportal-auth.sh --help     查看帮助
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 部分网关不下发 mac 参数时使用的兜底值（已在生产环境验证，勿改）
EP_MAC_DEFAULT="111111111"

# 日志轮转阈值（字节）：超过则轮转为 LOG_FILE.1，防止内存盘/磁盘被吃满
LOG_ROTATE_MAX=524288

# ------------------------------ 配置加载 ------------------------------

load_config() {
    CONF_FILE=""
    local conf_file=""
    if [ -n "${EPORTAL_CONF:-}" ]; then
        if [ -f "$EPORTAL_CONF" ]; then
            conf_file="$EPORTAL_CONF"
        else
            echo "提示：EPORTAL_CONF 指定的配置文件不存在: $EPORTAL_CONF（--setup 可创建）" >&2
        fi
    elif [ -f "$SCRIPT_DIR/eportal.conf" ]; then
        conf_file="$SCRIPT_DIR/eportal.conf"
    elif [ -f /etc/eportal/eportal.conf ]; then
        conf_file="/etc/eportal/eportal.conf"
    fi

    if [ -n "$conf_file" ]; then
        CONF_FILE="$conf_file"
        # 环境变量优先级高于配置文件：先快照，加载后回填
        local _u="${EP_USER:-}" _p="${EP_PASS:-}" _s="${EP_SERVER:-}" _w="${WAN_IF:-}" \
              _n="${SERVICE_NAME:-}" _d="${STATE_DIR:-}" _l="${LOG_FILE:-}" _i="${CHECK_INTERVAL:-}"
        # shellcheck disable=SC1090
        . "$conf_file"
        [ -n "$_u" ] && EP_USER="$_u"
        [ -n "$_p" ] && EP_PASS="$_p"
        [ -n "$_s" ] && EP_SERVER="$_s"
        [ -n "$_w" ] && WAN_IF="$_w"
        [ -n "$_n" ] && SERVICE_NAME="$_n"
        [ -n "$_d" ] && STATE_DIR="$_d"
        [ -n "$_l" ] && LOG_FILE="$_l"
        [ -n "$_i" ] && CHECK_INTERVAL="$_i"
    fi

    # 默认值（EP_USER/EP_PASS/EP_SERVER 无默认值，缺失由校验环节报错）
    WAN_IF="${WAN_IF:-auto}"
    SERVICE_NAME="${SERVICE_NAME:-%25E6%25A0%25A1%25E5%259B%25AD%25E8%2581%2594%25E9%2580%259A}"
    CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
    STATE_DIR="${STATE_DIR:-auto}"
    LOG_FILE="${LOG_FILE:-auto}"
}

config_complete() {
    [ -n "${EP_USER:-}" ] && [ -n "${EP_PASS:-}" ] && [ -n "${EP_SERVER:-}" ]
}

require_config() {
    local miss=""
    [ -n "${EP_USER:-}" ]   || miss="$miss EP_USER(认证账号)"
    [ -n "${EP_PASS:-}" ]   || miss="$miss EP_PASS(认证密码)"
    [ -n "${EP_SERVER:-}" ] || miss="$miss EP_SERVER(ePortal服务器地址)"
    if [ -n "$miss" ]; then
        echo "错误：以下必填配置未设置:$miss" >&2
        if [ -n "$CONF_FILE" ]; then
            echo "请编辑配置文件: $CONF_FILE，或运行 --setup 重新配置" >&2
        else
            echo "未找到配置文件。请运行 eportal-auth.sh --setup 进入配置向导，" >&2
            echo "或复制 eportal.conf.example 为 eportal.conf 并填写。" >&2
        fi
        exit 1
    fi
}

# ------------------------------ 路径解析 ------------------------------

resolve_state_dir() {
    # auto: 优先 /var/lib/eportal，不可写则降级到 $HOME/.eportal（免 root 也能运行）
    # EPORTAL_PREFERRED_STATE_DIR: 内部参数，供测试注入首选目录
    local preferred="${EPORTAL_PREFERRED_STATE_DIR:-/var/lib/eportal}"
    if mkdir -p "$preferred" 2>/dev/null && [ -w "$preferred" ]; then
        STATE_DIR="$preferred"
    elif mkdir -p "$HOME/.eportal" 2>/dev/null && [ -w "$HOME/.eportal" ]; then
        STATE_DIR="$HOME/.eportal"
    else
        echo "错误：无法创建可写的状态目录（尝试过 $preferred 与 $HOME/.eportal）" >&2
        return 1
    fi
}

resolve_paths() {
    if [ -z "$STATE_DIR" ] || [ "$STATE_DIR" = "auto" ]; then
        resolve_state_dir || return 1
    else
        mkdir -p "$STATE_DIR" 2>/dev/null || {
            echo "错误：STATE_DIR 指定的目录无法创建: $STATE_DIR" >&2
            return 1
        }
    fi
    if [ -z "$LOG_FILE" ] || [ "$LOG_FILE" = "auto" ]; then
        LOG_FILE="$STATE_DIR/eportal.log"
    else
        mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || {
            echo "错误：LOG_FILE 所在目录无法创建: $(dirname "$LOG_FILE")" >&2
            return 1
        }
    fi
    QS_CACHE="$STATE_DIR/qs.cache"
    USER_INDEX_FILE="$STATE_DIR/userindex.cache"
    COOKIE_JAR="$STATE_DIR/cookie.jar"
    LOCKDIR="$STATE_DIR/auth.lock"
    PEM="$STATE_DIR/pub.pem"
    RSA_CNF="$STATE_DIR/rsa.cnf"
    RSA_DER="$STATE_DIR/pub.der"
    RSA_IN="$STATE_DIR/in.bin"
    RSA_OUT="$STATE_DIR/out.bin"
    return 0
}

# ------------------------------ 网卡与 IP ------------------------------

detect_wan_if() {
    # 依次尝试: 默认路由 → 8.8.8.8 路由，取 dev 名称
    local dev=""
    dev=$(ip route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
    if [ -z "$dev" ]; then
        dev=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
    fi
    echo "$dev"
}

resolve_wan_if() {
    if [ "$WAN_IF" = "auto" ]; then
        WAN_IF=$(detect_wan_if)
        if [ -z "$WAN_IF" ]; then
            echo "错误：无法自动探测出口网卡（需要 iproute2 的 ip 命令）。请在配置文件中手动设置 WAN_IF" >&2
            return 1
        fi
    fi
    return 0
}

current_ip() {
    ip -4 addr show dev "$WAN_IF" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1
}

# ------------------------------ 基础工具 ------------------------------

# 日志写入 + 超阈值自动轮转（保留一代 .1）
log() {
    if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE")" -gt "$LOG_ROTATE_MAX" ]; then
        mv -f "$LOG_FILE" "$LOG_FILE.1"
        echo "$(date '+%F %T') 日志超过 $((LOG_ROTATE_MAX/1024))KB，已轮转" >> "$LOG_FILE"
    fi
    echo "$(date '+%F %T') $*" >> "$LOG_FILE"
}

# urlencode: 最小转义策略（仅转义 & = % 空格）
# 已在生产环境验证可用，勿改（改动可能破坏登录请求）
urlencode() {
    local s="$1"
    s=${s//&/__AMP__}; s=${s//=/__EQ__}; s=${s//%/__PCT__}; s=${s// /__SP__}
    s=${s//__AMP__/%26}; s=${s//__EQ__/%3D}; s=${s//__PCT__/%25}; s=${s//__SP__/%20}
    echo -n "$s"
}
double_encode() { urlencode "$(urlencode "$1")"; }

# urlencode_full: 完整 UTF-8 逐字节百分号编码（RFC 3986 未保留字符除外）
# 仅用于向导生成 SERVICE_NAME，不影响上面的最小转义 urlencode
urlencode_full() {
    local LC_ALL=C
    local s="$1" out="" i c
    for ((i=0; i<${#s}; i++)); do
        c=${s:i:1}
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
        esac
    done
    printf '%s' "$out"
}

# 向导用：将运营商名称/值转换为配置文件中的 SERVICE_NAME（双重编码值）
# - 明文（如中文"校园联通"）→ 双重编码
# - 已单层编码（如 %E4%B8%AD）→ 再编一层
# - 纯 ASCII 无编码（如 unicom）→ 原样（编码无变化）
service_to_config() {
    local v="$1"
    if printf '%s' "$v" | LC_ALL=C grep -q '%[0-9A-Fa-f][0-9A-Fa-f]' \
        && ! printf '%s' "$v" | LC_ALL=C grep -q '[^ -~]'; then
        urlencode_full "$v"
    else
        urlencode_full "$(urlencode_full "$v")"
    fi
}

# 配置值写入双引号字符串时的转义（\ " $ `）
esc_dq() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//\$/\\\$}
    s=${s//\`/\\\`}
    printf '%s' "$s"
}

# 敏感信息打码（前 2 后 2，过短全遮）
mask_secret() {
    local s="$1"
    if [ ${#s} -le 4 ]; then
        printf '****'
    else
        printf '%s****%s' "${s:0:2}" "${s: -2}"
    fi
}

# 登录 queryString 必须包含全部门户设备字段才算有效
valid_qs() {
    local q="$1"
    echo "$q" | grep -Eq '(^|&)wlanuserip=[^&]+' || return 1
    echo "$q" | grep -Eq '(^|&)wlanacname=[^&]+' || return 1
    echo "$q" | grep -Eq '(^|&)nasip=[^&]+' || return 1
    echo "$q" | grep -Eq '(^|&)mac=[^&]+' || return 1
    echo "$q" | grep -Eq '(^|&)t=[^&]+' || return 1
}

# ------------------------------ 门户探测与运营商抓取 ------------------------------

# 解析门户重定向 Location:
#   eportal <server> <qs>  锐捷 ePortal 登录页
#   other <location>       识别到非锐捷门户（私网 IP / srun / drcom）
#   none                   无劫持 / 已认证 / 锐捷但非登录页（如 success 跳转）
parse_portal_location() {
    local loc="$1"
    [ -n "$loc" ] || { echo "none"; return 0; }
    local server
    server=$(printf '%s' "$loc" | sed -n 's#^\(https\{0,1\}://[^/]*\)/eportal/index\.jsp.*#\1#p')
    if [ -n "$server" ]; then
        local qs
        qs=$(printf '%s' "$loc" | sed -n 's#^[^?]*?##p')
        echo "eportal $server $qs"
        return 0
    fi
    # 锐捷门户但非登录页（如已认证时的 redirectortosuccess.jsp）：无法用于配置
    printf '%s' "$loc" | grep -q '/eportal/' && { echo "none"; return 0; }
    if printf '%s' "$loc" | grep -Eq '^https?://(10\.|127\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' \
        || printf '%s' "$loc" | grep -Eqi '(srun|drcom)'; then
        echo "other $loc"
        return 0
    fi
    echo "none"
}

# 门户劫持探测：依次请求探测 URL，不跟随重定向，取 Location 判定
# 仅在交互向导中调用；进度输出到 stderr，结果输出到 stdout
detect_eportal_server() {
    local probes=("http://connect.rom.miui.com/generate_204"
                  "http://captive.apple.com/hotspot-detect.html"
                  "http://www.msftconnecttest.com/redirect"
                  "http://www.baidu.com")
    local u i=1 loc res
    for u in "${probes[@]}"; do
        printf '正在探测校园网门户 (%d/%d)...\n' "$i" "${#probes[@]}" >&2
        loc=$(curl --noproxy '*' -s -o /dev/null -m 5 -w '%{redirect_url}' "$u" 2>/dev/null)
        res=$(parse_portal_location "$loc")
        case "$res" in
            eportal*|other*) echo "$res"; return 0 ;;
        esac
        i=$((i+1))
    done
    echo "none"
}

# 解析登录页 HTML 中的运营商/套餐选项
# 输出: 每行 "value<TAB>显示名"；识别失败返回 1
# 模式 a: <select name/id 含 service/operator> 内的 <option>
# 模式 b: JS 服务名数组字面量（var serviceList = [...];）
parse_service_options() {
    local flat block
    flat=$(printf '%s' "$1" | tr -d '\r\n')
    [ -n "$flat" ] || return 1
    # 模式 a: select 下拉框
    block=$(printf '%s' "$flat" | sed -n 's/^.*<select[^>]*\(service\|operator\)[^>]*>//p' | head -1)
    if [ -n "$block" ]; then
        block=${block%%</select>*}
        local found=0 opt val name
        while IFS= read -r opt; do
            val=$(printf '%s' "$opt" | sed -n 's/^<option[^>]*value="\([^"]*\)".*/\1/p')
            name=$(printf '%s' "$opt" | sed -n 's/^<option[^>]*>\([^<]*\)<\/option>$/\1/p')
            if [ -n "$name" ]; then
                printf '%s\t%s\n' "$val" "$name"
                found=1
            fi
        done <<< "$(printf '%s' "$block" | grep -o '<option[^>]*>[^<]*</option>')"
        [ $found -eq 1 ] && return 0
    fi
    # 模式 b: JS 数组
    local arr
    arr=$(printf '%s' "$flat" | grep -oE '[Ss]ervice[A-Za-z]*[[:space:]]*=[[:space:]]*\[[^]]*\]' | head -1)
    if [ -n "$arr" ]; then
        arr=${arr#*[}
        arr=${arr%]}
        local item
        while IFS= read -r item; do
            item=$(printf '%s' "$item" | sed -e 's/^ *//' -e 's/ *$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
            [ -n "$item" ] && printf '%s\t%s\n' "$item" "$item"
        done <<< "$(printf '%s' "$arr" | tr ',' '\n')"
        return 0
    fi
    return 1
}

# 抓取指定服务器的运营商列表（需要有效 qs，即设备处于未认证状态）
fetch_service_list() {
    local server="$1" qs="$2" page
    [ -n "$server" ] && [ -n "$qs" ] || return 1
    page=$(curl --noproxy '*' -s --compressed -m 10 "$server/eportal/index.jsp?$qs" 2>/dev/null)
    [ -n "$page" ] || return 1
    parse_service_options "$page"
}

# ------------------------------ 单实例锁（PID 探活，断电自恢复） ------------------------------

acquire_lock() {
    if mkdir "$LOCKDIR" 2>/dev/null; then
        echo $$ > "$LOCKDIR/pid"
        trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT
        return 0
    fi
    # 锁已存在：检查持有进程是否存活
    local oldpid
    oldpid=$(cat "$LOCKDIR/pid" 2>/dev/null)
    if [ -n "$oldpid" ] && ! kill -0 "$oldpid" 2>/dev/null; then
        log "检测到残留锁（PID $oldpid 已退出），已自动接管"
        rm -rf "$LOCKDIR"
        if mkdir "$LOCKDIR" 2>/dev/null; then
            echo $$ > "$LOCKDIR/pid"
            trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT
            return 0
        fi
        return 1
    fi
    # 活进程持锁 / 锁目录无 PID 文件（极端竞态，保守跳过）
    return 1
}

# ------------------------------ 认证流程 ------------------------------
# 以下认证逻辑（check_auth / make_pem / rsa_encrypt / do_auth）已在生产环境
# 验证可用，除日志增强、openssl 命令选择（R14c）、请求体 stdin 化（R15）、
# 密码错误识别（R16）外勿改。

check_auth() {
    local ui myip result userip userid userindex saved_index attempt=0
    myip=$(current_ip)
    [ -n "$myip" ] || return 1
    log "在线检查 (getOnlineUserInfo): 网卡=$WAN_IF IP=$myip 服务器=$EP_SERVER"
    userindex=""
    if [ -s "$USER_INDEX_FILE" ]; then
        userindex=$(tr -d '\r\n' < "$USER_INDEX_FILE")
    fi
    while [ $attempt -lt 6 ]; do
        if [ -n "$userindex" ]; then
            ui=$(curl --noproxy '*' -s -m 8 -b "$COOKIE_JAR" \
                -d "userIndex=$userindex" \
                "$EP_SERVER/eportal/InterFace.do?method=getOnlineUserInfo" 2>/dev/null)
        else
            ui=$(curl --noproxy '*' -s -m 8 -b "$COOKIE_JAR" \
                -d "userId=$EP_USER" \
                "$EP_SERVER/eportal/InterFace.do?method=getOnlineUserInfo" 2>/dev/null)
        fi
        result=$(echo "$ui" | sed -n 's/.*"result":"\([^"]*\)".*/\1/p')
        userid=$(echo "$ui" | sed -n 's/.*"userId":"\([^"]*\)".*/\1/p')
        userip=$(echo "$ui" | sed -n 's/.*"userIp":"\([^"]*\)".*/\1/p')
        saved_index=$(echo "$ui" | sed -n 's/.*"userIndex":"\([^"]*\)".*/\1/p')
        if [ -n "$saved_index" ] && [ "$userid" = "$EP_USER" ] && [ "$userip" = "$myip" ]; then
            printf '%s\n' "$saved_index" > "$USER_INDEX_FILE"
            [ "$result" = "success" ] && return 0
            if [ "$result" = "wait" ]; then
                log "认证会话已建立，服务器资料同步中 (${attempt}/5)"
                sleep 5
                userindex="$saved_index"
                attempt=$((attempt+1))
                continue
            fi
        fi
        return 1
    done
    log "认证会话同步超时，未得到 success"
    return 1
}

make_pem() {
    local modhex="$1" exphex="$2"
    [ ${#modhex} -ge 64 ] || { log "模数长度异常: ${#modhex}"; return 1; }
    printf 'asn1=SEQUENCE:pubkey\n[pubkey]\nmodulus=INTEGER:0x%s\npubexp=INTEGER:0x%s\n' "$modhex" "$exphex" > "$RSA_CNF"
    openssl asn1parse -genconf "$RSA_CNF" -out "$RSA_DER" -noout 2>/dev/null || { log "genconf 失败"; return 1; }
    openssl rsa -RSAPublicKey_in -inform DER -in "$RSA_DER" -out "$PEM" 2>/dev/null || { log "DER->PEM 失败"; return 1; }
    rm -f "$RSA_CNF" "$RSA_DER"
    [ -s "$PEM" ]
}

# 二进制文件转十六进制字符串：hexdump 优先，od 回退（od 为 POSIX 标配）
bin_to_hex() {
    if command -v hexdump >/dev/null 2>&1; then
        hexdump -v -e '1/1 "%02x"' "$1"
    else
        od -An -tx1 "$1" | tr -d ' \n'
    fi
}

# RSA 无填充加密单块：优先 pkeyutl（OpenSSL 3.x，rsautl 已弃用），失败回退 rsautl
rsa_raw_encrypt() {
    if openssl pkeyutl -encrypt -pubin -inkey "$PEM" -pkeyopt rsa_padding_mode:none -in "$1" -out "$RSA_OUT" 2>/dev/null \
        && [ -s "$RSA_OUT" ]; then
        bin_to_hex "$RSA_OUT"
        return 0
    fi
    if openssl rsautl -raw -encrypt -pubin -inkey "$PEM" -in "$1" -out "$RSA_OUT" 2>/dev/null \
        && [ -s "$RSA_OUT" ]; then
        bin_to_hex "$RSA_OUT"
        return 0
    fi
    return 1
}

rsa_encrypt() {
    local plain="$1" modhex="$2" exphex="$3"
    make_pem "$modhex" "$exphex" || { log "PEM 构造失败"; return 1; }
    local len=${#plain} i=0 chunk csize pad hexout result=""
    while [ $i -lt $len ]; do
        chunk=$(printf '%s' "$plain" | dd bs=1 skip=$i count=128 2>/dev/null)
        csize=${#chunk}; pad=$((128-csize))
        { [ $pad -gt 0 ] && head -c $pad /dev/zero; printf '%s' "$chunk"; } > "$RSA_IN"
        hexout=$(rsa_raw_encrypt "$RSA_IN")
        [ -n "$hexout" ] || { log "RSA 加密失败 (块 $((i/128+1)))"; return 1; }
        result="${result}${hexout} "
        i=$((i+128))
    done
    echo -n "${result% }"
}

# 识别『密码错误』类拒绝响应（用于高亮提示，避免误判为网络问题）
auth_resp_is_fatal() {
    printf '%s' "$1" | grep -qE '密码错误|password.?error|账号或密码|用户名或密码|E2620|不存在'
}

do_auth() {
    local pageinfo pubmod pubexp qs mac qs_enc_once qs_enc pass_enc body resp
    local used_cache=0 i=0
    log "探测登录参数 (首页重定向): 服务器=$EP_SERVER 网卡=$WAN_IF"
    qs=$(curl --noproxy '*' -s -o /dev/null -w '%{redirect_url}' -m 8 "$EP_SERVER/" 2>/dev/null)
    qs=${qs#*index.jsp?}

    if ! valid_qs "$qs"; then
        qs=""
        if [ -s "$QS_CACHE" ]; then
            qs=$(tr -d '\r\n' < "$QS_CACHE")
            if valid_qs "$qs"; then
                used_cache=1
                log "复用完整缓存 qs (不改写服务器参数): ${qs:0:100}"
            else
                rm -f "$QS_CACHE"
                qs=""
                log "WARN: 缓存 qs 不完整，已删除"
            fi
        fi
    fi

    if ! valid_qs "$qs"; then
        log "WARN: 无完整登录参数，快速重探 10s x 6"
        while [ $i -lt 6 ]; do
            sleep 10; i=$((i+1))
            qs=$(curl --noproxy '*' -s -o /dev/null -w '%{redirect_url}' -m 8 "$EP_SERVER/" 2>/dev/null)
            qs=${qs#*index.jsp?}
            valid_qs "$qs" && { log "INFO: 获取到完整登录参数"; break; }
            qs=""
        done
        if ! valid_qs "$qs"; then
            log "WARN: 60s 重探仍无完整登录参数，放弃本轮"
            return 1
        fi
    fi

    # Only persist a complete server-issued queryString.
    valid_qs "$qs" || return 1
    printf '%s\n' "$qs" > "$QS_CACHE" 2>/dev/null || log "WARN: 无法写入 qs 缓存"
    mac=$(echo "$qs" | tr '&' '\n' | sed -n 's/^mac=//p' | head -1)
    [ -n "$mac" ] || mac="$EP_MAC_DEFAULT"
    log "queryString 前100: ${qs:0:100} mac=${mac}"

    # Establish the same HTTP session as the browser before API calls.
    log "建立会话 (index.jsp): 服务器=$EP_SERVER"
    rm -f "$COOKIE_JAR"
    curl --noproxy '*' -sS -m 10 -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        -H 'Cache-Control: no-cache' -o /dev/null "$EP_SERVER/eportal/index.jsp?$qs" 2>/dev/null || {
        log "FATAL: index.jsp 会话建立失败"
        return 1
    }

    qs_enc_once=$(urlencode "$qs")
    qs_enc=$(double_encode "$qs")
    log "获取公钥 (pageInfo): 服务器=$EP_SERVER"
    pageinfo=$(curl --noproxy '*' -s -m 8 -b "$COOKIE_JAR" -X POST "$EP_SERVER/eportal/InterFace.do?method=pageInfo" \
        -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
        --data-raw "queryString=$qs_enc_once" 2>/dev/null)
    pubmod=$(echo "$pageinfo" | sed -n 's/.*"publicKeyModulus":"\([0-9a-f]*\)".*/\1/p' | head -1)
    pubexp=$(echo "$pageinfo" | sed -n 's/.*"publicKeyExponent":"\([0-9a-f]*\)".*/\1/p' | head -1)
    [ -n "$pubmod" ] || { log "FATAL: pageInfo 无 publicKeyModulus"; return 1; }
    [ -n "$pubexp" ] || pubexp="10001"
    log "公钥: exp=${pubexp} mod长度=${#pubmod}"

    pass_enc=$(rsa_encrypt "${EP_PASS}>${mac}" "$pubmod" "$pubexp")
    [ -n "$pass_enc" ] || { log "FATAL: 密码加密失败"; return 1; }
    pass_enc=$(double_encode "$pass_enc")
    body="userId=$(double_encode "$EP_USER")&password=${pass_enc}&service=${SERVICE_NAME}&queryString=${qs_enc}&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt=true"
    # 请求体经 stdin 传递，避免学号/密码出现在 ps 进程列表中
    log "提交登录 (login): 网卡=$WAN_IF IP=$(current_ip) 服务器=$EP_SERVER"
    resp=$(printf '%s' "$body" | curl --noproxy '*' -s -m 10 -b "$COOKIE_JAR" -c "$COOKIE_JAR" -X POST "$EP_SERVER/eportal/InterFace.do?method=login" \
        -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
        --data @- 2>/dev/null)
    log "login 响应: ${resp:0:400}"
    case "$resp" in
        *'"result":"success"'*|*'"result":"Success"'*)
            local new_index
            new_index=$(echo "$resp" | sed -n 's/.*"userIndex":"\([^"]*\)".*/\1/p')
            if [ -n "$new_index" ]; then
                printf '%s\n' "$new_index" > "$USER_INDEX_FILE"
                log "已保存 userIndex"
            else
                log "WARN: 登录成功响应没有 userIndex"
            fi
            echo "OK"; return 0 ;;
        *)
            echo "FAIL: $resp"
            if auth_resp_is_fatal "$resp"; then
                log "FATAL: 服务器返回认证拒绝（疑似密码错误/账号问题），请核对 EP_USER/EP_PASS；连续失败将自动退避"
                echo "FATAL: 疑似密码错误或账号问题，请核对配置（watchdog 已自动退避重试）"
            fi
            [ "$used_cache" = "1" ] && { rm -f "$QS_CACHE"; log "缓存 qs 认证失败，已删除"; }
            return 1
            ;;
    esac
}

run_auth() {
    FORCE_AUTH="${FORCE_AUTH:-0}"
    log "===== 运行 ===== 网卡=$WAN_IF IP=$(current_ip) 服务器=$EP_SERVER"
    if [ "$FORCE_AUTH" != "1" ] && check_auth; then
        echo "✅ 已认证，无需操作"; log "✅ 已认证，跳过"
    else
        echo "⚠️ 未认证，执行登录..."
        log "⚠️ 未认证，开始登录"
        if do_auth; then
            echo "✅ 认证完成"
            log "✅ 认证成功"
            exit 0
        else
            echo "❌ 认证失败"
            log "❌ 认证失败"
            exit 1
        fi
    fi
}

# ------------------------------ 自检模式 ------------------------------

run_check() {
    local fail=0 warn=0 myip dev code
    echo "==== ePortal 认证环境自检 ===="
    if [ -n "$CONF_FILE" ]; then
        echo "配置文件: $CONF_FILE"
    else
        echo "配置文件: 未找到（查找顺序: \$EPORTAL_CONF → 脚本同目录/eportal.conf → /etc/eportal/eportal.conf）"
    fi
    echo

    # ---- 1. 配置完整性 ----
    if [ -n "${EP_USER:-}" ]; then
        echo "[PASS] 配置项 EP_USER 已设置"
    else
        echo "[FAIL] 配置项 EP_USER(认证账号) 未设置 —— 请编辑配置文件填写或运行 --setup"
        fail=1
    fi
    if [ -n "${EP_PASS:-}" ]; then
        echo "[PASS] 配置项 EP_PASS 已设置"
        if printf '%s' "$EP_PASS" | grep -q '[&=% ]'; then
            echo "[WARN] 密码包含特殊字符(& = % 空格)，存在编码兼容性风险，建议修改校园网密码"
            warn=1
        fi
    else
        echo "[FAIL] 配置项 EP_PASS(认证密码) 未设置 —— 请编辑配置文件填写或运行 --setup"
        fail=1
    fi
    if [ -n "${EP_SERVER:-}" ]; then
        echo "[PASS] 配置项 EP_SERVER 已设置: $EP_SERVER"
    else
        echo "[FAIL] 配置项 EP_SERVER(ePortal服务器地址) 未设置 —— 请编辑配置文件填写或运行 --setup"
        fail=1
    fi

    # ---- 2. 依赖命令 ----
    if command -v curl >/dev/null 2>&1; then
        echo "[PASS] 依赖 curl 已安装"
    else
        echo "[FAIL] 依赖 curl 未安装 —— OpenWrt: opkg install curl; Debian/Ubuntu: apt install curl"
        fail=1
    fi
    if command -v openssl >/dev/null 2>&1; then
        echo "[PASS] 依赖 openssl 已安装"
    else
        echo "[FAIL] 依赖 openssl 未安装 —— OpenWrt: opkg install openssl-util; Debian/Ubuntu: apt install openssl"
        fail=1
    fi
    if [ "$WAN_IF" = "auto" ]; then
        if command -v ip >/dev/null 2>&1; then
            echo "[PASS] 依赖 ip(iproute2) 已安装（WAN_IF=auto 需要）"
        else
            echo "[FAIL] 依赖 ip(iproute2) 未安装 —— 自动探测网卡不可用; OpenWrt: opkg install ip; Debian/Ubuntu: apt install iproute2; 或在配置中手动设置 WAN_IF"
            fail=1
        fi
    fi

    # ---- 3. 状态目录 / 日志 ----
    echo "[PASS] 状态目录可写: $STATE_DIR"
    if touch "$LOG_FILE" 2>/dev/null; then
        echo "[PASS] 日志文件可写: $LOG_FILE"
    else
        echo "[FAIL] 日志文件不可写: $LOG_FILE —— 请检查 LOG_FILE 配置"
        fail=1
    fi

    # ---- 4. 出口网卡与 IP ----
    dev="$WAN_IF"
    if [ "$WAN_IF" = "auto" ]; then
        dev=$(detect_wan_if)
        if [ -n "$dev" ]; then
            echo "[PASS] 出口网卡自动探测: $dev"
        else
            echo "[FAIL] 无法自动探测出口网卡 —— 请安装 iproute2 或在配置中手动设置 WAN_IF"
            fail=1
        fi
    else
        if command -v ip >/dev/null 2>&1; then
            if ip link show dev "$WAN_IF" >/dev/null 2>&1; then
                echo "[PASS] 出口网卡配置有效: $WAN_IF"
            else
                echo "[FAIL] 网卡 $WAN_IF 不存在 —— 请检查配置 WAN_IF"
                fail=1
            fi
        else
            echo "[FAIL] ip 命令不可用，无法验证网卡 $WAN_IF —— 请安装 iproute2"
            fail=1
        fi
    fi
    if [ -n "$dev" ] && command -v ip >/dev/null 2>&1; then
        myip=$(ip -4 addr show dev "$dev" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
        if [ -n "$myip" ]; then
            echo "[PASS] 当前 IP: $myip (网卡 $dev)"
        else
            echo "[FAIL] 网卡 $dev 未获取到 IPv4 地址 —— 请检查网络连接"
            fail=1
        fi
    fi

    # ---- 5. 服务器连通性 ----
    if [ -n "${EP_SERVER:-}" ]; then
        code=$(curl --noproxy '*' -s -o /dev/null -m 3 -w '%{http_code}' "$EP_SERVER/" 2>/dev/null)
        if [ -n "$code" ] && [ "$code" != "000" ]; then
            echo "[PASS] ePortal 服务器可达: $EP_SERVER (HTTP $code)"
        else
            echo "[FAIL] 无法访问 ePortal 服务器 $EP_SERVER —— 请确认设备已接入校园网，或检查 EP_SERVER 配置"
            fail=1
        fi
    fi

    echo "----------------------------------------"
    if [ "$fail" -eq 0 ]; then
        echo "自检通过 (WARN $warn 项)"
        return 0
    fi
    echo "自检未通过: 存在 FAIL 项 (WARN $warn 项)，请按上述提示修复"
    return 1
}

# ------------------------------ 状态查询 ------------------------------

run_status() {
    local dev ipaddr ui result
    echo "==== ePortal 状态 ===="
    if [ "$WAN_IF" = "auto" ]; then
        dev=$(detect_wan_if)
        if [ -n "$dev" ]; then
            echo "出口网卡: $dev (自动探测)"
            WAN_IF="$dev"
        else
            echo "出口网卡: 探测失败（未安装 iproute2 或无默认路由）"
        fi
    else
        echo "出口网卡: $WAN_IF"
    fi
    ipaddr=$(current_ip)
    echo "当前 IP: ${ipaddr:-未知}"
    echo "服务器: $EP_SERVER"
    echo "学号: $(mask_secret "${EP_USER:-}")"
    echo "密码: $(mask_secret "${EP_PASS:-}")"
    echo "状态目录: $STATE_DIR"
    echo "日志文件: $LOG_FILE"
    ui=$(curl --noproxy '*' -s -m 5 -b "$COOKIE_JAR" \
        -d "userId=$EP_USER" \
        "$EP_SERVER/eportal/InterFace.do?method=getOnlineUserInfo" 2>/dev/null)
    result=$(echo "$ui" | sed -n 's/.*"result":"\([^"]*\)".*/\1/p')
    case "$result" in
        success) echo "在线状态: ✅ 在线" ;;
        wait)    echo "在线状态: ⏳ 服务器资料同步中" ;;
        *)       echo "在线状态: ❌ 离线或查询失败" ;;
    esac
    if [ -f "$LOG_FILE" ]; then
        echo
        echo "---- 最近日志 (10 行) ----"
        tail -n 10 "$LOG_FILE"
    fi
    return 0
}

# ------------------------------ 配置向导 ------------------------------

setup_conf_target() {
    if [ -n "${EPORTAL_CONF:-}" ]; then
        echo "$EPORTAL_CONF"
        return 0
    fi
    if [ -f "$SCRIPT_DIR/eportal.conf" ]; then
        echo "$SCRIPT_DIR/eportal.conf"
        return 0
    fi
    if [ -f /etc/eportal/eportal.conf ]; then
        echo "/etc/eportal/eportal.conf"
        return 0
    fi
    if mkdir -p /etc/eportal 2>/dev/null && [ -w /etc/eportal ]; then
        echo "/etc/eportal/eportal.conf"
        return 0
    fi
    mkdir -p "$HOME/.eportal" 2>/dev/null
    echo "$HOME/.eportal/eportal.conf"
}

run_setup() {
    echo "====== ePortal 配置向导 ======"
    local server="" qs="" det ans user pass wanif
    local svc_list="" fetched_ok=0

    # ---- 1. ePortal 服务器（自动探测优先）----
    if [ "${EPORTAL_SETUP_NO_DETECT:-0}" != "1" ]; then
        det=$(detect_eportal_server)
        case "$det" in
            eportal*)
                server=$(printf '%s' "$det" | awk '{print $2}')
                qs=$(printf '%s' "$det" | awk '{print $3}')
                echo "✅ 自动识别到锐捷 ePortal 服务器: $server"
                printf '使用该服务器? [Y/n]: '
                read -r ans || ans=""
                case "$ans" in n|N*) server=""; qs="" ;; esac
                ;;
            other*)
                echo "⚠️ 识别到非锐捷 ePortal 门户: $(printf '%s' "$det" | cut -d' ' -f2-)"
                echo "   本脚本仅支持锐捷 ePortal 认证系统"
                ;;
            none)
                echo "ℹ️ 未能自动探测到认证门户（设备可能已认证或不在校园网）"
                ;;
        esac
    fi
    if [ -z "$server" ]; then
        printf '请输入 ePortal 服务器地址 [回车默认 http://210.27.177.172]: '
        read -r server || server=""
        [ -n "$server" ] || server="http://210.27.177.172"
    fi

    # ---- 2. 学号 ----
    while :; do
        printf '请输入学号: '
        read -r user || { echo; echo "错误：输入已结束"; return 1; }
        [ -n "$user" ] && break
        echo "学号不能为空，请重新输入"
    done

    # ---- 3. 密码（隐藏输入 + 二次确认）----
    local pass2
    while :; do
        printf '请输入密码: '
        read -rs pass || { echo; echo "错误：输入已结束"; return 1; }
        echo
        [ -n "$pass" ] || { echo "密码不能为空，请重新输入"; continue; }
        printf '请再次输入密码: '
        read -rs pass2 || { echo; echo "错误：输入已结束"; return 1; }
        echo
        [ "$pass" = "$pass2" ] && break
        echo "两次输入不一致，请重新输入"
    done

    # ---- 4. 运营商/套餐（在线抓取优先，回退预设）----
    if [ "${EPORTAL_SETUP_NO_DETECT:-0}" != "1" ] && [ -z "$qs" ]; then
        # 从服务器首页重定向尝试获取 qs（设备未认证时可得）
        local loc2 res2
        loc2=$(curl --noproxy '*' -s -o /dev/null -m 8 -w '%{redirect_url}' "$server/" 2>/dev/null)
        res2=$(parse_portal_location "$loc2")
        case "$res2" in eportal*) qs=$(printf '%s' "$res2" | awk '{print $3}') ;; esac
    fi
    if [ "${EPORTAL_SETUP_NO_DETECT:-0}" != "1" ] && [ -n "$qs" ]; then
        echo "正在获取本校运营商/套餐列表..."
        if svc_list=$(fetch_service_list "$server" "$qs") && [ -n "$svc_list" ]; then
            fetched_ok=1
        else
            echo "ℹ️ 在线获取运营商列表失败，使用预设选项"
        fi
    fi
    local names=() vals=() n=0 choice svc_display svc_config fval fname total
    if [ "$fetched_ok" = "1" ]; then
        echo "检测到以下运营商/套餐:"
        while IFS=$'\t' read -r fval fname; do
            [ -n "$fname" ] || continue
            [ -n "$fval" ] || fval="$fname"
            n=$((n+1)); names+=("$fname"); vals+=("$fval")
            printf '  %d) %s\n' "$n" "$fname"
        done <<< "$svc_list"
    fi
    if [ $n -eq 0 ]; then
        echo "选择运营商/套餐:"
        n=1; names=("校园联通"); vals=("校园联通")
        printf '  1) 校园联通（默认，已验证可用）\n'
    fi
    n=$((n+1)); names+=("其他（手动输入）"); vals+=("")
    total=$n
    printf '  %d) 其他（手动输入名称）\n' "$total"
    while :; do
        printf '请选择 [1]: '
        read -r choice || { echo; echo "错误：输入已结束"; return 1; }
        [ -z "$choice" ] && choice=1
        case "$choice" in *[!0-9]*) echo "请输入数字编号"; continue ;; esac
        if [ "$choice" -ge 1 ] && [ "$choice" -le "$total" ]; then break; fi
        echo "编号超出范围 (1-$total)"
    done
    if [ "$choice" -eq "$total" ]; then
        while :; do
            printf '请输入运营商/套餐名称（明文，如 校园移动）: '
            read -r svc_display || { echo; echo "错误：输入已结束"; return 1; }
            [ -n "$svc_display" ] && break
            echo "名称不能为空"
        done
        vals[$((choice-1))]="$svc_display"
    else
        svc_display="${names[$((choice-1))]}"
    fi
    svc_config=$(service_to_config "${vals[$((choice-1))]}")

    # ---- 5. 出口网卡 ----
    printf '出口网卡 [回车默认 auto 自动探测]: '
    read -r wanif || wanif=""
    [ -n "$wanif" ] || wanif="auto"

    # ---- 6. 写入配置（保留未询问项，如 CHECK_INTERVAL）----
    local target interval="60"
    target=$(setup_conf_target)
    if [ -f "$target" ]; then
        interval=$(sed -n 's/^CHECK_INTERVAL="\([^"]*\)".*/\1/p' "$target" | tail -1)
        [ -n "$interval" ] || interval=60
    else
        mkdir -p "$(dirname "$target")" 2>/dev/null || {
            echo "错误：无法创建配置目录 $(dirname "$target")" >&2
            return 1
        }
    fi
    cat > "$target" <<EOF
# 由 eportal-auth.sh --setup 生成于 $(date '+%F %T')

# 认证账号（学号）
EP_USER="$(esc_dq "$user")"
# 认证密码
EP_PASS="$(esc_dq "$pass")"
# ePortal 服务器地址
EP_SERVER="$(esc_dq "$server")"
# 出口网卡（auto = 按默认路由自动探测）
WAN_IF="$(esc_dq "$wanif")"
# 认证服务名（向导根据套餐名自动生成的双重 URL 编码值，套餐: $svc_display）
SERVICE_NAME="$svc_config"
# 状态目录（auto = /var/lib/eportal，不可写时降级 ~/.eportal）
STATE_DIR="auto"
# 日志文件（auto = $STATE_DIR/eportal.log）
LOG_FILE="auto"
# watchdog 检测间隔（秒）
CHECK_INTERVAL="$interval"
EOF
    chmod 600 "$target" || { echo "警告：无法设置配置文件权限为 600" >&2; }

    echo
    echo "✅ 配置已保存: $target (权限 600)"
    echo "   学号: $user"
    echo "   服务器: $server"
    echo "   套餐: $svc_display"
    echo "   网卡: $wanif"

    # ---- 7. 可选自检 ----
    printf '是否立即运行环境自检 --check? [Y/n]: '
    read -r ans || ans=""
    case "$ans" in
        n|N*) ;;
        *)
            echo
            export EPORTAL_CONF="$target"
            load_config
            if resolve_paths; then
                run_check
            else
                echo "自检跳过：状态目录不可写"
            fi
            ;;
    esac
    return 0
}

# ------------------------------ 入口 ------------------------------

usage() {
    cat <<'EOF'
锐捷 ePortal 自动认证脚本

用法:
  eportal-auth.sh            执行一次认证检查（未配置且在终端下会引导进入向导）
  eportal-auth.sh --setup    交互式配置向导（自动探测学校门户/抓取运营商列表）
  eportal-auth.sh --check    环境自检（配置/依赖/网络），不做认证
  eportal-auth.sh --status   查看在线状态、配置摘要（密码打码）与最近日志
  eportal-auth.sh --help     显示本帮助

环境变量:
  EPORTAL_CONF=<路径>        指定配置文件位置（--setup 会写入该路径）
  FORCE_AUTH=1               跳过在线检查，强制重新登录
  EPORTAL_SETUP_NO_DETECT=1  向导跳过网络探测（内部/测试用）
  其余配置项(EP_USER/EP_PASS/...) 环境变量优先级高于配置文件
EOF
}

main() {
    load_config
    local mode="${1:-}"
    case "$mode" in
        -h|--help)
            usage; exit 0 ;;
        --check)
            resolve_paths || exit 1
            run_check
            exit $? ;;
        --setup)
            run_setup
            exit $? ;;
        --status)
            require_config
            resolve_paths || exit 1
            run_status
            exit 0 ;;
        "")
            : ;;
        *)
            echo "未知参数: $1（--help 查看用法）" >&2
            exit 1 ;;
    esac

    # 未配置时：终端下引导进入向导，非终端（cron/服务）直接报错
    if ! config_complete; then
        if [ -t 0 ]; then
            echo "配置未完成，进入配置向导（Ctrl+C 可退出）..."
            run_setup || exit 1
            load_config
        fi
        require_config
    fi

    resolve_paths || exit 1
    resolve_wan_if || exit 1
    mkdir -p "$STATE_DIR" 2>/dev/null

    # 单实例锁（PID 探活，断电残留自动接管）
    if ! acquire_lock; then
        echo "认证脚本已有实例运行，跳过"
        exit 0
    fi

    run_auth
}

# 被其他脚本 source 时（如测试）不执行主流程
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
