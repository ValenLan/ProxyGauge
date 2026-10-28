#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
BACKEND="$SCRIPT_DIR/proxygauge-backend.sh"
TEST_ROOT=$(/usr/bin/mktemp -d /tmp/proxygauge-provider-detection.XXXXXX)
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


# 静态门禁（仅辅助，行为断言见下文）：双进程名归一映射与 1082 兜底端口必须存在。
/usr/bin/grep -Fq 'Shadowrocket|MacPacketTunnel)' "$BACKEND"
/usr/bin/grep -Fq 'for port in 7890 7897 1082; do' "$BACKEND"

TEST_PF_CONF="$TEST_ROOT/pf.conf"
/usr/bin/printf '%s\n' 'anchor "proxygauge"' > "$TEST_PF_CONF"
export PROXYGAUGE_PF_CONF="$TEST_PF_CONF"
export PROXYGAUGE_KILL_STATE="$TEST_ROOT/missing-kill-state"

# Isolated provider table; no proxy-named processes or host pgrep dependency.
SR_PID=51001
MPT_PID=51002
MIHOMO_PID=51003
UNKNOWN_PID=51004
BOTH_PROVIDER_PIDS="$SR_PID
$MPT_PID"
export PROXYGAUGE_PROVIDER_PROCESS_RECORDS=$'51001\tShadowrocket\tstart-sr\n51002\tMacPacketTunnel\tstart-ne\n51003\tmihomo\tstart-core\n51004\tpgunknownx\tstart-unknown'
export PROXYGAUGE_NETWORK_SERVICES=$'status\tok\nservice\t11111111-1111-1111-1111-111111111111\tcom.liguangming.Shadowrocket\tconnected\tutun5\tutun5'
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
assert_client_tun_entry 'utun5,utun6' "$OTHER_TUN_ENTRY"
assert_client_tun_entry 'utun05,utun5' "$OTHER_TUN_ENTRY"
assert_client_tun_entry '' "$CLIENT_VPN_ENTRY"
# 合法但指向错误设备：路由必须降级为“其他”，不得归因于 Shadowrocket。
assert_client_tun_entry 'utun6' "$OTHER_TUN_ENTRY"
# 非法格式或包含服务未绑定接口必须降级，不得靠默认路由推断归属。
assert_client_tun_entry 'utun5 utun6' "$OTHER_TUN_ENTRY"
assert_client_tun_entry 'utun5,' "$OTHER_TUN_ENTRY"
assert_client_tun_entry 'utun' "$OTHER_TUN_ENTRY"
assert_client_tun_entry 'en0' "$OTHER_TUN_ENTRY"

INJECTION_MARKER="$TEST_ROOT/trusted-tuns-code-executed"
assert_client_tun_entry 'utun5;$(touch '"$INJECTION_MARKER"')' "$OTHER_TUN_ENTRY"
[ ! -e "$INJECTION_MARKER" ]

# 超长或含未绑定设备的列表均不能补足服务归属证据。
TRUSTED_LIST_63=$(/usr/bin/seq 1 63 | /usr/bin/sed 's/^/utun/' | /usr/bin/paste -sd, -)
TRUSTED_LIST_64=$(/usr/bin/seq 1 64 | /usr/bin/sed 's/^/utun/' | /usr/bin/paste -sd, -)
assert_client_tun_entry "$TRUSTED_LIST_63" "$OTHER_TUN_ENTRY" "$ROUTE_TABLE_UTUN9"
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

# 未识别的进程（注入进程表中的名字不在任何已知列表）不得被谎称 Mihomo / Clash /
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

# mihomo + Shadowrocket 同时运行：与链路检测一致判为多核心冲突，且不得猜测归因。
# 实时枚举中 mihomo 同时出现在 core_pids 与 provider 列表里，夹具按此注入。
MULTI_PROVIDER_PIDS="$BOTH_PROVIDER_PIDS
$MIHOMO_PID"

multi_provider_probe=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CORE_PIDS="$MIHOMO_PID" \
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
[ "$(/usr/bin/awk -F '\t' '$1 == "headline" { print $2 }' <<< "$multi_provider_probe")" = '状态异常' ]
[ "$(/usr/bin/awk -F '\t' '$1 == "detail" { print $2 }' <<< "$multi_provider_probe")" = '检测到多个代理核心，请关闭重复核心后刷新状态' ]
[ "$(/usr/bin/awk -F '\t' '$1 == "core" { print $2 "\t" $3 }' <<< "$multi_provider_probe")" = $'2 个核心\twarning' ]
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

echo 'ProxyGauge provider detection tests passed.'
