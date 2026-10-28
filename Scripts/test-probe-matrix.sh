#!/bin/bash
set -euo pipefail

# probe 状态全矩阵：提供者 {mihomo, Shadowrocket, 无} × 入口 {仅系统代理, 仅隧道, 双入口, 无}。
# 全部通过 PROXYGAUGE_* 注入驱动 proxygauge-backend.sh probe，验证整体结论、
# 文案归因与各卡状态；非 mihomo 提供者的输出不得出现 "Mihomo" 字样。

SCRIPT_DIR=$(/usr/bin/dirname "$0")
BACKEND="$SCRIPT_DIR/proxygauge-backend.sh"
TEST_ROOT=$(/usr/bin/mktemp -d /tmp/proxygauge-probe-matrix.XXXXXX)
ASSERTIONS=0

cleanup() {
  /bin/rm -rf "$TEST_ROOT"
}
trap cleanup EXIT
# Prevent unconfigured scenarios from consulting or connecting to host proxies.
export PROXYGAUGE_DISCOVERY_CLIENT=未识别
export PROXYGAUGE_DISCOVERY_PORT_ACTIVE=0
export PROXYGAUGE_DISCOVERY_LISTENER_RECORDS=''
export PROXYGAUGE_MIHOMO_SOCKET="$TEST_ROOT/missing.sock"
export PROXYGAUGE_DISCOVERY_SOCKET="$TEST_ROOT/missing.sock"
export PROXYGAUGE_PF_ANCHOR="$TEST_ROOT/missing-anchor"


fail() {
  echo "probe 矩阵断言失败: $1" >&2
  exit 1
}

# Isolated provider lifecycle records; never create proxy-named host processes.
sr_app_pid=51001
sr_ne_pid=51002
SR_PROVIDER_PIDS="$sr_app_pid
$sr_ne_pid"
export PROXYGAUGE_PROVIDER_PROCESS_RECORDS=$'51001\tShadowrocket\tstart-sr\n51002\tMacPacketTunnel\tstart-ne\n56001\tmihomo\tstart-core\n56002\tmihomo\tstart-other-core'
export PROXYGAUGE_NETWORK_SERVICES=$'status\tok\nservice\t11111111-1111-1111-1111-111111111111\tcom.liguangming.Shadowrocket\tconnected\tutun7\tutun7'
export PROXYGAUGE_ROUTE_LOOKUP_RESULTS=$'inet 1.1.1.1 utun7\ninet 8.8.8.8 utun7\ninet 9.9.9.9 utun7\ninet 208.67.222.222 utun7\ninet6 2606:4700:4700::1111 unavailable\ninet6 2001:4860:4860::8888 unavailable\ninet6 2620:fe::fe unavailable\ninet6 2620:119:35::35 unavailable'
export PROXYGAUGE_TUN_ROUTE_TABLE=''
# mihomo 提供者用分配段内的 fake 核心 PID（probe 单核心路径不做 ps 解析）。
FAKE_MIHOMO_CORE_PID=56001
MATRIX_PORT=56190

run_probe() {
  /usr/bin/env \
    PROXYGAUGE_CONFIG=/dev/null \
    PROXYGAUGE_PF_CONF="$TEST_ROOT/missing-pf.conf" \
    PROXYGAUGE_KILL_STATE="$TEST_ROOT/missing-state" \
    PROXYGAUGE_KILL_TOKEN="$TEST_ROOT/missing-token" \
    PROXYGAUGE_SYSTEM_PROXY_STATE='' \
    PROXYGAUGE_MIXED="127.0.0.1:$MATRIX_PORT" \
    "$@" /bin/bash "$BACKEND" probe
}

expect_tail() {
  local out="$1" key="$2" expected="$3" label="$4" line actual
  ASSERTIONS=$((ASSERTIONS + 1))
  line=$(/usr/bin/awk -F '\t' -v key="$key" '$1 == key { print; exit }' <<< "$out")
  [ -n "$line" ] || fail "$label: 缺少 $key 行"
  actual="${line#*$'\t'}"
  if [ "$actual" != "$expected" ]; then
    fail "$label: $key 期望 [$expected] 实际 [$actual]"
  fi
}

