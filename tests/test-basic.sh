#!/bin/bash
# =============================================================================
# 基础自测：语法 / 配置校验 / 编码快照 / STATE_DIR 降级 / 门户探测解析 /
#           运营商解析 / 残留锁接管 / 日志轮转 / openssl 加密 / 退避计算 /
#           向导冒烟 / --status 打码
# 运行: bash tests/test-basic.sh   （不依赖真实校园网，可在任意 Linux/CI 通过）
# 全部通过时退出码为 0
# =============================================================================

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        ok "$desc"
    else
        bad "$desc (期望: [$expected], 实际: [$actual])"
    fi
}

assert_rc() {
    local desc="$1" expected="$2" rc="$3"
    if [ "$rc" = "$expected" ]; then
        ok "$desc"
    else
        bad "$desc (期望 rc=$expected, 实际 rc=$rc)"
    fi
}

KNOWN_SERVICE="%25E6%25A0%25A1%25E5%259B%25AD%25E8%2581%2594%25E9%2580%259A"

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ---- 1. 语法检查 ----
for f in eportal-auth.sh eportal-watchdog.sh install.sh init/openwrt-init-eportal; do
    if bash -n "$ROOT/$f" 2>/dev/null; then
        ok "语法检查 $f"
    else
        bad "语法检查 $f"
    fi
done

# ---- 2. 配置校验分支（模板账号为空时 --check 应报缺失且非零退出）----
out="$(EPORTAL_CONF="$ROOT/eportal.conf.example" bash "$ROOT/eportal-auth.sh" --check 2>&1)"
rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "EP_USER"; then
    ok "未配置账号时 --check 报错并给出缺失项 (退出码 $rc)"
else
    bad "未配置账号时 --check 应报错 EP_USER 缺失 (实际退出码 $rc)"
fi

# ---- 3/4. 编码函数快照 ----
# shellcheck disable=SC1090
source "$ROOT/eportal-auth.sh"

assert_eq "urlencode 空格转义"     "hello%20world"  "$(urlencode 'hello world')"
assert_eq "urlencode 符号转义"     "a%26b%3Dc%25d"  "$(urlencode 'a&b=c%d')"
assert_eq "urlencode 普通字符串"   "plain123"       "$(urlencode 'plain123')"
assert_eq "double_encode 空格"     "a%2520b"        "$(double_encode 'a b')"
assert_eq "double_encode 符号"     "a%2526b%253Db"  "$(double_encode 'a&b=b')"

# urlencode_full：完整 UTF-8 逐字节编码
assert_eq "urlencode_full 中文单层" "%E6%A0%A1%E5%9B%AD%E8%81%94%E9%80%9A" "$(urlencode_full '校园联通')"
assert_eq "urlencode_full 空格"     "a%20b"                                "$(urlencode_full 'a b')"
assert_eq "urlencode_full 未保留字符不变" "abc123"                          "$(urlencode_full 'abc123')"

# service_to_config：明文 → 双重编码 == 已验证可用值（R10 验收关键项）
assert_eq "service_to_config 校园联通 == 已验证值" "$KNOWN_SERVICE" "$(service_to_config '校园联通')"
assert_eq "service_to_config 已编码值再编一层"      "%25E4%25B8%25AD" "$(service_to_config '%E4%B8%AD')"
assert_eq "service_to_config 纯ASCII不变"           "unicom"          "$(service_to_config 'unicom')"

# ---- 5. STATE_DIR auto 降级逻辑 ----
t1="$TMPDIR_TEST/sd1"
mkdir -p "$t1"
touch "$t1/blocker"
out="$(STATE_DIR=auto \
       EPORTAL_PREFERRED_STATE_DIR="$t1/blocker/eportal" \
       HOME="$t1" \
       EPORTAL_CONF="$ROOT/eportal.conf.example" \
       bash "$ROOT/eportal-auth.sh" --check 2>&1)"
