#!/bin/bash
# check.sh 与 backend.sh 的代理提供者（provider）平行副本对拍：
# 1) 五个 provider 函数在两个脚本中必须逐字节一致；
# 2) 同一组注入环境下，两个脚本对 provider 的判定输出必须一致；
# 3) check.sh 第 1 节计数三态（恰 1 ok / >1 no / 0 no）；
# 4) check.sh 第 3 节 client 隧道必须归因到提供者名，禁止"不能归因于 Mihomo"；
# 5) check.sh 第 5 节在缺少 Mihomo socket 时必须 skip，不得判 no。
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
CHECK="$SCRIPT_DIR/proxygauge-check.sh"
BACKEND="$SCRIPT_DIR/proxygauge-backend.sh"
TEST_ROOT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/proxygauge-check-parity-test.XXXXXX")
PROVIDER_TEST_PIDS=""
cleanup() {
  if [ -n "$PROVIDER_TEST_PIDS" ]; then
    kill $PROVIDER_TEST_PIDS 2>/dev/null || true
  fi
  /bin/rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

PROVIDER_FUNCTIONS='proxy_provider_pids provider_pid_name provider_keys provider_count provider_label'
CLIENT_ROUTE_FUNCTIONS='trusted_client_tun_candidates client_tun_candidates provider_packet_tunnel_running classify_client_tunnel_route tun_route_table'
ROUTE_QUERY_FUNCTIONS='route_lookup_interface representative_route_interface'

extract_function() {
  /usr/bin/awk -v name="$2" '
    $0 == name "() {" { in_func = 1 }
    in_func { print }
    in_func && $0 == "}" { exit }
  ' "$1"
}

# --- 第一部分：五函数源码逐字节对拍（静态门禁，辅助） ---
# core_pids 是 proxy_provider_pids 的共享委派对象，一并纳入对拍。
for fn in core_pids $PROVIDER_FUNCTIONS $CLIENT_ROUTE_FUNCTIONS; do
  [ "$(/usr/bin/grep -c "^${fn}() {" "$CHECK")" = "1" ]
  [ "$(/usr/bin/grep -c "^${fn}() {" "$BACKEND")" = "1" ]
  extract_function "$CHECK" "$fn" > "$TEST_ROOT/check.$fn"
  extract_function "$BACKEND" "$fn" > "$TEST_ROOT/backend.$fn"
  [ "$(/usr/bin/head -n 1 "$TEST_ROOT/check.$fn")" = "$fn() {" ]
  [ "$(/usr/bin/tail -n 1 "$TEST_ROOT/check.$fn")" = "}" ]
  [ "$(/usr/bin/wc -l < "$TEST_ROOT/check.$fn" | /usr/bin/tr -d ' ')" -ge 3 ]
  if ! /usr/bin/diff -u "$TEST_ROOT/check.$fn" "$TEST_ROOT/backend.$fn"; then
    echo "provider 函数在 check.sh 与 backend.sh 中发生漂移: $fn" >&2
    exit 1
  fi
done

# --- 第二部分：五函数行为对拍 ---
# 把两个脚本中的 provider 函数分别抽出成可 source 的夹具，在同一组注入
# 环境下分别执行并逐字节比较输出，保证"平行副本"永远同步演进。
CHECK_FNS="$TEST_ROOT/check-provider-fns.sh"
BACKEND_FNS="$TEST_ROOT/backend-provider-fns.sh"
for fn in core_pids $PROVIDER_FUNCTIONS $CLIENT_ROUTE_FUNCTIONS $ROUTE_QUERY_FUNCTIONS; do
  extract_function "$CHECK" "$fn" >> "$CHECK_FNS"
  /usr/bin/printf '\n' >> "$CHECK_FNS"
  extract_function "$BACKEND" "$fn" >> "$BACKEND_FNS"
  /usr/bin/printf '\n' >> "$BACKEND_FNS"
done

# 真实命名的常驻进程充当 Shadowrocket / MacPacketTunnel / mihomo，
# 让 provider_pid_name 走真实 ps 名字解析（与 test-backend.sh 同模式）。
if ! /usr/bin/clang --version >/dev/null 2>&1; then
  echo 'SKIP: clang 不可用，无法编译 provider 夹具进程。'
  exit 0
fi
PROVIDER_HELPER_SRC="$TEST_ROOT/provider-helper.c"
/usr/bin/printf '%s\n' \
  '#include <unistd.h>' \
  'int main(void) { for (;;) pause(); }' > "$PROVIDER_HELPER_SRC"
/usr/bin/clang -o "$TEST_ROOT/provider-helper" "$PROVIDER_HELPER_SRC"
/bin/cp "$TEST_ROOT/provider-helper" "$TEST_ROOT/Shadowrocket"
/bin/cp "$TEST_ROOT/provider-helper" "$TEST_ROOT/MacPacketTunnel"
/bin/cp "$TEST_ROOT/provider-helper" "$TEST_ROOT/mihomo"
"$TEST_ROOT/Shadowrocket" &
shadowrocket_test_pid=$!
"$TEST_ROOT/MacPacketTunnel" &
packet_tunnel_test_pid=$!
"$TEST_ROOT/mihomo" &
mihomo_test_pid=$!
PROVIDER_TEST_PIDS="$shadowrocket_test_pid $packet_tunnel_test_pid $mihomo_test_pid"
shadowrocket_provider_pids="$shadowrocket_test_pid
$packet_tunnel_test_pid"

# 保证已死的 PID：用孤儿进程（父 shell 立即退出，sleep 被 launchd 收养），
# kill 后由 launchd 回收——本脚本的 job 表里没有它，不会触发 bash 3.2
# "回收被杀后台任务时提前执行 EXIT trap"的坑；ps -o ucomm= 必为空。
dead_test_pid=$(/bin/bash -c '/bin/sleep 60 >/dev/null 2>&1 & echo $!')
kill "$dead_test_pid" 2>/dev/null || true
sleep 1

assert_fn_scenario() {
  local label="$1"
  shift
  local check_out backend_out
  check_out=$(env "$@" /bin/bash -c '
    . "$1"
    echo "pids:"
    proxy_provider_pids
    echo "pids_status=$?"
    echo "keys:"
    provider_keys
    echo "keys_status=$?"
    echo "count: $(provider_count)"
    echo "label: $(provider_label)"
    for pid in ${FN_PROBE_PIDS:-}; do
      if name=$(provider_pid_name "$pid" 2>/dev/null); then st=0; else st=$?; fi
      /usr/bin/printf "name %s => %s [%s]\n" "$pid" "$name" "$st"
    done
    if name=$(provider_pid_name abc 2>/dev/null); then st=0; else st=$?; fi
    /usr/bin/printf "name abc => %s [%s]\n" "$name" "$st"
    if name=$(provider_pid_name "" 2>/dev/null); then st=0; else st=$?; fi
    /usr/bin/printf "name empty => %s [%s]\n" "$name" "$st"
  ' -- "$CHECK_FNS")
  backend_out=$(env "$@" /bin/bash -c '
    . "$1"
    echo "pids:"
    proxy_provider_pids
    echo "pids_status=$?"
    echo "keys:"
    provider_keys
    echo "keys_status=$?"
    echo "count: $(provider_count)"
    echo "label: $(provider_label)"
    for pid in ${FN_PROBE_PIDS:-}; do
      if name=$(provider_pid_name "$pid" 2>/dev/null); then st=0; else st=$?; fi
      /usr/bin/printf "name %s => %s [%s]\n" "$pid" "$name" "$st"
    done
    if name=$(provider_pid_name abc 2>/dev/null); then st=0; else st=$?; fi
    /usr/bin/printf "name abc => %s [%s]\n" "$name" "$st"
    if name=$(provider_pid_name "" 2>/dev/null); then st=0; else st=$?; fi
    /usr/bin/printf "name empty => %s [%s]\n" "$name" "$st"
  ' -- "$BACKEND_FNS")
  if [ "$check_out" != "$backend_out" ]; then
    echo "provider 函数行为在场景 '$label' 下不一致:" >&2
    /usr/bin/diff -u <(/usr/bin/printf '%s\n' "$check_out") \
      <(/usr/bin/printf '%s\n' "$backend_out") >&2 || true
    exit 1
  fi
  /usr/bin/printf '%s\n' "$check_out"
}

# 场景 A：Shadowrocket 主进程 + NE 进程归并为同一 provider。
fn_out=$(assert_fn_scenario 'shadowrocket-pair' \
  PROXYGAUGE_PROVIDER_PIDS="$shadowrocket_provider_pids" \
  FN_PROBE_PIDS="$shadowrocket_test_pid $packet_tunnel_test_pid")
/usr/bin/grep -Fxq 'shadowrocket' <<< "$fn_out"
/usr/bin/grep -Fxq 'count: 1' <<< "$fn_out"
/usr/bin/grep -Fxq 'label: Shadowrocket' <<< "$fn_out"
/usr/bin/grep -Fxq "name $shadowrocket_test_pid => Shadowrocket [0]" <<< "$fn_out"
/usr/bin/grep -Fxq "name $packet_tunnel_test_pid => MacPacketTunnel [0]" <<< "$fn_out"
/usr/bin/grep -Fxq 'name abc =>  [1]' <<< "$fn_out"
/usr/bin/grep -Fxq 'name empty =>  [1]' <<< "$fn_out"

# 场景 B：单个 mihomo 核心。
fn_out=$(assert_fn_scenario 'single-mihomo' \
  PROXYGAUGE_PROVIDER_PIDS="$mihomo_test_pid" \
  FN_PROBE_PIDS="$mihomo_test_pid")
/usr/bin/grep -Fxq "mihomo:$mihomo_test_pid" <<< "$fn_out"
/usr/bin/grep -Fxq 'count: 1' <<< "$fn_out"
/usr/bin/grep -Fxq 'label: Mihomo' <<< "$fn_out"
/usr/bin/grep -Fxq "name $mihomo_test_pid => mihomo [0]" <<< "$fn_out"

# 场景 C：仅 MacPacketTunnel（Shadowrocket NE 直出、GUI 未运行）也归并为 Shadowrocket。
fn_out=$(assert_fn_scenario 'packet-tunnel-only' \
  PROXYGAUGE_PROVIDER_PIDS="$packet_tunnel_test_pid" \
  FN_PROBE_PIDS="$packet_tunnel_test_pid")
/usr/bin/grep -Fxq 'shadowrocket' <<< "$fn_out"
/usr/bin/grep -Fxq 'count: 1' <<< "$fn_out"
/usr/bin/grep -Fxq 'label: Shadowrocket' <<< "$fn_out"

# 场景 D：Shadowrocket 与 Mihomo 并存 → 2 个 provider，不归因任何一方。
fn_out=$(assert_fn_scenario 'multi-provider' \
  PROXYGAUGE_PROVIDER_PIDS="$shadowrocket_provider_pids
$mihomo_test_pid")
/usr/bin/grep -Fxq 'shadowrocket' <<< "$fn_out"
/usr/bin/grep -Fxq "mihomo:$mihomo_test_pid" <<< "$fn_out"
/usr/bin/grep -Fxq 'count: 2' <<< "$fn_out"
/usr/bin/grep -Fxq 'label: ' <<< "$fn_out"

# 场景 E：零 provider。
fn_out=$(assert_fn_scenario 'no-provider' \
  PROXYGAUGE_PROVIDER_PIDS='')
/usr/bin/grep -Fxq 'count: 0' <<< "$fn_out"
/usr/bin/grep -Fxq 'label: ' <<< "$fn_out"

# 场景 F：注入已死 PID（CORE_PIDS 回退路径）→ unknown，不得解析出名字。
fn_out=$(assert_fn_scenario 'dead-core-pid' \
  PROXYGAUGE_CORE_PIDS="$dead_test_pid" \
  FN_PROBE_PIDS="$dead_test_pid")
/usr/bin/grep -Fxq "unknown:$dead_test_pid" <<< "$fn_out"
/usr/bin/grep -Fxq 'count: 1' <<< "$fn_out"
/usr/bin/grep -Fxq 'label: ' <<< "$fn_out"
/usr/bin/grep -Fxq "name $dead_test_pid =>  [1]" <<< "$fn_out"

# 场景 G：PROVIDER_PIDS 与 CORE_PIDS 同时注入时 PROVIDER_PIDS 优先。
fn_out=$(assert_fn_scenario 'provider-pids-precedence' \
  PROXYGAUGE_PROVIDER_PIDS="$packet_tunnel_test_pid" \
  PROXYGAUGE_CORE_PIDS="$mihomo_test_pid")
/usr/bin/grep -Fxq 'shadowrocket' <<< "$fn_out"
/usr/bin/grep -Fxq 'count: 1' <<< "$fn_out"
if /usr/bin/grep -Fq "mihomo:$mihomo_test_pid" <<< "$fn_out"; then
  echo 'PROXYGAUGE_PROVIDER_PIDS 必须优先于 PROXYGAUGE_CORE_PIDS。' >&2
  exit 1
fi

# --- 共用端到端夹具：注入系统代理/端口/路由，fake curl 保证零真实网络访问 ---
INACTIVE_PROXY_STATE=$'<dictionary> {\n  HTTPEnable : 0\n  HTTPSEnable : 0\n}'
FAKE_CURL="$TEST_ROOT/fake-curl"
/usr/bin/printf '%s\n' '#!/bin/bash' 'exit 94' > "$FAKE_CURL"
/bin/chmod 755 "$FAKE_CURL"

run_check() {
  env \
    PROXYGAUGE_CONFIG=/dev/null \
    PROXYGAUGE_SYSTEM_PROXY_STATE="$INACTIVE_PROXY_STATE" \
    PROXYGAUGE_CURL="$FAKE_CURL" \
    PROXYGAUGE_DISCOVERY_PORT_ACTIVE=0 \
    PROXYGAUGE_MIXED=127.0.0.1:9 \
    PROXYGAUGE_TIMEOUT=1 \
    "$@" /bin/bash "$CHECK" 2>&1 || true
}

run_probe() {
  env \
    PROXYGAUGE_CONFIG=/dev/null \
    PROXYGAUGE_PF_CONF="$TEST_ROOT/missing-pf.conf" \
    PROXYGAUGE_KILL_STATE="$TEST_ROOT/missing-kill-state" \
    PROXYGAUGE_SYSTEM_PROXY_STATE="$INACTIVE_PROXY_STATE" \
    PROXYGAUGE_DISCOVERY_PORT_ACTIVE=0 \
    PROXYGAUGE_MIXED=127.0.0.1:9 \
    "$@" /bin/bash "$BACKEND" probe
}

probe_field() {
  /usr/bin/awk -F '\t' -v key="$1" '$1 == key { print $2 "\t" $3 }'
}

# --- 第三部分：同一注入环境下两脚本 provider 判定输出一致 ---
# 单个 mihomo 核心：check.sh ✅ Mihomo 核心运行中 ⇔ backend core=运行中/ok。
single_mihomo_check=$(run_check \
  PROXYGAUGE_CORE_PIDS="$mihomo_test_pid" \
  PROXYGAUGE_TUN_KIND=none)
/usr/bin/grep -Fq "✅ Mihomo 核心运行中 (PID $mihomo_test_pid)" <<< "$single_mihomo_check"
single_mihomo_probe=$(run_probe \
  PROXYGAUGE_CORE_PIDS="$mihomo_test_pid" \
  PROXYGAUGE_TUN_KIND=none)
[ "$(probe_field core <<< "$single_mihomo_probe")" = $'运行中\tok' ]

# Shadowrocket 主进程 + NE：两脚本都必须归因 Shadowrocket，且不得提及 Mihomo。
shadowrocket_check=$(run_check \
  PROXYGAUGE_CORE_PIDS='' \
  PROXYGAUGE_PROVIDER_PIDS="$shadowrocket_provider_pids" \
  PROXYGAUGE_SECONDARY_ENABLED=0 \
  PROXYGAUGE_TUN_KIND=none)
/usr/bin/grep -Fq "✅ 代理客户端运行中 (Shadowrocket, PID $shadowrocket_test_pid)" <<< "$shadowrocket_check"
if /usr/bin/grep -Fq 'Mihomo' <<< "$shadowrocket_check"; then
  echo 'Shadowrocket 归因的 check.sh 输出不得提及 Mihomo。' >&2
  exit 1
fi
shadowrocket_probe=$(run_probe \
  PROXYGAUGE_CORE_PIDS='' \
  PROXYGAUGE_PROVIDER_PIDS="$shadowrocket_provider_pids" \
  PROXYGAUGE_TUN_KIND=none)
[ "$(probe_field core <<< "$shadowrocket_probe")" = $'Shadowrocket\tok' ]
if /usr/bin/grep -Fq 'Mihomo' <<< "$shadowrocket_probe"; then
  echo 'Shadowrocket 归因的 backend probe 输出不得提及 Mihomo。' >&2
  exit 1
fi

# 仅 NE 进程（MacPacketTunnel）直出：两脚本都必须归因 Shadowrocket。
tunnel_only_check=$(run_check \
  PROXYGAUGE_CORE_PIDS='' \
  PROXYGAUGE_PROVIDER_PIDS="$packet_tunnel_test_pid" \
  PROXYGAUGE_SECONDARY_ENABLED=0 \
  PROXYGAUGE_TUN_KIND=none)
/usr/bin/grep -Fq "✅ 代理客户端运行中 (Shadowrocket, PID $packet_tunnel_test_pid)" <<< "$tunnel_only_check"
tunnel_only_probe=$(run_probe \
  PROXYGAUGE_CORE_PIDS='' \
  PROXYGAUGE_PROVIDER_PIDS="$packet_tunnel_test_pid" \
  PROXYGAUGE_TUN_KIND=none)
[ "$(probe_field core <<< "$tunnel_only_probe")" = $'Shadowrocket\tok' ]

# 零 provider：check.sh ❌ 未发现 ⇔ backend core=未运行/error。
no_provider_check=$(run_check \
  PROXYGAUGE_CORE_PIDS='' \
  PROXYGAUGE_PROVIDER_PIDS='' \
  PROXYGAUGE_SECONDARY_ENABLED=0 \
  PROXYGAUGE_TUN_KIND=none)
/usr/bin/grep -Fq '❌ 未发现代理客户端或核心 — helper 进程不会被误判为核心' <<< "$no_provider_check"
no_provider_probe=$(run_probe \
  PROXYGAUGE_CORE_PIDS='' \
  PROXYGAUGE_PROVIDER_PIDS='' \
  PROXYGAUGE_TUN_KIND=none)
[ "$(probe_field core <<< "$no_provider_probe")" = $'未运行\terror' ]

# --- 第四部分：check.sh 第 1 节计数三态 ---
# 恰 1 → ok（上面的 Mihomo / Shadowrocket / 仅 NE 三个 ✅ 断言已覆盖两种形态）；
# >1 → no：Shadowrocket 与 Mihomo 并存必须判多核心冲突。
multi_provider_check=$(run_check \
  PROXYGAUGE_PROVIDER_PIDS="$shadowrocket_provider_pids
$mihomo_test_pid" \
  PROXYGAUGE_SECONDARY_ENABLED=0 \
  PROXYGAUGE_TUN_KIND=none)
/usr/bin/grep -Fq '❌ 发现 2 个代理客户端或核心 — 可能存在多核心冲突' <<< "$multi_provider_check"
if /usr/bin/grep -Fq '✅ 代理客户端运行中' <<< "$multi_provider_check" \
  || /usr/bin/grep -Fq '✅ Mihomo 核心运行中' <<< "$multi_provider_check"; then
  echo '多 provider 并存时第 1 节不得判 ok。' >&2
  exit 1
fi
# 0 → no（上面零 provider 的 ❌ 断言已覆盖）。

# --- 第五部分：第 3 节 client 隧道归因 ---
# 真实路由分类路径（不注入 TUN_KIND）：Shadowrocket 持有隧道路由时，
# check.sh 必须显示提供者名，且不得出现"不能归因于 Mihomo"；
# backend probe / discover 在同一注入下必须给出相同的归因。
ROUTES_UTUN7=$'inet 1.1.1.1 utun7\ninet 8.8.8.8 utun7\ninet 9.9.9.9 utun7\ninet 208.67.222.222 utun7\ninet6 2606:4700:4700::1111 unavailable\ninet6 2001:4860:4860::8888 unavailable\ninet6 2620:fe::fe unavailable\ninet6 2620:119:35::35 unavailable'
client_route_table=$'default            10.0.0.1           UGScg                 utun7'

# Exercise the real shared client classifier for both available address
# families and incomplete/contradictory route evidence. No route command or
# HTTP request is used: every representative lookup is injected.
assert_client_route_scenario() {
  local label expected routes provider_pids check_kind backend_kind
  label="$1"
  expected="$2"
  routes="$3"
  provider_pids="${4:-$shadowrocket_provider_pids}"
  check_kind=$(env PROXYGAUGE_PROVIDER_PIDS="$provider_pids" \
    PROXYGAUGE_TRUSTED_CLIENT_TUNS='' \
    PROXYGAUGE_TUN_ROUTE_TABLE="$client_route_table" \
    PROXYGAUGE_ROUTE_LOOKUP_RESULTS="$routes" \
    /bin/bash -c '. "$1"; classify_client_tunnel_route' -- "$CHECK_FNS")
  backend_kind=$(env PROXYGAUGE_PROVIDER_PIDS="$provider_pids" \
    PROXYGAUGE_TRUSTED_CLIENT_TUNS='' \
    PROXYGAUGE_TUN_ROUTE_TABLE="$client_route_table" \
    PROXYGAUGE_ROUTE_LOOKUP_RESULTS="$routes" \
    /bin/bash -c '. "$1"; classify_client_tunnel_route' -- "$BACKEND_FNS")
  if [ "$check_kind" != "$expected" ] || [ "$backend_kind" != "$expected" ]; then
    echo "$label client route disagreement: check=$check_kind backend=$backend_kind expected=$expected" >&2
    exit 1
  fi
}
ROUTES_CLIENT_V6_ONLY=$(printf '%s\n' "$ROUTES_UTUN7" \
  | /usr/bin/awk '$1 == "inet" { $3 = "unavailable" } $1 == "inet6" { $3 = "utun7" } { print }')
ROUTES_CLIENT_DUAL=${ROUTES_UTUN7// unavailable/ utun7}
assert_client_route_scenario ipv4-only client "$ROUTES_UTUN7"
assert_client_route_scenario ipv6-only client "$ROUTES_CLIENT_V6_ONLY"
assert_client_route_scenario dual-same-interface client "$ROUTES_CLIENT_DUAL"
assert_client_route_scenario same-family-split other "${ROUTES_UTUN7/inet 8.8.8.8 utun7/inet 8.8.8.8 en0}"
assert_client_route_scenario dual-family-split other "${ROUTES_CLIENT_V6_ONLY// unavailable/ utun8}"
assert_client_route_scenario one-query-unknown other "${ROUTES_UTUN7/inet 9.9.9.9 utun7/inet 9.9.9.9 unknown}"
assert_client_route_scenario partial-family-unavailable other "${ROUTES_UTUN7/inet 9.9.9.9 utun7/inet 9.9.9.9 unavailable}"
assert_client_route_scenario both-families-unavailable other "${ROUTES_UTUN7// utun7/ unavailable}"
assert_client_route_scenario known-v4-unknown-v6 other "${ROUTES_UTUN7// unavailable/ unknown}"
assert_client_route_scenario gui-with-foreign-tunnel other "$ROUTES_UTUN7" "$shadowrocket_test_pid"
assert_client_route_scenario mihomo-without-tun-evidence other "$ROUTES_UTUN7" "$mihomo_test_pid"

client_check=$(run_check \
  PROXYGAUGE_CORE_PIDS='' \
  PROXYGAUGE_PROVIDER_PIDS="$shadowrocket_provider_pids" \
  PROXYGAUGE_SECONDARY_ENABLED=0 \
  PROXYGAUGE_MIHOMO_SOCKET="$TEST_ROOT/missing.sock" \
  PROXYGAUGE_TUN_ROUTE_TABLE="$client_route_table" \
  PROXYGAUGE_ROUTE_LOOKUP_RESULTS="$ROUTES_UTUN7")
/usr/bin/grep -Fq 'ℹ️ Shadowrocket VPN: 代表性隧道路由已确认' <<< "$client_check"
/usr/bin/grep -Fq '✅ 代理入口已生效' <<< "$client_check"
if /usr/bin/grep -Fq '不能归因于 Mihomo' <<< "$client_check"; then
  echo 'client 隧道归因到提供者后，不得再说"不能归因于 Mihomo"。' >&2
  exit 1
fi
if /usr/bin/grep -Fq '归属客户端未知' <<< "$client_check"; then
  echo 'client 隧道归因到提供者后，不得再说"归属客户端未知"。' >&2
  exit 1
fi

client_probe=$(run_probe \
  PROXYGAUGE_CORE_PIDS='' \
  PROXYGAUGE_PROVIDER_PIDS="$shadowrocket_provider_pids" \
  PROXYGAUGE_DISCOVERY_SOCKET="$TEST_ROOT/missing.sock" \
  PROXYGAUGE_TUN_ROUTE_TABLE="$client_route_table" \
  PROXYGAUGE_ROUTE_LOOKUP_RESULTS="$ROUTES_UTUN7")
[ "$(/usr/bin/awk -F '\t' '$1 == "entry" { print $2 "\t" $3 "\t" $4 }' <<< "$client_probe")" \
  = $'代表性路由已确认\tok\tShadowrocket VPN' ]
[ "$(probe_field tun <<< "$client_probe")" = $'代表性路由已确认\tok' ]
[ "$(probe_field core <<< "$client_probe")" = $'Shadowrocket\tok' ]

client_discover=$(env \
  PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_PF_CONF="$TEST_ROOT/missing-pf.conf" \
  PROXYGAUGE_CORE_PIDS='' \
  PROXYGAUGE_PROVIDER_PIDS="$shadowrocket_provider_pids" \
  PROXYGAUGE_SYSTEM_PROXY_STATE="$INACTIVE_PROXY_STATE" \
  PROXYGAUGE_DISCOVERY_CLIENT='Shadowrocket' \
  PROXYGAUGE_DISCOVERY_CONFIG="$TEST_ROOT/missing.yaml" \
  PROXYGAUGE_DISCOVERY_SOCKET="$TEST_ROOT/missing.sock" \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=0 \
  PROXYGAUGE_MIXED=127.0.0.1:9 \
  PROXYGAUGE_TUN_ROUTE_TABLE="$client_route_table" \
  PROXYGAUGE_ROUTE_LOOKUP_RESULTS="$ROUTES_UTUN7" \
  /bin/bash "$BACKEND" discover)
/usr/bin/grep -Fq $'mode\tShadowrocket VPN' <<< "$client_discover"

# --- 第六部分：第 5 节无 Mihomo socket 必须 skip，不得判 no ---
# 即使 provider（Shadowrocket）正在运行，第 5 节的跳过也只 keyed 于 socket 缺失。
secondary_check=$(run_check \
  PROXYGAUGE_CORE_PIDS='' \
  PROXYGAUGE_PROVIDER_PIDS="$shadowrocket_provider_pids" \
  PROXYGAUGE_SECONDARY_ENABLED=1 \
  PROXYGAUGE_SECONDARY_LABEL='Parity 链路' \
  PROXYGAUGE_SECONDARY_MIXED=127.0.0.1:8 \
  PROXYGAUGE_MIHOMO_SOCKET="$TEST_ROOT/missing.sock" \
  PROXYGAUGE_TUN_KIND=none)
/usr/bin/grep -Fq '===== 5. 额外分流链路 (Parity 链路) =====' <<< "$secondary_check"
/usr/bin/grep -Fq '未检测到 Mihomo 控制 socket；跳过可选策略组与规则检查' <<< "$secondary_check"
if /usr/bin/grep -Fq '无法读取 Mihomo 额外分流状态' <<< "$secondary_check"; then
  echo '缺少 Mihomo socket 时必须保持 skip，不得升级为读取失败。' >&2
  exit 1
fi
section5=$(/usr/bin/awk '
  /^===== 5\./ { in_section = 1 }
  /^===== 6\./ { in_section = 0 }
  in_section { print }
' <<< "$secondary_check")
/usr/bin/grep -Fq '未检测到 Parity 链路 策略组或本地入口' <<< "$section5"
if /usr/bin/grep -Fq '❌' <<< "$section5"; then
  echo '无 Mihomo socket 时第 5 节不得产生任何失败项。' >&2
  exit 1
fi

echo 'ProxyGauge check/backend provider parity tests passed.'