expect_schema() {
  local out="$1" label="$2" key
  ASSERTIONS=$((ASSERTIONS + 1))
  for key in overall headline detail core port entry system tun kill; do
    /usr/bin/awk -F '\t' -v key="$key" '$1 == key { found = 1; exit } END { exit found ? 0 : 1 }' \
      <<< "$out" || fail "$label: probe 输出缺少 $key 卡片"
  done
}

expect_no_mihomo() {
  local out="$1" label="$2"
  ASSERTIONS=$((ASSERTIONS + 1))
  if /usr/bin/grep -Fq 'Mihomo' <<< "$out"; then
    fail "$label: 非 mihomo 提供者的 probe 输出不得含 Mihomo 字样"
  fi
}

SYS_PROXY_OK_ENV=(
  PROXYGAUGE_SYSTEM_PROXY_STATE="<dictionary> {
  HTTPEnable : 1
  HTTPProxy : 127.0.0.1
  HTTPPort : $MATRIX_PORT
  HTTPSEnable : 1
  HTTPSProxy : 127.0.0.1
  HTTPSPort : $MATRIX_PORT
  SOCKSEnable : 0
}"
  PROXYGAUGE_SYSTEM_PROXY_ACTIVE=1
  PROXYGAUGE_SYSTEM_PROXY_DYNAMIC=0
  PROXYGAUGE_SYSTEM_PROXY_HTTPS=1
  PROXYGAUGE_SYSTEM_PROXY_BYPASS=0
  PROXYGAUGE_SYSTEM_PROXY_MATCHES=1
)
PORT_OPEN_ENV=(
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=1
  PROXYGAUGE_DISCOVERY_PORT_OWNER=proxy
)
PORT_CLOSED_ENV=(
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=0
)
NO_TUN_ENV=(
  PROXYGAUGE_TUN_ACTIVE=0
  PROXYGAUGE_TUN_KIND=none
)
NO_SYSTEM_ENV=(
  PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0
)

run_cell() {
  local label="$1"
  shift
  local out
  out=$(run_probe "$@")
  expect_schema "$out" "$label"
  CELL_OUT="$out"
}

# ---------- mihomo 提供者（fake 核心 PID） ----------

run_cell 'mihomo×仅系统代理' \
  PROXYGAUGE_CORE_PIDS=$FAKE_MIHOMO_CORE_PID \
  "${SYS_PROXY_OK_ENV[@]}" "${NO_TUN_ENV[@]}" "${PORT_OPEN_ENV[@]}"
expect_tail "$CELL_OUT" overall 'ok' 'mihomo×仅系统代理'
expect_tail "$CELL_OUT" headline '代理已接管' 'mihomo×仅系统代理'
expect_tail "$CELL_OUT" detail '流量入口当前工作正常' 'mihomo×仅系统代理'
expect_tail "$CELL_OUT" core $'运行中\tok' 'mihomo×仅系统代理'
expect_tail "$CELL_OUT" port "$MATRIX_PORT"$' 监听中\tok' 'mihomo×仅系统代理'
expect_tail "$CELL_OUT" entry $'已启用\tok\t系统代理\tarrow.left.arrow.right' 'mihomo×仅系统代理'
expect_tail "$CELL_OUT" system $'已启用\tok' 'mihomo×仅系统代理'
expect_tail "$CELL_OUT" tun $'未接管\tidle' 'mihomo×仅系统代理'

run_cell 'mihomo×仅隧道' \
  PROXYGAUGE_CORE_PIDS=$FAKE_MIHOMO_CORE_PID \
  "${NO_SYSTEM_ENV[@]}" PROXYGAUGE_TUN_ACTIVE=1 PROXYGAUGE_TUN_KIND=mihomo \
  "${PORT_CLOSED_ENV[@]}"
expect_tail "$CELL_OUT" overall 'ok' 'mihomo×仅隧道'
expect_tail "$CELL_OUT" headline '代理路径已确认' 'mihomo×仅隧道'
expect_tail "$CELL_OUT" detail 'Mihomo TUN 的可用公网路由已确认' 'mihomo×仅隧道'
expect_tail "$CELL_OUT" core $'运行中\tok' 'mihomo×仅隧道'
expect_tail "$CELL_OUT" port "$MATRIX_PORT"$' 非当前入口\tidle' 'mihomo×仅隧道'
expect_tail "$CELL_OUT" entry $'代表性路由已确认\tok\tTUN 路由\tarrow.triangle.2.circlepath' 'mihomo×仅隧道'
expect_tail "$CELL_OUT" system $'未启用\tidle' 'mihomo×仅隧道'
expect_tail "$CELL_OUT" tun $'代表性路由已确认\tok' 'mihomo×仅隧道'

