#!/bin/bash
set -euo pipefail

# probe 状态全矩阵：提供者 {mihomo, Shadowrocket, 无} × 入口 {仅系统代理, 仅隧道, 双入口, 无}。
# 全部通过 PROXYGAUGE_* 注入驱动 proxygauge-backend.sh probe，验证整体结论、
# 文案归因与各卡状态；非 mihomo 提供者的输出不得出现 "Mihomo" 字样。

SCRIPT_DIR=$(/usr/bin/dirname "$0")
BACKEND="$SCRIPT_DIR/proxygauge-backend.sh"
TEST_ROOT=$(/usr/bin/mktemp -d /tmp/proxygauge-probe-matrix.XXXXXX)
SR_PIDS=""
ASSERTIONS=0

cleanup() {
  if [ -n "$SR_PIDS" ]; then
    /bin/kill $SR_PIDS 2>/dev/null || true
  fi
  /bin/rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  echo "probe 矩阵断言失败: $1" >&2
  exit 1
}

# Shadowrocket 提供者需要真实进程名解析（provider_pid_name 走 ps），
# 编译一个可改名常驻 helper，分别以 Shadowrocket / MacPacketTunnel 名字运行。
PROVIDER_HELPER_SRC="$TEST_ROOT/provider-helper.c"
/usr/bin/printf '%s\n' \
  '#include <unistd.h>' \
  'int main(void) { for (;;) pause(); }' > "$PROVIDER_HELPER_SRC"
/usr/bin/clang -o "$TEST_ROOT/provider-helper" "$PROVIDER_HELPER_SRC"
/bin/cp "$TEST_ROOT/provider-helper" "$TEST_ROOT/Shadowrocket"
/bin/cp "$TEST_ROOT/provider-helper" "$TEST_ROOT/MacPacketTunnel"
"$TEST_ROOT/Shadowrocket" &
sr_app_pid=$!
"$TEST_ROOT/MacPacketTunnel" &
sr_ne_pid=$!
SR_PIDS="$sr_app_pid $sr_ne_pid"
SR_PROVIDER_PIDS="$sr_app_pid
$sr_ne_pid"

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
  "${PORT_OPEN_ENV[@]}"
expect_tail "$CELL_OUT" overall 'warning' 'mihomo×双入口'
expect_tail "$CELL_OUT" headline '入口同时开启' 'mihomo×双入口'
expect_tail "$CELL_OUT" detail '系统代理与 Mihomo TUN 均已启用' 'mihomo×双入口'
expect_tail "$CELL_OUT" core $'运行中\tok' 'mihomo×双入口'
expect_tail "$CELL_OUT" port "$MATRIX_PORT"$' 监听中\tok' 'mihomo×双入口'
expect_tail "$CELL_OUT" entry $'同时开启\twarning\t双重入口\texclamationmark.triangle.fill' 'mihomo×双入口'
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

# ---------- Shadowrocket 提供者（真实命名的常驻进程，无 mihomo 核心） ----------

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
  "${PORT_OPEN_ENV[@]}"
expect_tail "$CELL_OUT" overall 'warning' 'Shadowrocket×双入口'
expect_tail "$CELL_OUT" headline '入口同时开启' 'Shadowrocket×双入口'
expect_tail "$CELL_OUT" detail '系统代理与 Shadowrocket VPN 均已启用' 'Shadowrocket×双入口'
expect_tail "$CELL_OUT" core $'Shadowrocket\tok' 'Shadowrocket×双入口'
expect_tail "$CELL_OUT" port "$MATRIX_PORT"$' 监听中\tok' 'Shadowrocket×双入口'
expect_tail "$CELL_OUT" entry $'同时开启\twarning\t双重入口\texclamationmark.triangle.fill' 'Shadowrocket×双入口'
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

echo "ProxyGauge probe 状态全矩阵测试通过（12 组合，$ASSERTIONS 条断言）。"
