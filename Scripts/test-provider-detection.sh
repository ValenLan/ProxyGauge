#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
BACKEND="$SCRIPT_DIR/proxygauge-backend.sh"
TEST_ROOT=$(/usr/bin/mktemp -d /tmp/proxygauge-provider-detection.XXXXXX)
HELPER_PID_LIST=""
cleanup() {
  if [ -n "$HELPER_PID_LIST" ]; then
    /bin/kill $HELPER_PID_LIST 2>/dev/null || true
  fi
  /bin/rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

# 静态门禁（仅辅助，行为断言见下文）：双进程名归一映射与 1082 兜底端口必须存在。
/usr/bin/grep -Fq 'Shadowrocket|MacPacketTunnel)' "$BACKEND"
/usr/bin/grep -Fq 'for port in 7890 7897 1082; do' "$BACKEND"

TEST_PF_CONF="$TEST_ROOT/pf.conf"
/usr/bin/printf '%s\n' 'anchor "proxygauge"' > "$TEST_PF_CONF"
export PROXYGAUGE_PF_CONF="$TEST_PF_CONF"
export PROXYGAUGE_KILL_STATE="$TEST_ROOT/missing-kill-state"

# macOS 会 SIGKILL 改名后的系统 binary，因此自行编译 pause() helper 并复制成
# 各提供者进程名，用真实 ps/pgrep 名字解析验证 provider 归并与边界。
HELPER_SRC="$TEST_ROOT/provider-helper.c"
/usr/bin/printf '%s\n' \
  '#include <unistd.h>' \
  'int main(void) { for (;;) pause(); }' > "$HELPER_SRC"
/usr/bin/clang -o "$TEST_ROOT/provider-helper" "$HELPER_SRC"
for helper_name in Shadowrocket MacPacketTunnel mihomo pgunknownx; do
  /bin/cp "$TEST_ROOT/provider-helper" "$TEST_ROOT/$helper_name"
done

"$TEST_ROOT/Shadowrocket" &
SR_PID=$!
"$TEST_ROOT/MacPacketTunnel" &
MPT_PID=$!
"$TEST_ROOT/pgunknownx" &
UNKNOWN_PID=$!
HELPER_PID_LIST="$SR_PID
$MPT_PID
$UNKNOWN_PID"
BOTH_PROVIDER_PIDS="$SR_PID
$MPT_PID"

ROUTES_UTUN5_V4=$'inet 1.1.1.1 utun5\ninet 8.8.8.8 utun5\ninet 9.9.9.9 utun5\ninet 208.67.222.222 utun5\ninet6 2606:4700:4700::1111 unavailable\ninet6 2001:4860:4860::8888 unavailable\ninet6 2620:fe::fe unavailable\ninet6 2620:119:35::35 unavailable'
ROUTE_TABLE_UTUN5='default            198.18.0.1          UGScg                 utun5'
ROUTE_TABLE_UTUN9='default            198.18.0.1          UGScg                 utun9'
ROUTE_TABLE_PHYSICAL='default            192.0.2.1           UGScg                 en0'
CLIENT_VPN_ENTRY=$'代表性路由已确认\tok\tShadowrocket VPN'
OTHER_TUN_ENTRY=$'已检测\twarning\t其他 VPN / TUN'

# Shadowrocket 主进程 + MacPacketTunnel 网络扩展双进程必须归一为 1 个提供者，
# 而不是被计为“2 个核心”或两个 provider。
dual_provider_probe=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CORE_PIDS='' \
  PROXYGAUGE_PROVIDER_PIDS="$BOTH_PROVIDER_PIDS" \
  PROXYGAUGE_MIXED=127.0.0.1:1082 \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=1 \
  PROXYGAUGE_DISCOVERY_LISTENER_RECORDS="p$MPT_PID
n127.0.0.1:1082" \
  PROXYGAUGE_SYSTEM_PROXY_ACTIVE=1 \
  PROXYGAUGE_SYSTEM_PROXY_DYNAMIC=0 \
  PROXYGAUGE_SYSTEM_PROXY_HTTPS=1 \
  PROXYGAUGE_SYSTEM_PROXY_BYPASS=0 \
  PROXYGAUGE_SYSTEM_PROXY_MATCHES=1 \
  PROXYGAUGE_TUN_KIND=none \
  /bin/bash "$BACKEND" probe)
[ "$(/usr/bin/awk -F '\t' '$1 == "overall" { print $2 }' <<< "$dual_provider_probe")" = ok ]
[ "$(/usr/bin/awk -F '\t' '$1 == "headline" { print $2 }' <<< "$dual_provider_probe")" = '代理已接管' ]
[ "$(/usr/bin/awk -F '\t' '$1 == "core" { print $2 "\t" $3 }' <<< "$dual_provider_probe")" = $'Shadowrocket\tok' ]
[ "$(/usr/bin/awk -F '\t' '$1 == "port" { print $2 "\t" $3 }' <<< "$dual_provider_probe")" = $'1082 监听中\tok' ]
[ "$(/usr/bin/awk -F '\t' '$1 == "entry" { print $2 "\t" $3 "\t" $4 }' <<< "$dual_provider_probe")" = $'已启用\tok\t系统代理' ]
if /usr/bin/grep -Fq '2 个核心' <<< "$dual_provider_probe"; then
  echo 'Shadowrocket 主进程与 MacPacketTunnel 必须归一为 1 个提供者。' >&2
  exit 1
fi
if /usr/bin/grep -Fq 'Mihomo' <<< "$dual_provider_probe"; then
  echo 'Shadowrocket 双进程归一不得被标注为 Mihomo。' >&2
  exit 1
fi

# 仅 Shadowrocket 主进程（无网络扩展进程、纯系统代理路径）也必须识别为 Shadowrocket。
main_only_probe=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CORE_PIDS='' \
  PROXYGAUGE_PROVIDER_PIDS="$SR_PID" \
  PROXYGAUGE_MIXED=127.0.0.1:1082 \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=1 \
  PROXYGAUGE_DISCOVERY_LISTENER_RECORDS="p$SR_PID
n127.0.0.1:1082" \
  PROXYGAUGE_SYSTEM_PROXY_ACTIVE=1 \
  PROXYGAUGE_SYSTEM_PROXY_DYNAMIC=0 \
  PROXYGAUGE_SYSTEM_PROXY_HTTPS=1 \
  PROXYGAUGE_SYSTEM_PROXY_BYPASS=0 \
  PROXYGAUGE_SYSTEM_PROXY_MATCHES=1 \
  PROXYGAUGE_TUN_KIND=none \
  /bin/bash "$BACKEND" probe)
[ "$(/usr/bin/awk -F '\t' '$1 == "overall" { print $2 }' <<< "$main_only_probe")" = ok ]
[ "$(/usr/bin/awk -F '\t' '$1 == "core" { print $2 "\t" $3 }' <<< "$main_only_probe")" = $'Shadowrocket\tok' ]
[ "$(/usr/bin/awk -F '\t' '$1 == "port" { print $2 "\t" $3 }' <<< "$main_only_probe")" = $'1082 监听中\tok' ]
[ "$(/usr/bin/awk -F '\t' '$1 == "entry" { print $2 "\t" $3 "\t" $4 }' <<< "$main_only_probe")" = $'已启用\tok\t系统代理' ]
if /usr/bin/grep -Fq 'Mihomo' <<< "$main_only_probe"; then
  echo '仅 Shadowrocket 主进程的系统代理路径不得被标注为 Mihomo。' >&2
  exit 1
fi

# 仅 MacPacketTunnel（NE 直出、无系统代理）也必须识别为 Shadowrocket 并确认 VPN 路由。
ne_only_probe=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CORE_PIDS='' \
  PROXYGAUGE_PROVIDER_PIDS="$MPT_PID" \
  PROXYGAUGE_MIXED=127.0.0.1:1082 \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=0 \
  PROXYGAUGE_DISCOVERY_SOCKET="$TEST_ROOT/missing.sock" \
  PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_ROUTE_TABLE="$ROUTE_TABLE_UTUN5" \
  PROXYGAUGE_TRUSTED_CLIENT_TUNS='utun5' \
  PROXYGAUGE_ROUTE_LOOKUP_RESULTS="$ROUTES_UTUN5_V4" \
  /bin/bash "$BACKEND" probe)