run_cell 'mihomo×双入口' \
  PROXYGAUGE_CORE_PIDS=$FAKE_MIHOMO_CORE_PID \
  "${SYS_PROXY_OK_ENV[@]}" PROXYGAUGE_TUN_ACTIVE=1 PROXYGAUGE_TUN_KIND=mihomo \
  PROXYGAUGE_DISCOVERY_LISTENER_RECORDS="p$FAKE_MIHOMO_CORE_PID
n127.0.0.1:$MATRIX_PORT" \
  "${PORT_OPEN_ENV[@]}"
expect_tail "$CELL_OUT" overall 'ok' 'mihomo×双入口'
expect_tail "$CELL_OUT" headline '代理路径已确认' 'mihomo×双入口'
expect_tail "$CELL_OUT" detail '系统代理与 Mihomo TUN 均已启用' 'mihomo×双入口'
expect_tail "$CELL_OUT" core $'运行中\tok' 'mihomo×双入口'
expect_tail "$CELL_OUT" port "$MATRIX_PORT"$' 监听中\tok' 'mihomo×双入口'
expect_tail "$CELL_OUT" entry $'同时开启\tok\t双重入口\tarrow.triangle.2.circlepath' 'mihomo×双入口'
expect_tail "$CELL_OUT" system $'已启用\tok' 'mihomo×双入口'
expect_tail "$CELL_OUT" tun $'代表性路由已确认\tok' 'mihomo×双入口'

run_cell 'mihomo×无入口' \
  PROXYGAUGE_CORE_PIDS=$FAKE_MIHOMO_CORE_PID \
  "${NO_SYSTEM_ENV[@]}" "${NO_TUN_ENV[@]}" "${PORT_CLOSED_ENV[@]}"
expect_tail "$CELL_OUT" overall 'error' 'mihomo×无入口'
expect_tail "$CELL_OUT" headline '代理未完整生效' 'mihomo×无入口'
expect_tail "$CELL_OUT" detail '请检查代理核心、本地入口与系统代理或 TUN 后刷新' 'mihomo×无入口'
expect_tail "$CELL_OUT" core $'运行中\tok' 'mihomo×无入口'
expect_tail "$CELL_OUT" port "$MATRIX_PORT"$' 未监听\terror' 'mihomo×无入口'
expect_tail "$CELL_OUT" entry $'未启用\tidle\t流量入口\tarrow.triangle.branch' 'mihomo×无入口'
expect_tail "$CELL_OUT" system $'未启用\tidle' 'mihomo×无入口'
expect_tail "$CELL_OUT" tun $'未接管\tidle' 'mihomo×无入口'

# ---------- Shadowrocket 提供者（隔离进程表，无 mihomo 核心） ----------

run_cell 'Shadowrocket×仅系统代理' \
  PROXYGAUGE_CORE_PIDS='' PROXYGAUGE_PROVIDER_PIDS="$SR_PROVIDER_PIDS" \
  "${SYS_PROXY_OK_ENV[@]}" "${NO_TUN_ENV[@]}" "${PORT_OPEN_ENV[@]}"
expect_tail "$CELL_OUT" overall 'ok' 'Shadowrocket×仅系统代理'
expect_tail "$CELL_OUT" headline '代理已接管' 'Shadowrocket×仅系统代理'
expect_tail "$CELL_OUT" detail '流量入口当前工作正常' 'Shadowrocket×仅系统代理'
expect_tail "$CELL_OUT" core $'Shadowrocket\tok' 'Shadowrocket×仅系统代理'
expect_tail "$CELL_OUT" port "$MATRIX_PORT"$' 监听中\tok' 'Shadowrocket×仅系统代理'
expect_tail "$CELL_OUT" entry $'已启用\tok\t系统代理\tarrow.left.arrow.right' 'Shadowrocket×仅系统代理'
expect_tail "$CELL_OUT" system $'已启用\tok' 'Shadowrocket×仅系统代理'
expect_tail "$CELL_OUT" tun $'未接管\tidle' 'Shadowrocket×仅系统代理'
expect_no_mihomo "$CELL_OUT" 'Shadowrocket×仅系统代理'