if echo "$out" | grep -q "$t1/.eportal"; then
    ok "STATE_DIR 首选不可写时降级到 $t1/.eportal"
else
    bad "STATE_DIR 应降级到 $t1/.eportal，实际输出: $(echo "$out" | grep 状态目录)"
fi

# ---- 6. R12 门户 Location 解析 ----
r=$(parse_portal_location "http://210.27.177.172/eportal/index.jsp?wlanuserip=1.2.3.4&wlanacname=x&nasip=1.1.1.1&mac=abc&t=wirelessv2")
assert_eq "R12 锐捷登录页 → eportal+服务器+qs" \
    "eportal http://210.27.177.172 wlanuserip=1.2.3.4&wlanacname=x&nasip=1.1.1.1&mac=abc&t=wirelessv2" "$r"
r=$(parse_portal_location "http://210.27.177.172/eportal/redirectortosuccess.jsp")
assert_eq "R12 锐捷已认证跳转 → none" "none" "$r"
r=$(parse_portal_location "https://x.edu.cn/srun_portal_pc?ac_name=1")
assert_eq "R12 srun 门户 → other" "other https://x.edu.cn/srun_portal_pc?ac_name=1" "$r"
r=$(parse_portal_location "http://10.1.2.3/drcom/login")
assert_eq "R12 私网IP drcom → other" "other http://10.1.2.3/drcom/login" "$r"
r=$(parse_portal_location "")
assert_eq "R12 空重定向 → none" "none" "$r"
r=$(parse_portal_location "http://go.microsoft.com/fwlink/?LinkID=219472")
assert_eq "R12 普通互联网跳转 → none" "none" "$r"

# ---- 7. R13 运营商列表 HTML 解析 ----
FIX_SELECT='<html><body><select id="service" name="service"><option value="校园联通">校园联通</option><option value="%E4%B8%AD%E5%9B%BD%E7%A7%BB%E5%8A%A8">中国移动</option></select></body></html>'
out=$(parse_service_options "$FIX_SELECT"); rc=$?
assert_rc "R13 模式a option下拉 解析成功" 0 "$rc"
echo "$out" | grep -qF $'校园联通\t校园联通' \
    && ok "R13 模式a 第一项(校园联通)" || bad "R13 模式a 第一项，实际: $(echo "$out" | head -1)"
echo "$out" | grep -qF $'%E4%B8%AD%E5%9B%BD%E7%A7%BB%E5%8A%A8\t中国移动' \
    && ok "R13 模式a 第二项(已编码value)" || bad "R13 模式a 第二项，实际: $(echo "$out" | sed -n 2p)"

FIX_JS='<html><script>var serviceList = ["校园联通","中国移动","中国电信"];</script></html>'
out=$(parse_service_options "$FIX_JS"); rc=$?
assert_rc "R13 模式b JS数组 解析成功" 0 "$rc"
if [ "$(echo "$out" | wc -l)" -eq 3 ] && echo "$out" | grep -qF $'中国移动\t中国移动'; then
    ok "R13 模式b 解析出 3 项"
else
    bad "R13 模式b 应解析 3 项，实际: [$out]"
fi

out=$(parse_service_options "<html><body></body></html>"); rc=$?
assert_rc "R13 空页面 解析失败回退" 1 "$rc"

# ---- 8. R14 残留锁：死 PID 自动接管 / 活 PID 跳过 ----
LOG_FILE="$TMPDIR_TEST/lock.log"; LOCKDIR="$TMPDIR_TEST/auth.lock"
deadpid=""
bash -c 'exit 0' & deadpid=$!
wait "$deadpid" 2>/dev/null
sleep 0.3
kill -0 "$deadpid" 2>/dev/null && deadpid=9999999   # 保险：确保 PID 已死
mkdir -p "$LOCKDIR"; echo "$deadpid" > "$LOCKDIR/pid"
if acquire_lock; then
    ok "R14 死PID残留锁 自动接管"
    grep -q "残留锁" "$LOG_FILE" && ok "R14 接管写入日志" || bad "R14 接管日志缺失"