[ "$(/usr/bin/awk -F '\t' '$1 == "overall" { print $2 }' <<< "$ne_only_probe")" = ok ]
[ "$(/usr/bin/awk -F '\t' '$1 == "headline" { print $2 }' <<< "$ne_only_probe")" = '代理路径已确认' ]
[ "$(/usr/bin/awk -F '\t' '$1 == "detail" { print $2 }' <<< "$ne_only_probe")" = 'Shadowrocket VPN 的可用公网路由已确认' ]
[ "$(/usr/bin/awk -F '\t' '$1 == "core" { print $2 "\t" $3 }' <<< "$ne_only_probe")" = $'Shadowrocket\tok' ]
[ "$(/usr/bin/awk -F '\t' '$1 == "entry" { print $2 "\t" $3 "\t" $4 }' <<< "$ne_only_probe")" = "$CLIENT_VPN_ENTRY" ]
[ "$(/usr/bin/awk -F '\t' '$1 == "tun" { print $2 "\t" $3 }' <<< "$ne_only_probe")" = $'代表性路由已确认\tok' ]
[ "$(/usr/bin/awk -F '\t' '$1 == "port" { print $2 "\t" $3 }' <<< "$ne_only_probe")" = $'1082 非当前入口\tidle' ]
if /usr/bin/grep -Fq 'Mihomo' <<< "$ne_only_probe"; then
  echo '仅 MacPacketTunnel 的 VPN 路由不得被归因于 Mihomo。' >&2
  exit 1