run_cell 'Shadowrocket×仅隧道' \
  PROXYGAUGE_CORE_PIDS='' PROXYGAUGE_PROVIDER_PIDS="$SR_PROVIDER_PIDS" \
  "${NO_SYSTEM_ENV[@]}" PROXYGAUGE_TUN_ACTIVE=1 PROXYGAUGE_TUN_KIND=client \
  "${PORT_CLOSED_ENV[@]}"
expect_tail "$CELL_OUT" overall 'ok' 'Shadowrocket×仅隧道'
expect_tail "$CELL_OUT" headline '代理路径已确认' 'Shadowrocket×仅隧道'
expect_tail "$CELL_OUT" detail 'Shadowrocket VPN 的可用公网路由已确认' 'Shadowrocket×仅隧道'
expect_tail "$CELL_OUT" core $'Shadowrocket\tok' 'Shadowrocket×仅隧道'
expect_tail "$CELL_OUT" port "$MATRIX_PORT"$' 非当前入口\tidle' 'Shadowrocket×仅隧道'
expect_tail "$CELL_OUT" entry $'代表性路由已确认\tok\tShadowrocket VPN\tarrow.triangle.2.circlepath' 'Shadowrocket×仅隧道'
expect_tail "$CELL_OUT" system $'未启用\tidle' 'Shadowrocket×仅隧道'
expect_tail "$CELL_OUT" tun $'代表性路由已确认\tok' 'Shadowrocket×仅隧道'
expect_no_mihomo "$CELL_OUT" 'Shadowrocket×仅隧道'

run_cell 'Shadowrocket×双入口' \
  PROXYGAUGE_CORE_PIDS='' PROXYGAUGE_PROVIDER_PIDS="$SR_PROVIDER_PIDS" \
  "${SYS_PROXY_OK_ENV[@]}" PROXYGAUGE_TUN_ACTIVE=1 PROXYGAUGE_TUN_KIND=client \
  PROXYGAUGE_DISCOVERY_LISTENER_RECORDS="p$sr_ne_pid
n127.0.0.1:$MATRIX_PORT" \
  "${PORT_OPEN_ENV[@]}"
expect_tail "$CELL_OUT" overall 'ok' 'Shadowrocket×双入口'
expect_tail "$CELL_OUT" headline '代理路径已确认' 'Shadowrocket×双入口'
expect_tail "$CELL_OUT" detail '系统代理与 Shadowrocket VPN 均已启用' 'Shadowrocket×双入口'
expect_tail "$CELL_OUT" core $'Shadowrocket\tok' 'Shadowrocket×双入口'
expect_tail "$CELL_OUT" port "$MATRIX_PORT"$' 监听中\tok' 'Shadowrocket×双入口'
expect_tail "$CELL_OUT" entry $'同时开启\tok\t双重入口\tarrow.triangle.2.circlepath' 'Shadowrocket×双入口'
expect_tail "$CELL_OUT" system $'已启用\tok' 'Shadowrocket×双入口'
expect_tail "$CELL_OUT" tun $'代表性路由已确认\tok' 'Shadowrocket×双入口'
expect_no_mihomo "$CELL_OUT" 'Shadowrocket×双入口'

run_cell 'Shadowrocket×无入口' \
  PROXYGAUGE_CORE_PIDS='' PROXYGAUGE_PROVIDER_PIDS="$SR_PROVIDER_PIDS" \
  "${NO_SYSTEM_ENV[@]}" "${NO_TUN_ENV[@]}" "${PORT_CLOSED_ENV[@]}"