else
    bad "R14 死PID残留锁应自动接管"
fi
rm -rf "$LOCKDIR"
mkdir -p "$LOCKDIR"; echo "$$" > "$LOCKDIR/pid"   # 当前测试进程，存活
if acquire_lock; then
    bad "R14 活PID锁不应被抢占"
else
    ok "R14 活PID锁 正常跳过"
fi
rm -rf "$LOCKDIR"

# ---- 9. R14 日志轮转 ----
LOG_FILE="$TMPDIR_TEST/rot.log"
head -c 600000 /dev/zero | tr '\0' 'x' > "$LOG_FILE"
log "写入触发轮转"
if [ -f "$LOG_FILE.1" ] && [ "$(wc -c < "$LOG_FILE")" -lt 1000 ]; then
    ok "R14 日志超512KB自动轮转(保留.1)"
else
    bad "R14 日志轮转未生效 (.1存在: $([ -f "$LOG_FILE.1" ] && echo yes || echo no))"
fi

# ---- 10. R14 openssl：pkeyutl 优先路径加密可用 ----
# 形状与生产一致：1024 位公钥（128 字节模数）+ 128 字节前导零填充块
# （OpenSSL 3.x raw 模式要求输入长度恰等于密钥长度）
keyd="$TMPDIR_TEST/keys"; mkdir -p "$keyd"
if openssl genrsa -out "$keyd/priv.pem" 1024 >/dev/null 2>&1; then
    mod=$(openssl rsa -in "$keyd/priv.pem" -noout -modulus 2>/dev/null | sed 's/^Modulus=//')
    PEM="$keyd/pub.pem"; RSA_CNF="$keyd/rsa.cnf"; RSA_DER="$keyd/pub.der"; RSA_IN="$keyd/in.bin"; RSA_OUT="$keyd/out.bin"
    if make_pem "$mod" 10001; then
        { head -c 123 /dev/zero; printf 'hello'; } > "$RSA_IN"
        hex=$(rsa_raw_encrypt "$RSA_IN")
        if [ -n "$hex" ] && [ ${#hex} -eq 256 ]; then
            ok "R14 rsa_raw_encrypt 加密产物 1024bit=256hex"
        else
            bad "R14 加密产物异常 (长度 ${#hex})"
        fi
    else
        bad "R14 make_pem 构造公钥失败"
    fi
else
    bad "R14 openssl genrsa 不可用（环境异常）"
fi

# ---- 11. R16 退避计算边界值 ----
# shellcheck disable=SC1091
source "$ROOT/eportal-watchdog.sh"
assert_eq "R16 退避 0次=基础间隔"   "60"  "$(backoff_interval 0 60)"
assert_eq "R16 退避 1次=120"       "120" "$(backoff_interval 1 60)"
assert_eq "R16 退避 2次=240"       "240" "$(backoff_interval 2 60)"
assert_eq "R16 退避 3次=480"       "480" "$(backoff_interval 3 60)"
assert_eq "R16 退避 4次=900封顶"   "900" "$(backoff_interval 4 60)"
assert_eq "R16 退避 9次=900封顶"   "900" "$(backoff_interval 9 60)"
assert_eq "R16 退避 尊重自定义基础" "30"  "$(backoff_interval 0 30)"

# ---- 12. R16 密码错误响应识别 ----
if auth_resp_is_fatal '{"result":"fail","message":"密码错误!!!"}'; then
    ok "R16 密码错误响应 → FATAL 识别"
else
    bad "R16 密码错误响应未被识别"
fi
if auth_resp_is_fatal '{"result":"success","userIndex":"x"}'; then
    bad "R16 success 响应被误判为 FATAL"
else
    ok "R16 success 响应不误判"
fi

# ---- 13. R15 login 请求体 stdin 化（代码结构断言）----
if grep -q -- '--data @-' "$ROOT/eportal-auth.sh" \
    && ! grep -q -- '--data-raw "$body"' "$ROOT/eportal-auth.sh"; then
    ok "R15 login 请求体经 stdin 传递（--data @-）"
else
    bad "R15 login 请求体仍以命令行参数传递"
fi

# ---- 14. R10 向导非交互冒烟（管道喂答案，禁用网络探测）----
wconf="$TMPDIR_TEST/wizard/eportal.conf"
mkdir -p "$(dirname "$wconf")"
printf '\n20230123\nmypass\nmypass\n1\n\nn\n' \
    | EPORTAL_SETUP_NO_DETECT=1 EPORTAL_CONF="$wconf" bash "$ROOT/eportal-auth.sh" --setup >/dev/null 2>&1
rc=$?
if grep -q '^EP_USER="20230123"$' "$wconf" 2>/dev/null \
    && grep -q "^SERVICE_NAME=\"$KNOWN_SERVICE\"$" "$wconf" \
    && grep -q '^EP_SERVER="http://210.27.177.172"$' "$wconf" \
    && grep -q '^WAN_IF="auto"$' "$wconf"; then
    ok "R10 向导冒烟: 配置项全部正确写入"
else
    bad "R10 向导冒烟: 配置写入异常: $(cat "$wconf" 2>/dev/null | head -20 | tr '\n' ' ')"
fi
if [ "$(stat -c '%a' "$wconf" 2>/dev/null)" = "600" ]; then
    ok "R10 向导冒烟: 配置文件权限 600"
else
    # git bash / noacl 挂载上 chmod 为空操作，权限断言由 CI(Linux) 覆盖
    probe="$TMPDIR_TEST/perm_probe"
    echo x > "$probe"; chmod 600 "$probe"
    if [ "$(stat -c '%a' "$probe" 2>/dev/null)" != "600" ]; then
        echo "SKIP: 当前文件系统不支持 POSIX 权限模拟(git bash/noacl)，权限 600 断言由 CI 覆盖"
    else
        bad "R10 向导冒烟: 权限应为 600，实际 $(stat -c '%a' "$wconf" 2>/dev/null)"
    fi
fi
if grep -q '^CHECK_INTERVAL="60"$' "$wconf"; then
    ok "R10 向导冒烟: 未询问项保留默认值"
else
    bad "R10 向导冒烟: CHECK_INTERVAL 缺失"
fi

# ---- 15. R16 --status 打码与容错 ----
out="$(EP_USER=20230123 EP_PASS=testpass EP_SERVER=http://127.0.0.1:1/ \
    bash "$ROOT/eportal-auth.sh" --status 2>&1)"
if echo "$out" | grep -q '20\*\*\*\*23' && ! echo "$out" | grep -q '20230123'; then
    ok "R16 --status 学号打码"
else
    bad "R16 --status 学号未正确打码"
fi
if echo "$out" | grep -q 'te\*\*\*\*ss' && ! echo "$out" | grep -q 'testpass'; then
    ok "R16 --status 密码打码"
else
    bad "R16 --status 密码未正确打码"
fi

# --status 未配置时给出友好缺失提示
out="$(EPORTAL_CONF="$ROOT/eportal.conf.example" bash "$ROOT/eportal-auth.sh" --status 2>&1)"
rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "EP_USER"; then
    ok "R16 --status 未配置时友好报错 (退出码 $rc)"
else
    bad "R16 --status 未配置时应报错 (实际退出码 $rc)"
fi

# ---- 16. mask_secret 边界 ----
assert_eq "mask 短值全遮"  "****"    "$(mask_secret abc)"
assert_eq "mask 长值前后2" "ab****gh" "$(mask_secret abcdefgh)"

# ---- 结果汇总 ----
echo
echo "===== 测试结果: PASS=$PASS FAIL=$FAIL ====="
[ $FAIL -eq 0 ] && exit 0 || exit 1