fi

ne_only_discovery=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CORE_PIDS='' \
  PROXYGAUGE_PROVIDER_PIDS="$MPT_PID" \
  PROXYGAUGE_DISCOVERY_CONFIG="$TEST_ROOT/missing.yaml" \
  PROXYGAUGE_DISCOVERY_SOCKET="$TEST_ROOT/missing.sock" \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=0 \
  PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_ROUTE_TABLE="$ROUTE_TABLE_UTUN5" \
  PROXYGAUGE_TRUSTED_CLIENT_TUNS='utun5' \
  PROXYGAUGE_ROUTE_LOOKUP_RESULTS="$ROUTES_UTUN5_V4" \
  /bin/bash "$BACKEND" discover)
/usr/bin/grep -Fq $'mode\tShadowrocket VPN' <<< "$ne_only_discovery"

# PROXYGAUGE_TRUSTED_CLIENT_TUNS 格式边界：逗号分隔、最多 63 个 utun 设备；
# 非法格式不得报错或注入，必须静默回落到路由表候选。
assert_client_tun_entry() {
  local trusted expected route_table actual
  trusted="$1"
  expected="$2"
  route_table="${3:-$ROUTE_TABLE_UTUN5}"
  actual=$(PROXYGAUGE_CONFIG=/dev/null \
    PROXYGAUGE_CORE_PIDS='' \
    PROXYGAUGE_PROVIDER_PIDS="$BOTH_PROVIDER_PIDS" \
    PROXYGAUGE_MIXED=127.0.0.1:1082 \
    PROXYGAUGE_DISCOVERY_PORT_ACTIVE=0 \
    PROXYGAUGE_DISCOVERY_SOCKET="$TEST_ROOT/missing.sock" \
    PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
    PROXYGAUGE_TUN_ROUTE_TABLE="$route_table" \
    PROXYGAUGE_TRUSTED_CLIENT_TUNS="$trusted" \
    PROXYGAUGE_ROUTE_LOOKUP_RESULTS="$ROUTES_UTUN5_V4" \
    /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "entry" { print $2 "\t" $3 "\t" $4 }')
  if [ "$actual" != "$expected" ]; then
    echo "PROXYGAUGE_TRUSTED_CLIENT_TUNS='$trusted' 的隧道分类错误: $actual（期望 $expected）" >&2
    exit 1
  fi
}

assert_client_tun_entry 'utun5' "$CLIENT_VPN_ENTRY"
assert_client_tun_entry 'utun5,utun6' "$CLIENT_VPN_ENTRY"
assert_client_tun_entry 'utun05,utun5' "$CLIENT_VPN_ENTRY"
assert_client_tun_entry '' "$CLIENT_VPN_ENTRY"
# 合法但指向错误设备：路由必须降级为“其他”，不得归因于 Shadowrocket。
assert_client_tun_entry 'utun6' "$OTHER_TUN_ENTRY"
# 非法格式（空格分隔、尾随逗号、缺数字、非 utun）一律回落到路由表候选。
assert_client_tun_entry 'utun5 utun6' "$CLIENT_VPN_ENTRY"
assert_client_tun_entry 'utun5,' "$CLIENT_VPN_ENTRY"
assert_client_tun_entry 'utun' "$CLIENT_VPN_ENTRY"
assert_client_tun_entry 'en0' "$CLIENT_VPN_ENTRY"

INJECTION_MARKER="$TEST_ROOT/trusted-tuns-code-executed"
assert_client_tun_entry 'utun5;$(touch '"$INJECTION_MARKER"')' "$CLIENT_VPN_ENTRY"
[ ! -e "$INJECTION_MARKER" ]

# 63 个设备是上限：63 个（含 utun5）合法；64 个被拒绝并回落到路由表候选
# （路由表默认走 utun9，而代表性路由走 utun5，回落后必须判为“其他”）。
TRUSTED_LIST_63=$(/usr/bin/seq 1 63 | /usr/bin/sed 's/^/utun/' | /usr/bin/paste -sd, -)
TRUSTED_LIST_64=$(/usr/bin/seq 1 64 | /usr/bin/sed 's/^/utun/' | /usr/bin/paste -sd, -)
assert_client_tun_entry "$TRUSTED_LIST_63" "$CLIENT_VPN_ENTRY" "$ROUTE_TABLE_UTUN9"
assert_client_tun_entry "$TRUSTED_LIST_64" "$OTHER_TUN_ENTRY" "$ROUTE_TABLE_UTUN9"

wrong_device_probe=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CORE_PIDS='' \
  PROXYGAUGE_PROVIDER_PIDS="$BOTH_PROVIDER_PIDS" \
  PROXYGAUGE_MIXED=127.0.0.1:1082 \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=0 \
  PROXYGAUGE_DISCOVERY_SOCKET="$TEST_ROOT/missing.sock" \
  PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_ROUTE_TABLE="$ROUTE_TABLE_UTUN5" \
  PROXYGAUGE_TRUSTED_CLIENT_TUNS='utun6' \
  PROXYGAUGE_ROUTE_LOOKUP_RESULTS="$ROUTES_UTUN5_V4" \
  /bin/bash "$BACKEND" probe)