expect_tail "$CELL_OUT" overall 'error' 'Shadowrocket×无入口'
expect_tail "$CELL_OUT" headline '代理未完整生效' 'Shadowrocket×无入口'
expect_tail "$CELL_OUT" detail '请检查代理核心、本地入口与系统代理或 TUN 后刷新' 'Shadowrocket×无入口'
expect_tail "$CELL_OUT" core $'Shadowrocket\tok' 'Shadowrocket×无入口'
expect_tail "$CELL_OUT" port "$MATRIX_PORT"$' 未监听\terror' 'Shadowrocket×无入口'
expect_tail "$CELL_OUT" entry $'未启用\tidle\t流量入口\tarrow.triangle.branch' 'Shadowrocket×无入口'
expect_tail "$CELL_OUT" system $'未启用\tidle' 'Shadowrocket×无入口'
expect_tail "$CELL_OUT" tun $'未接管\tidle' 'Shadowrocket×无入口'
expect_no_mihomo "$CELL_OUT" 'Shadowrocket×无入口'

# ---------- 无提供者 ----------

run_cell '无提供者×仅系统代理' \
  PROXYGAUGE_CORE_PIDS='' PROXYGAUGE_PROVIDER_PIDS='' \
  "${SYS_PROXY_OK_ENV[@]}" "${NO_TUN_ENV[@]}" "${PORT_CLOSED_ENV[@]}"
expect_tail "$CELL_OUT" overall 'warning' '无提供者×仅系统代理'
expect_tail "$CELL_OUT" headline '检测到系统代理路径' '无提供者×仅系统代理'
expect_tail "$CELL_OUT" detail '系统代理已启用，但不是当前已确认的 当前代理客户端 入口；请以系统实际出口为准' '无提供者×仅系统代理'
expect_tail "$CELL_OUT" core $'未运行\terror' '无提供者×仅系统代理'
expect_tail "$CELL_OUT" port "$MATRIX_PORT"$' 未监听\terror' '无提供者×仅系统代理'
expect_tail "$CELL_OUT" entry $'已启用\tok\t系统代理\tarrow.left.arrow.right' '无提供者×仅系统代理'
expect_tail "$CELL_OUT" system $'已启用\tok' '无提供者×仅系统代理'
expect_tail "$CELL_OUT" tun $'未接管\tidle' '无提供者×仅系统代理'
expect_no_mihomo "$CELL_OUT" '无提供者×仅系统代理'

run_cell '无提供者×仅隧道' \
  PROXYGAUGE_CORE_PIDS='' PROXYGAUGE_PROVIDER_PIDS='' \
  "${NO_SYSTEM_ENV[@]}" PROXYGAUGE_TUN_ACTIVE=1 PROXYGAUGE_TUN_KIND=other \
  "${PORT_CLOSED_ENV[@]}"
expect_tail "$CELL_OUT" overall 'warning' '无提供者×仅隧道'
expect_tail "$CELL_OUT" headline '检测到其他 VPN/TUN' '无提供者×仅隧道'
expect_tail "$CELL_OUT" detail '系统存在活动隧道路由，但不能归因于 当前代理客户端；请以系统实际出口为准' '无提供者×仅隧道'
expect_tail "$CELL_OUT" core $'未运行\terror' '无提供者×仅隧道'
expect_tail "$CELL_OUT" port "$MATRIX_PORT"$' 未监听\terror' '无提供者×仅隧道'
expect_tail "$CELL_OUT" entry $'已检测\twarning\t其他 VPN / TUN\texclamationmark.triangle.fill' '无提供者×仅隧道'
expect_tail "$CELL_OUT" system $'未启用\tidle' '无提供者×仅隧道'
expect_tail "$CELL_OUT" tun $'检测到其他隧道\twarning' '无提供者×仅隧道'
expect_no_mihomo "$CELL_OUT" '无提供者×仅隧道'

run_cell '无提供者×双入口' \
  PROXYGAUGE_CORE_PIDS='' PROXYGAUGE_PROVIDER_PIDS='' \
  "${SYS_PROXY_OK_ENV[@]}" PROXYGAUGE_TUN_ACTIVE=1 PROXYGAUGE_TUN_KIND=mihomo \
  "${PORT_CLOSED_ENV[@]}"