[ "$(/usr/bin/awk -F '\t' '$1 == "overall" { print $2 }' <<< "$wrong_device_probe")" = warning ]
[ "$(/usr/bin/awk -F '\t' '$1 == "headline" { print $2 }' <<< "$wrong_device_probe")" = '检测到其他 VPN/TUN' ]
[ "$(/usr/bin/awk -F '\t' '$1 == "detail" { print $2 }' <<< "$wrong_device_probe")" = '系统存在活动隧道路由，但不能归因于 Shadowrocket；请以系统实际出口为准' ]
[ "$(/usr/bin/awk -F '\t' '$1 == "tun" { print $2 "\t" $3 }' <<< "$wrong_device_probe")" = $'检测到其他隧道\twarning' ]

# 端口兜底表必须包含 1082：系统代理 / 控制器 / 配置文件都缺失时，监听在
# 1082 且归属于当前提供者的端口必须被发现；归属外部进程的 1082 不得认领。
fallback_1082_discovery=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CORE_PIDS='' \
  PROXYGAUGE_PROVIDER_PIDS="$BOTH_PROVIDER_PIDS" \
  PROXYGAUGE_DISCOVERY_CONFIG="$TEST_ROOT/missing.yaml" \
  PROXYGAUGE_DISCOVERY_SOCKET="$TEST_ROOT/missing.sock" \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=1 \
  PROXYGAUGE_DISCOVERY_LISTENER_RECORDS="p$MPT_PID