expect_tail "$CELL_OUT" overall 'warning' '无提供者×双入口'
expect_tail "$CELL_OUT" headline '检测到系统代理路径' '无提供者×双入口'
expect_tail "$CELL_OUT" detail '系统代理已启用，但不是当前已确认的 当前代理客户端 入口；请以系统实际出口为准' '无提供者×双入口'
expect_tail "$CELL_OUT" core $'未运行\terror' '无提供者×双入口'
expect_tail "$CELL_OUT" entry $'同时开启\twarning\t双重入口\texclamationmark.triangle.fill' '无提供者×双入口'
expect_tail "$CELL_OUT" system $'已启用\tok' '无提供者×双入口'
expect_tail "$CELL_OUT" tun $'代表性路由已确认\tok' '无提供者×双入口'
expect_no_mihomo "$CELL_OUT" '无提供者×双入口'

run_cell '无提供者×无入口' \
  PROXYGAUGE_CORE_PIDS='' PROXYGAUGE_PROVIDER_PIDS='' \
  "${NO_SYSTEM_ENV[@]}" "${NO_TUN_ENV[@]}" "${PORT_CLOSED_ENV[@]}"
expect_tail "$CELL_OUT" overall 'error' '无提供者×无入口'
expect_tail "$CELL_OUT" headline '代理未完整生效' '无提供者×无入口'
expect_tail "$CELL_OUT" detail '请检查代理核心、本地入口与系统代理或 TUN 后刷新' '无提供者×无入口'
expect_tail "$CELL_OUT" core $'未运行\terror' '无提供者×无入口'
expect_tail "$CELL_OUT" port "$MATRIX_PORT"$' 未监听\terror' '无提供者×无入口'
expect_tail "$CELL_OUT" entry $'未启用\tidle\t流量入口\tarrow.triangle.branch' '无提供者×无入口'
expect_tail "$CELL_OUT" system $'未启用\tidle' '无提供者×无入口'
expect_tail "$CELL_OUT" tun $'未接管\tidle' '无提供者×无入口'
expect_tail "$CELL_OUT" kill $'未配置\tidle' '无提供者×无入口'
expect_no_mihomo "$CELL_OUT" '无提供者×无入口'


# Dual paths are normal only when both ownership and system configuration are
# confirmed. All these cases use isolated records, never live proxy processes.
DUAL_BOUNDARY_CASES=0
assert_problem_dual() {
  local label="$1" out level
  shift
  out=$(run_probe "$@")
  expect_schema "$out" "$label"
  expect_tail "$out" overall warning "$label"
  level=$(/usr/bin/awk -F '\t' '$1 == "entry" {print $3}' <<< "$out")
  ASSERTIONS=$((ASSERTIONS + 1))
  [ "$level" = warning ] || fail "$label: 未确认或有问题的双入口不能显示绿色"
  DUAL_BOUNDARY_CASES=$((DUAL_BOUNDARY_CASES + 1))
}
SR_DUAL_ENV=(
  PROXYGAUGE_CORE_PIDS=''
  PROXYGAUGE_PROVIDER_PIDS="$SR_PROVIDER_PIDS"
  "${SYS_PROXY_OK_ENV[@]}"
  PROXYGAUGE_TUN_ACTIVE=1
  PROXYGAUGE_TUN_KIND=client
  "${PORT_OPEN_ENV[@]}"
  PROXYGAUGE_DISCOVERY_LISTENER_RECORDS="p$sr_ne_pid
n127.0.0.1:$MATRIX_PORT"
)
assert_problem_dual 'Shadowrocket×动态PAC双入口' "${SR_DUAL_ENV[@]}" PROXYGAUGE_SYSTEM_PROXY_DYNAMIC=1
assert_problem_dual 'Shadowrocket×入口不匹配' "${SR_DUAL_ENV[@]}" PROXYGAUGE_SYSTEM_PROXY_MATCHES=0
assert_problem_dual 'Shadowrocket×HTTPS缺失' "${SR_DUAL_ENV[@]}" PROXYGAUGE_SYSTEM_PROXY_HTTPS=0
assert_problem_dual 'Shadowrocket×出口域名绕过' "${SR_DUAL_ENV[@]}" PROXYGAUGE_SYSTEM_PROXY_BYPASS=1
assert_problem_dual 'Shadowrocket×监听归属不唯一' "${SR_DUAL_ENV[@]}" \
  PROXYGAUGE_DISCOVERY_LISTENER_RECORDS="p$sr_app_pid
n127.0.0.1:$MATRIX_PORT
p$sr_ne_pid
n127.0.0.1:$MATRIX_PORT"
assert_problem_dual 'Shadowrocket×未识别监听归属' "${SR_DUAL_ENV[@]}" PROXYGAUGE_DISCOVERY_LISTENER_RECORDS=''
assert_problem_dual 'MihomoTUN×Shadowrocket系统代理' \
  PROXYGAUGE_CORE_PIDS=$FAKE_MIHOMO_CORE_PID \
  PROXYGAUGE_PROVIDER_PIDS="$FAKE_MIHOMO_CORE_PID
$sr_ne_pid" "${SYS_PROXY_OK_ENV[@]}" \
  PROXYGAUGE_TUN_ACTIVE=1 PROXYGAUGE_TUN_KIND=mihomo "${PORT_OPEN_ENV[@]}" \
  PROXYGAUGE_DISCOVERY_LISTENER_RECORDS="p$sr_ne_pid
n127.0.0.1:$MATRIX_PORT"
assert_problem_dual 'MihomoTUN×另一核心系统代理' \
  PROXYGAUGE_CORE_PIDS=$FAKE_MIHOMO_CORE_PID PROXYGAUGE_PROVIDER_PIDS=$'56001\n56002' \
  "${SYS_PROXY_OK_ENV[@]}" PROXYGAUGE_TUN_ACTIVE=1 PROXYGAUGE_TUN_KIND=mihomo \
  "${PORT_OPEN_ENV[@]}" PROXYGAUGE_DISCOVERY_LISTENER_RECORDS="p56002
n127.0.0.1:$MATRIX_PORT"
for kind in mihomo-unconfirmed split unknown other; do
  assert_problem_dual "Mihomo×问题路由$kind" \
    PROXYGAUGE_CORE_PIDS=$FAKE_MIHOMO_CORE_PID "${SYS_PROXY_OK_ENV[@]}" \
    PROXYGAUGE_TUN_ACTIVE=1 PROXYGAUGE_TUN_KIND="$kind" "${PORT_OPEN_ENV[@]}" \
    PROXYGAUGE_DISCOVERY_LISTENER_RECORDS="p$FAKE_MIHOMO_CORE_PID
n127.0.0.1:$MATRIX_PORT"
done


# Inspect all enabled protocols, not only the preferred HTTPS endpoint.
PROTOCOL_CASES=0
protocol_snapshot() {
  local http_enabled="$1" http_host="$2" http_port="$3" socks_enabled="${4:-0}" socks_host="${5:-127.0.0.1}" socks_port="${6:-56192}"
  /usr/bin/printf '<dictionary> {\n  HTTPEnable : %s\n  HTTPProxy : %s\n  HTTPPort : %s\n  HTTPSEnable : 1\n  HTTPSProxy : 127.0.0.1\n  HTTPSPort : %s\n  SOCKSEnable : %s\n  SOCKSProxy : %s\n  SOCKSPort : %s\n}\n' \
    "$http_enabled" "$http_host" "$http_port" "$MATRIX_PORT" "$socks_enabled" "$socks_host" "$socks_port"
}
assert_protocol_dual() {
  local label="$1" snapshot="$2" records="$3" expected="$4" out level
  out=$(run_probe "${SR_DUAL_ENV[@]}" PROXYGAUGE_SYSTEM_PROXY_STATE="$snapshot" \
    PROXYGAUGE_DISCOVERY_LISTENER_RECORDS="$records")
  expect_schema "$out" "$label"
  expect_tail "$out" overall "$expected" "$label"
  level=$(/usr/bin/awk -F '\t' '$1 == "entry" {print $3}' <<< "$out")
  ASSERTIONS=$((ASSERTIONS + 1))
  [ "$level" = "$expected" ] || fail "$label: entry期望$expected 实际$level"
  PROTOCOL_CASES=$((PROTOCOL_CASES + 1))
}
SR_PRIMARY_RECORDS="p$sr_ne_pid
n127.0.0.1:$MATRIX_PORT"
SR_DIFFERENT_PORT_RECORDS="$SR_PRIMARY_RECORDS
p$sr_app_pid
n127.0.0.1:56191"
assert_protocol_dual 'HTTP未知owner×HTTPS当前SR' "$(protocol_snapshot 1 127.0.0.1 56191)" \
  "$SR_PRIMARY_RECORDS