n127.0.0.1:1082" \
  PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_ROUTE_TABLE="$ROUTE_TABLE_PHYSICAL" \
  /bin/bash "$BACKEND" discover)
/usr/bin/grep -Fq $'found\t1' <<< "$fallback_1082_discovery"
/usr/bin/grep -Fq $'endpoint\t127.0.0.1:1082' <<< "$fallback_1082_discovery"
/usr/bin/grep -Fq $'source\t本地监听端口' <<< "$fallback_1082_discovery"
/usr/bin/grep -Fq $'active\tok' <<< "$fallback_1082_discovery"
/usr/bin/grep -Fq $'mode\t未开启' <<< "$fallback_1082_discovery"

fallback_foreign_discovery=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CORE_PIDS='' \
  PROXYGAUGE_PROVIDER_PIDS="$BOTH_PROVIDER_PIDS" \
  PROXYGAUGE_DISCOVERY_CONFIG="$TEST_ROOT/missing.yaml" \
  PROXYGAUGE_DISCOVERY_SOCKET="$TEST_ROOT/missing.sock" \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=1 \
  PROXYGAUGE_DISCOVERY_LISTENER_RECORDS=$'p54010\nn127.0.0.1:1082' \
  PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_ROUTE_TABLE="$ROUTE_TABLE_PHYSICAL" \
  /bin/bash "$BACKEND" discover)
/usr/bin/grep -Fq $'found\t0' <<< "$fallback_foreign_discovery"
/usr/bin/grep -Fq $'endpoint\t127.0.0.1:7890' <<< "$fallback_foreign_discovery"
/usr/bin/grep -Fq $'source\t手动设置' <<< "$fallback_foreign_discovery"
/usr/bin/grep -Fq $'active\tidle' <<< "$fallback_foreign_discovery"

# 未识别的进程（真实 ps 名字解析后不在任何已知列表）不得被谎称 Mihomo / Clash /
# Shadowrocket，其隧道也必须降级为“其他”。
unknown_provider_probe=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CORE_PIDS='' \
  PROXYGAUGE_PROVIDER_PIDS="$UNKNOWN_PID" \
  PROXYGAUGE_MIXED=127.0.0.1:9 \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=0 \
  PROXYGAUGE_DISCOVERY_SOCKET="$TEST_ROOT/missing.sock" \
  PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_ROUTE_TABLE="$ROUTE_TABLE_UTUN5" \
  PROXYGAUGE_TRUSTED_CLIENT_TUNS='utun5' \
  PROXYGAUGE_ROUTE_LOOKUP_RESULTS="$ROUTES_UTUN5_V4" \
  /bin/bash "$BACKEND" probe)
[ "$(/usr/bin/awk -F '\t' '$1 == "overall" { print $2 }' <<< "$unknown_provider_probe")" = warning ]
[ "$(/usr/bin/awk -F '\t' '$1 == "headline" { print $2 }' <<< "$unknown_provider_probe")" = '检测到其他 VPN/TUN' ]
[ "$(/usr/bin/awk -F '\t' '$1 == "detail" { print $2 }' <<< "$unknown_provider_probe")" = '系统存在活动隧道路由，但不能归因于 当前代理客户端；请以系统实际出口为准' ]
[ "$(/usr/bin/awk -F '\t' '$1 == "core" { print $2 "\t" $3 }' <<< "$unknown_provider_probe")" = $'未运行\terror' ]
[ "$(/usr/bin/awk -F '\t' '$1 == "entry" { print $2 "\t" $3 "\t" $4 }' <<< "$unknown_provider_probe")" = "$OTHER_TUN_ENTRY" ]
if /usr/bin/grep -Eq 'Mihomo|Shadowrocket|Clash' <<< "$unknown_provider_probe"; then
  echo '未识别进程不得被标注为任何已知代理提供者。' >&2
  exit 1