p51999
n127.0.0.1:56191" warning
assert_protocol_dual 'HTTP和HTTPS同端点' "$(protocol_snapshot 1 127.0.0.1 "$MATRIX_PORT")" "$SR_PRIMARY_RECORDS" ok
assert_protocol_dual 'HTTP不同端口同SR客户端' "$(protocol_snapshot 1 127.0.0.1 56191)" "$SR_DIFFERENT_PORT_RECORDS" ok
assert_protocol_dual 'HTTP不同提供者×HTTPS当前SR' "$(protocol_snapshot 1 127.0.0.1 56191)" \
  "$SR_PRIMARY_RECORDS
p$FAKE_MIHOMO_CORE_PID
n127.0.0.1:56191" warning
assert_protocol_dual 'HTTP多owner×HTTPS当前SR' "$(protocol_snapshot 1 127.0.0.1 56191)" \
  "$SR_DIFFERENT_PORT_RECORDS
p$sr_ne_pid
n127.0.0.1:56191" warning
assert_protocol_dual 'HTTP远端端点' "$(protocol_snapshot 1 192.0.2.10 56191)" "$SR_PRIMARY_RECORDS" warning
assert_protocol_dual 'HTTP缺失端点字段' "$(protocol_snapshot 1 '' 56191)" "$SR_PRIMARY_RECORDS" warning
assert_protocol_dual 'HTTP停用残留字段' "$(protocol_snapshot 0 192.0.2.10 invalid)" "$SR_PRIMARY_RECORDS" ok
assert_protocol_dual 'SOCKS未知owner×HTTPS当前SR' "$(protocol_snapshot 0 127.0.0.1 56191 1 127.0.0.1 56192)" \
  "$SR_PRIMARY_RECORDS
p51999
n127.0.0.1:56192" warning
assert_protocol_dual 'SOCKS不同端口同当前SR' "$(protocol_snapshot 0 127.0.0.1 56191 1 127.0.0.1 56192)" \
  "$SR_PRIMARY_RECORDS
p$sr_ne_pid
n127.0.0.1:56192" ok


# Different ports must still belong to the exact confirmed Mihomo core. A second
# running Mihomo provider is a duplicate-core conflict on its own, so 56002 is
# only a stray listener here, not a provider.
for http_owner in "$FAKE_MIHOMO_CORE_PID" 56002; do
  if [ "$http_owner" = "$FAKE_MIHOMO_CORE_PID" ]; then expected=ok; else expected=warning; fi
  protocol_out=$(run_probe PROXYGAUGE_CORE_PIDS=$FAKE_MIHOMO_CORE_PID \
    PROXYGAUGE_PROVIDER_PIDS=$FAKE_MIHOMO_CORE_PID "${SYS_PROXY_OK_ENV[@]}" \
    PROXYGAUGE_TUN_ACTIVE=1 PROXYGAUGE_TUN_KIND=mihomo "${PORT_OPEN_ENV[@]}" \
    PROXYGAUGE_SYSTEM_PROXY_STATE="$(protocol_snapshot 1 127.0.0.1 56191)" \
    PROXYGAUGE_DISCOVERY_LISTENER_RECORDS="p$FAKE_MIHOMO_CORE_PID
n127.0.0.1:$MATRIX_PORT
p$http_owner
n127.0.0.1:56191")
  expect_schema "$protocol_out" "Mihomo多协议owner=$http_owner"
  expect_tail "$protocol_out" overall "$expected" "Mihomo多协议owner=$http_owner"
  protocol_level=$(/usr/bin/awk -F '\t' '$1 == "entry" {print $3}' <<< "$protocol_out")
  ASSERTIONS=$((ASSERTIONS + 1))
  [ "$protocol_level" = "$expected" ] || fail "Mihomo多协议owner=$http_owner: entry期望$expected 实际$protocol_level"
  PROTOCOL_CASES=$((PROTOCOL_CASES + 1))
done

echo "ProxyGauge probe 状态全矩阵测试通过（12 组合、$DUAL_BOUNDARY_CASES 个双入口边界、$PROTOCOL_CASES 个协议边界，$ASSERTIONS 条断言）。"