fi

unknown_provider_discovery=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CORE_PIDS='' \
  PROXYGAUGE_PROVIDER_PIDS="$UNKNOWN_PID" \
  PROXYGAUGE_DISCOVERY_CONFIG="$TEST_ROOT/missing.yaml" \
  PROXYGAUGE_DISCOVERY_SOCKET="$TEST_ROOT/missing.sock" \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=0 \
  PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_ROUTE_TABLE="$ROUTE_TABLE_UTUN5" \
  PROXYGAUGE_TRUSTED_CLIENT_TUNS='utun5' \
  PROXYGAUGE_ROUTE_LOOKUP_RESULTS="$ROUTES_UTUN5_V4" \
  /bin/bash "$BACKEND" discover)
/usr/bin/grep -Fq $'mode\t其他 VPN / TUN' <<< "$unknown_provider_discovery"
/usr/bin/grep -Fq $'found\t0' <<< "$unknown_provider_discovery"

# 已失效的 PID（NE 记录残留）不得解析出任何提供者。
STALE_PIDS_FREE=1
for stale_pid in 54020 54021; do
  if /bin/ps -p "$stale_pid" >/dev/null 2>&1; then
    STALE_PIDS_FREE=0
  fi
done
if [ "$STALE_PIDS_FREE" = 1 ]; then
  stale_provider_probe=$(PROXYGAUGE_CONFIG=/dev/null \
    PROXYGAUGE_CORE_PIDS='' \
    PROXYGAUGE_PROVIDER_PIDS=$'54020\n54021' \
    PROXYGAUGE_MIXED=127.0.0.1:9 \
    PROXYGAUGE_DISCOVERY_PORT_ACTIVE=0 \
    PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
    PROXYGAUGE_TUN_ROUTE_TABLE="$ROUTE_TABLE_PHYSICAL" \
    /bin/bash "$BACKEND" probe)
  [ "$(/usr/bin/awk -F '\t' '$1 == "overall" { print $2 }' <<< "$stale_provider_probe")" = error ]
  [ "$(/usr/bin/awk -F '\t' '$1 == "core" { print $2 "\t" $3 }' <<< "$stale_provider_probe")" = $'未运行\terror' ]
  if /usr/bin/grep -Eq 'Mihomo|Shadowrocket|Clash' <<< "$stale_provider_probe"; then
    echo '失效 PID 不得被解析为任何已知代理提供者。' >&2
    exit 1
  fi
else
  echo 'SKIP: 54020/54021 被实机进程占用，跳过失效 PID 用例。'
fi

# 真实 pgrep/ps 路径（不注入 PID 列表）。实机若存在其他 mihomo 系核心进程，
# 归一结论会被污染，此类只读实机检查条件不满足时打印 SKIP，不得 fail。
foreign_pids() {
  local name pid
  {
    for name in "$@"; do
      /usr/bin/pgrep -x "$name" 2>/dev/null || true
    done
  } | /usr/bin/awk 'NF && !seen[$0]++' | while IFS= read -r pid; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    if ! /usr/bin/grep -Fqx "$pid" <<< "$HELPER_PID_LIST"; then
      /usr/bin/printf '%s\n' "$pid"
    fi
  done
}

if [ -z "$(foreign_pids verge-mihomo mihomo clash-meta)" ]; then
  real_dual_probe=$(PROXYGAUGE_CONFIG=/dev/null \
    PROXYGAUGE_MIXED=127.0.0.1:54099 \
    PROXYGAUGE_DISCOVERY_PORT_ACTIVE=0 \
    PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
    PROXYGAUGE_TUN_ROUTE_TABLE="$ROUTE_TABLE_PHYSICAL" \
    /bin/bash "$BACKEND" probe)
  [ "$(/usr/bin/awk -F '\t' '$1 == "core" { print $2 "\t" $3 }' <<< "$real_dual_probe")" = $'Shadowrocket\tok' ]
  if /usr/bin/grep -Fq '2 个核心' <<< "$real_dual_probe"; then
    echo '真实 pgrep 路径下 Shadowrocket 双进程也必须归一为 1 个提供者。' >&2
    exit 1
  fi
else
  echo 'SKIP: 实机存在其他 mihomo 系核心进程，跳过真实 pgrep 归一用例。'
fi

if [ -z "$(foreign_pids verge-mihomo mihomo clash-meta clash sing-box singbox xray v2ray iKuuuVPNCore ikuuuvpncore)" ]; then
  real_client_discovery=$(PROXYGAUGE_CONFIG=/dev/null \
    PROXYGAUGE_DISCOVERY_CONFIG="$TEST_ROOT/missing.yaml" \
    PROXYGAUGE_DISCOVERY_SOCKET="$TEST_ROOT/missing.sock" \
    PROXYGAUGE_DISCOVERY_PORT_ACTIVE=0 \
    PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
    PROXYGAUGE_TUN_ROUTE_TABLE="$ROUTE_TABLE_PHYSICAL" \
    /bin/bash "$BACKEND" discover)
  /usr/bin/grep -Fq $'client\tShadowrocket' <<< "$real_client_discovery"
else
  echo 'SKIP: 实机存在其他代理客户端进程，跳过真实客户端识别用例。'
fi

# mihomo + Shadowrocket 同时运行：多个提供者必须降级为“其他”，不得猜测归因。
"$TEST_ROOT/mihomo" &
MIHOMO_PID=$!
HELPER_PID_LIST="$HELPER_PID_LIST
$MIHOMO_PID"
MULTI_PROVIDER_PIDS="$BOTH_PROVIDER_PIDS
$MIHOMO_PID"

multi_provider_probe=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CORE_PIDS='' \
  PROXYGAUGE_PROVIDER_PIDS="$MULTI_PROVIDER_PIDS" \
  PROXYGAUGE_MIXED=127.0.0.1:1082 \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=0 \
  PROXYGAUGE_DISCOVERY_SOCKET="$TEST_ROOT/missing.sock" \
  PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_ROUTE_TABLE="$ROUTE_TABLE_UTUN5" \
  PROXYGAUGE_TRUSTED_CLIENT_TUNS='utun5' \
  PROXYGAUGE_ROUTE_LOOKUP_RESULTS="$ROUTES_UTUN5_V4" \
  /bin/bash "$BACKEND" probe)
[ "$(/usr/bin/awk -F '\t' '$1 == "overall" { print $2 }' <<< "$multi_provider_probe")" = warning ]
[ "$(/usr/bin/awk -F '\t' '$1 == "headline" { print $2 }' <<< "$multi_provider_probe")" = '检测到其他 VPN/TUN' ]
[ "$(/usr/bin/awk -F '\t' '$1 == "detail" { print $2 }' <<< "$multi_provider_probe")" = '系统存在活动隧道路由，但不能归因于 当前代理客户端；请以系统实际出口为准' ]
[ "$(/usr/bin/awk -F '\t' '$1 == "core" { print $2 "\t" $3 }' <<< "$multi_provider_probe")" = $'未运行\terror' ]
[ "$(/usr/bin/awk -F '\t' '$1 == "entry" { print $2 "\t" $3 "\t" $4 }' <<< "$multi_provider_probe")" = "$OTHER_TUN_ENTRY" ]
if /usr/bin/grep -Eq 'Mihomo|Shadowrocket' <<< "$multi_provider_probe"; then
  echo '多提供者并存时必须降级为其他，不得猜测归因。' >&2
  exit 1
fi

multi_provider_discovery=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CORE_PIDS='' \
  PROXYGAUGE_PROVIDER_PIDS="$MULTI_PROVIDER_PIDS" \
  PROXYGAUGE_DISCOVERY_CLIENT='Shadowrocket' \
  PROXYGAUGE_DISCOVERY_SYSTEM_PROXY=127.0.0.1:1082 \
  PROXYGAUGE_DISCOVERY_CONFIG="$TEST_ROOT/missing.yaml" \
  PROXYGAUGE_DISCOVERY_SOCKET="$TEST_ROOT/missing.sock" \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=0 \
  PROXYGAUGE_SYSTEM_PROXY_ACTIVE=1 \
  PROXYGAUGE_SYSTEM_PROXY_DYNAMIC=0 \
  PROXYGAUGE_TUN_ROUTE_TABLE="$ROUTE_TABLE_UTUN5" \
  PROXYGAUGE_TRUSTED_CLIENT_TUNS='utun5' \
  PROXYGAUGE_ROUTE_LOOKUP_RESULTS="$ROUTES_UTUN5_V4" \
  /bin/bash "$BACKEND" discover)
/usr/bin/grep -Fq $'mode\t系统代理 + 其他 VPN / TUN' <<< "$multi_provider_discovery"
if /usr/bin/grep -Fq 'Shadowrocket VPN' <<< "$multi_provider_discovery"; then
  echo '多提供者并存时 discover 不得猜测为 Shadowrocket VPN。' >&2
  exit 1
fi

multi_provider_tun_discovery=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CORE_PIDS='' \
  PROXYGAUGE_PROVIDER_PIDS="$MULTI_PROVIDER_PIDS" \
  PROXYGAUGE_DISCOVERY_CLIENT='Shadowrocket' \
  PROXYGAUGE_DISCOVERY_CONFIG="$TEST_ROOT/missing.yaml" \
  PROXYGAUGE_DISCOVERY_SOCKET="$TEST_ROOT/missing.sock" \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=0 \
  PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_ROUTE_TABLE="$ROUTE_TABLE_UTUN5" \
  PROXYGAUGE_TRUSTED_CLIENT_TUNS='utun5' \
  PROXYGAUGE_ROUTE_LOOKUP_RESULTS="$ROUTES_UTUN5_V4" \
  /bin/bash "$BACKEND" discover)
/usr/bin/grep -Fq $'mode\t其他 VPN / TUN' <<< "$multi_provider_tun_discovery"

# 真实路径：mihomo 核心与 Shadowrocket 并存时，detected_running_client 命中
# 两个不同客户端，必须输出“未识别”而不是猜测其一；probe 的 core 行则由唯一
# 核心（mihomo）优先接管。
if [ -z "$(foreign_pids verge-mihomo mihomo clash-meta clash sing-box singbox xray v2ray iKuuuVPNCore ikuuuvpncore)" ]; then
  real_multi_discovery=$(PROXYGAUGE_CONFIG=/dev/null \
    PROXYGAUGE_DISCOVERY_CONFIG="$TEST_ROOT/missing.yaml" \
    PROXYGAUGE_DISCOVERY_SOCKET="$TEST_ROOT/missing.sock" \
    PROXYGAUGE_DISCOVERY_PORT_ACTIVE=0 \
    PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
    PROXYGAUGE_TUN_ROUTE_TABLE="$ROUTE_TABLE_PHYSICAL" \
    /bin/bash "$BACKEND" discover)
  /usr/bin/grep -Fq $'client\t未识别' <<< "$real_multi_discovery"
else
  echo 'SKIP: 实机存在其他代理客户端进程，跳过真实多客户端识别用例。'
fi

if [ -z "$(foreign_pids verge-mihomo mihomo clash-meta)" ]; then
  real_core_probe=$(PROXYGAUGE_CONFIG=/dev/null \
    PROXYGAUGE_MIXED=127.0.0.1:54099 \
    PROXYGAUGE_DISCOVERY_PORT_ACTIVE=0 \
    PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
    PROXYGAUGE_TUN_ROUTE_TABLE="$ROUTE_TABLE_PHYSICAL" \
    /bin/bash "$BACKEND" probe)
  [ "$(/usr/bin/awk -F '\t' '$1 == "core" { print $2 "\t" $3 }' <<< "$real_core_probe")" = $'运行中\tok' ]
else
  echo 'SKIP: 实机存在其他 mihomo 系核心进程，跳过真实核心优先用例。'
fi

echo 'ProxyGauge provider detection tests passed.'
