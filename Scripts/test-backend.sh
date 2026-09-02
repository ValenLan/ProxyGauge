#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
BACKEND="$SCRIPT_DIR/proxygauge-backend.sh"
TEMP_DIR=$(/usr/bin/mktemp -d /tmp/proxygauge-backend-test.XXXXXX)
cleanup() {
  /bin/rm -rf "$TEMP_DIR"
}
trap cleanup EXIT
if [ "$(/usr/bin/grep -Fc '/usr/bin/curl --disable ' "$BACKEND")" -ne \
  "$(/usr/bin/grep -Fc '/usr/bin/curl ' "$BACKEND")" ]; then
  echo 'Every backend curl call must ignore user curl configuration.' >&2
  exit 1
fi
/usr/bin/grep -Fq 'socket_owned_by_mihomo "$socket_path" || return 1' "$BACKEND"
if [ "$(/usr/bin/grep -Fc 'socket_owned_by_mihomo "$socket_path" || return 1' "$BACKEND")" -ne 2 ]; then
  echo 'Both controller reads must verify that the Unix socket belongs to a detected Mihomo PID.' >&2
  exit 1
fi
TEST_PF_CONF="$TEMP_DIR/pf.conf"
/usr/bin/printf '%s\n' 'anchor "proxygauge"' > "$TEST_PF_CONF"
export PROXYGAUGE_PF_CONF="$TEST_PF_CONF"
export PROXYGAUGE_KILL_STATE="$TEMP_DIR/missing-state"

RUNTIME_STATE="$TEMP_DIR/runtime-state"
/usr/bin/printf '%s\n' enabled > "$RUNTIME_STATE"
/bin/chmod 644 "$RUNTIME_STATE"
/usr/bin/printf '%s\n' test-token > "$TEMP_DIR/runtime-token"
trusted_enabled=$(PROXYGAUGE_KILL_STATE="$RUNTIME_STATE" \
  PROXYGAUGE_KILL_TOKEN="$TEMP_DIR/runtime-token" \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "kill" { print $2 "\t" $3 }')
[ "$trusted_enabled" = $'已开启\tok' ]

/usr/bin/printf '%s\n' fault > "$RUNTIME_STATE"
trusted_fault=$(PROXYGAUGE_KILL_STATE="$RUNTIME_STATE" \
  PROXYGAUGE_KILL_TOKEN="$TEMP_DIR/runtime-token" \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "kill" { print $2 "\t" $3 }')
[ "$trusted_fault" = $'需要修复\terror' ]

unconfigured_kill=$(PROXYGAUGE_PF_CONF="$TEMP_DIR/missing-pf.conf" \
  PROXYGAUGE_KILL_TOKEN="$TEMP_DIR/missing-token" \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "kill" { print $2 "\t" $3 }')
[ "$unconfigured_kill" = $'未配置\tidle' ]

configured_off_kill=$(PROXYGAUGE_KILL_TOKEN="$TEMP_DIR/missing-token" \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "kill" { print $2 "\t" $3 }')
[ "$configured_off_kill" = $'已关闭\twarning' ]

assert_entry_state() {
  local system_active tun_active expected actual
  system_active="$1"
  tun_active="$2"
  expected="$3"

  actual=$(PROXYGAUGE_SYSTEM_PROXY_ACTIVE="$system_active" \
    PROXYGAUGE_TUN_ACTIVE="$tun_active" \
    PROXYGAUGE_TUN_KIND=mihomo \
    PROXYGAUGE_KILL_TOKEN="$TEMP_DIR/missing-token" \
    /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "entry" { print $2 "\t" $3 "\t" $4 "\t" $5 }')

  if [ "$actual" != "$expected" ]; then
    echo "入口状态解析失败: system=$system_active tun=$tun_active => $actual (期望 $expected)" >&2
    exit 1
  fi
}

assert_entry_state 1 0 $'已启用\tok\t系统代理\tarrow.left.arrow.right'
assert_entry_state 0 1 $'代表性路由已确认\tok\tTUN 路由\tarrow.triangle.2.circlepath'
assert_entry_state 1 1 $'同时开启\twarning\t双重入口\texclamationmark.triangle.fill'
assert_entry_state 0 0 $'未启用\tidle\t流量入口\tarrow.triangle.branch'

dynamic_dual_entry=$(PROXYGAUGE_SYSTEM_PROXY_ACTIVE=1 \
  PROXYGAUGE_SYSTEM_PROXY_DYNAMIC=1 \
  PROXYGAUGE_TUN_KIND=mihomo \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "entry" { print $2 "\t" $3 "\t" $4 }')
[ "$dynamic_dual_entry" = $'按目标决定\twarning\tPAC / 自动代理 + Mihomo TUN' ]

mismatched_dual_entry=$(PROXYGAUGE_SYSTEM_PROXY_ACTIVE=1 \
  PROXYGAUGE_SYSTEM_PROXY_DYNAMIC=0 \
  PROXYGAUGE_SYSTEM_PROXY_HTTPS=1 \
  PROXYGAUGE_SYSTEM_PROXY_BYPASS=0 \
  PROXYGAUGE_SYSTEM_PROXY_MATCHES=0 \
  PROXYGAUGE_TUN_KIND=mihomo \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "entry" { print $2 "\t" $3 "\t" $4 }')
[ "$mismatched_dual_entry" = $'入口不匹配\twarning\t系统代理路径 + Mihomo TUN' ]

dynamic_dual_mode=$(PROXYGAUGE_SYSTEM_PROXY_ACTIVE=1 \
  PROXYGAUGE_SYSTEM_PROXY_DYNAMIC=1 \
  PROXYGAUGE_TUN_KIND=mihomo \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=0 \
  /bin/bash "$BACKEND" discover | /usr/bin/awk -F '\t' '$1 == "mode" { print $2 }')
[ "$dynamic_dual_mode" = 'PAC / 自动代理 + Mihomo TUN' ]

other_tunnel_entry=$(PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_ACTIVE=1 \
  PROXYGAUGE_TUN_KIND=other \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "entry" { print $2 "\t" $3 "\t" $4 }')
[ "$other_tunnel_entry" = $'已检测\twarning\t其他 VPN / TUN' ]

other_tunnel_without_mihomo=$(PROXYGAUGE_CORE_PIDS='' \
  PROXYGAUGE_MIXED=127.0.0.1:9 \
  PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_ACTIVE=1 \
  PROXYGAUGE_TUN_KIND=other \
  /bin/bash "$BACKEND" probe)
[ "$(/usr/bin/awk -F '\t' '$1 == "overall" { print $2 }' <<< "$other_tunnel_without_mihomo")" = warning ]
[ "$(/usr/bin/awk -F '\t' '$1 == "headline" { print $2 }' <<< "$other_tunnel_without_mihomo")" = '检测到其他 VPN/TUN' ]

other_tunnel_port=53011
other_tunnel_with_mihomo=$(PROXYGAUGE_CORE_PIDS=12345 \
  PROXYGAUGE_MIXED="127.0.0.1:$other_tunnel_port" \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=1 \
  PROXYGAUGE_DISCOVERY_PORT_OWNER=other \
  PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_ACTIVE=1 \
  PROXYGAUGE_TUN_KIND=other \
  /bin/bash "$BACKEND" probe)
[ "$(/usr/bin/awk -F '\t' '$1 == "overall" { print $2 }' <<< "$other_tunnel_with_mihomo")" = warning ]
[ "$(/usr/bin/awk -F '\t' '$1 == "headline" { print $2 }' <<< "$other_tunnel_with_mihomo")" = '检测到其他 VPN/TUN' ]
[ "$(/usr/bin/awk -F '\t' '$1 == "port" { print $2 "\t" $3 }' <<< "$other_tunnel_with_mihomo")" = "${other_tunnel_port}"$' 监听器未确认\twarning' ]
/usr/bin/grep -Fq '不能归因于 Mihomo' <<< "$other_tunnel_with_mihomo"
if /usr/bin/grep -Fq '系统代理未明确指向' <<< "$other_tunnel_with_mihomo"; then
  echo 'A generic VPN route must not be described as a system proxy mismatch.' >&2
  exit 1
fi

system_and_other_tunnel_entry=$(PROXYGAUGE_SYSTEM_PROXY_ACTIVE=1 \
  PROXYGAUGE_TUN_ACTIVE=1 \
  PROXYGAUGE_TUN_KIND=other \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "entry" { print $2 "\t" $3 "\t" $4 }')
[ "$system_and_other_tunnel_entry" = $'同时检测\twarning\t系统代理 + 其他 VPN / TUN' ]

system_and_other_tunnel_mode=$(PROXYGAUGE_SYSTEM_PROXY_ACTIVE=1 \
  PROXYGAUGE_TUN_ACTIVE=1 \
  PROXYGAUGE_TUN_KIND=other \
  PROXYGAUGE_DISCOVERY_PORT_OPEN=0 \
  /bin/bash "$BACKEND" discover | /usr/bin/awk -F '\t' '$1 == "mode" { print $2 }')
[ "$system_and_other_tunnel_mode" = '系统代理 + 其他 VPN / TUN' ]

generic_route_entry=$(PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_ROUTE_TABLE=$'default            10.0.0.1           UGScg                 utun7' \
  PROXYGAUGE_DISCOVERY_SOCKET="$TEMP_DIR/missing.sock" \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "entry" { print $2 "\t" $3 "\t" $4 }')
[ "$generic_route_entry" = $'已检测\twarning\t其他 VPN / TUN' ]

legacy_vpn_route_entry=$(PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_ROUTE_TABLE=$'default            10.0.0.1           UGScg                 ppp0' \
  PROXYGAUGE_DISCOVERY_SOCKET="$TEMP_DIR/missing.sock" \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "entry" { print $2 "\t" $3 "\t" $4 }')
[ "$legacy_vpn_route_entry" = $'已检测\twarning\t其他 VPN / TUN' ]

TUN_CONFIG_WITHOUT_DEVICE="$TEMP_DIR/tun-config-without-device.json"
/usr/bin/printf '%s\n' '{"tun":{"enable":true}}' > "$TUN_CONFIG_WITHOUT_DEVICE"
ROUTES_UTUN7_V4=$'inet 1.1.1.1 utun7\ninet 8.8.8.8 utun7\ninet 9.9.9.9 utun7\ninet 208.67.222.222 utun7\ninet6 2606:4700:4700::1111 unavailable\ninet6 2001:4860:4860::8888 unavailable\ninet6 2620:fe::fe unavailable\ninet6 2620:119:35::35 unavailable'
ROUTES_PHYSICAL_V4=${ROUTES_UTUN7_V4//utun7/en0}
enabled_config_generic_route=$(PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_ROUTE_TABLE=$'default            10.0.0.1           UGScg                 utun7' \
  PROXYGAUGE_DISCOVERY_SOCKET_JSON="$TUN_CONFIG_WITHOUT_DEVICE" \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "entry" { print $2 "\t" $3 "\t" $4 }')
[ "$enabled_config_generic_route" = $'路由待确认\twarning\tMihomo TUN' ]

enabled_config_fake_ip_route=$(PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_ROUTE_TABLE=$'198.18/15          link#24            UCS                   utun7' \
  PROXYGAUGE_DISCOVERY_SOCKET_JSON="$TUN_CONFIG_WITHOUT_DEVICE" \
  PROXYGAUGE_ROUTE_LOOKUP_RESULTS="$ROUTES_PHYSICAL_V4" \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "entry" { print $2 "\t" $3 "\t" $4 }')
[ "$enabled_config_fake_ip_route" = $'代表性路由不一致\twarning\tMihomo TUN' ]

confirmed_fake_ip_route=$(PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_ROUTE_TABLE=$'198.18/15          link#24            UCS                   utun7' \
  PROXYGAUGE_DISCOVERY_SOCKET_JSON="$TUN_CONFIG_WITHOUT_DEVICE" \
  PROXYGAUGE_ROUTE_LOOKUP_RESULTS="$ROUTES_UTUN7_V4" \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "entry" { print $2 "\t" $3 "\t" $4 }')
[ "$confirmed_fake_ip_route" = $'代表性路由已确认\tok\tTUN 路由' ]

matched_mihomo_route_entry=$(PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_ROUTE_TABLE=$'default            10.0.0.1           UGScg                 utun7' \
  PROXYGAUGE_MIHOMO_TUN_ACTIVE=1 \
  PROXYGAUGE_MIHOMO_TUN_DEVICE=utun7 \
  PROXYGAUGE_ROUTE_LOOKUP_RESULTS="$ROUTES_UTUN7_V4" \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "entry" { print $2 "\t" $3 "\t" $4 }')
[ "$matched_mihomo_route_entry" = $'代表性路由已确认\tok\tTUN 路由' ]

mismatched_mihomo_route_entry=$(PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_ROUTE_TABLE=$'default            10.0.0.1           UGScg                 utun7' \
  PROXYGAUGE_MIHOMO_TUN_ACTIVE=1 \
  PROXYGAUGE_MIHOMO_TUN_DEVICE=utun8 \
  PROXYGAUGE_ROUTE_LOOKUP_RESULTS="$ROUTES_UTUN7_V4" \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "entry" { print $2 "\t" $3 "\t" $4 }')
[ "$mismatched_mihomo_route_entry" = $'代表性路由不一致\twarning\tMihomo TUN' ]

mismatched_mihomo_fake_ip_entry=$(PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_ROUTE_TABLE=$'198.18/15          link#24            UCS                   utun7' \
  PROXYGAUGE_MIHOMO_TUN_ACTIVE=1 \
  PROXYGAUGE_MIHOMO_TUN_DEVICE=utun8 \
  PROXYGAUGE_ROUTE_LOOKUP_RESULTS="$ROUTES_UTUN7_V4" \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "entry" { print $2 "\t" $3 "\t" $4 }')
[ "$mismatched_mihomo_fake_ip_entry" = $'代表性路由不一致\twarning\tMihomo TUN' ]

same_family_split_routes=${ROUTES_UTUN7_V4/inet 8.8.8.8 utun7/inet 8.8.8.8 en0}
same_family_split_entry=$(PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_ROUTE_TABLE=$'198.18/15 link#24 UCS utun7' \
  PROXYGAUGE_MIHOMO_TUN_ACTIVE=1 \
  PROXYGAUGE_MIHOMO_TUN_DEVICE=utun7 \
  PROXYGAUGE_ROUTE_LOOKUP_RESULTS="$same_family_split_routes" \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "entry" { print $2 "\t" $3 "\t" $4 }')
[ "$same_family_split_entry" = $'代表性路由不一致\twarning\tMihomo TUN' ]

dual_family_split_routes=$'inet 1.1.1.1 utun7\ninet 8.8.8.8 utun7\ninet 9.9.9.9 utun7\ninet 208.67.222.222 utun7\ninet6 2606:4700:4700::1111 utun8\ninet6 2001:4860:4860::8888 utun8\ninet6 2620:fe::fe utun8\ninet6 2620:119:35::35 utun8'
dual_family_split_entry=$(PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_ROUTE_TABLE=$'198.18/15 link#24 UCS utun7\ndefault fe80::1 UGSc utun8' \
  PROXYGAUGE_MIHOMO_TUN_ACTIVE=1 \
  PROXYGAUGE_MIHOMO_TUN_DEVICE=utun7 \
  PROXYGAUGE_ROUTE_LOOKUP_RESULTS="$dual_family_split_routes" \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "entry" { print $2 "\t" $3 "\t" $4 }')
[ "$dual_family_split_entry" = $'代表性路由不一致\twarning\tMihomo TUN' ]

unknown_route_results=${ROUTES_UTUN7_V4/inet 9.9.9.9 utun7/inet 9.9.9.9 unknown}
unknown_route_entry=$(PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_ROUTE_TABLE=$'198.18/15 link#24 UCS utun7' \
  PROXYGAUGE_MIHOMO_TUN_ACTIVE=1 \
  PROXYGAUGE_MIHOMO_TUN_DEVICE=utun7 \
  PROXYGAUGE_ROUTE_LOOKUP_RESULTS="$unknown_route_results" \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "entry" { print $2 "\t" $3 "\t" $4 }')
[ "$unknown_route_entry" = $'路由查询失败\twarning\tMihomo TUN' ]

tun_only_probe=$(PROXYGAUGE_CORE_PIDS=41001 \
  PROXYGAUGE_MIXED=127.0.0.1:53010 \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=0 \
  PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_ROUTE_TABLE=$'198.18/15 link#24 UCS utun7' \
  PROXYGAUGE_MIHOMO_TUN_ACTIVE=1 \
  PROXYGAUGE_MIHOMO_TUN_DEVICE=utun7 \
  PROXYGAUGE_ROUTE_LOOKUP_RESULTS="$ROUTES_UTUN7_V4" \
  /bin/bash "$BACKEND" probe)
[ "$(/usr/bin/awk -F '\t' '$1 == "overall" { print $2 }' <<< "$tun_only_probe")" = ok ]
[ "$(/usr/bin/awk -F '\t' '$1 == "port" { print $2 "\t" $3 }' <<< "$tun_only_probe")" = $'53010 非当前入口\tidle' ]

mismatched_entry=$(PROXYGAUGE_SYSTEM_PROXY_ACTIVE=1 \
  PROXYGAUGE_SYSTEM_PROXY_MATCHES=0 \
  PROXYGAUGE_SYSTEM_PROXY_DYNAMIC=0 \
  PROXYGAUGE_TUN_ACTIVE=0 \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "entry" { print $2 "\t" $3 "\t" $4 }')
[ "$mismatched_entry" = $'入口不匹配\twarning\t系统代理' ]

dynamic_entry=$(PROXYGAUGE_SYSTEM_PROXY_ACTIVE=1 \
  PROXYGAUGE_SYSTEM_PROXY_DYNAMIC=1 \
  PROXYGAUGE_TUN_ACTIVE=0 \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "entry" { print $2 "\t" $3 "\t" $4 }')
[ "$dynamic_entry" = $'按目标决定\twarning\tPAC / 自动代理' ]

http_only_entry=$(PROXYGAUGE_SYSTEM_PROXY_ACTIVE=1 \
  PROXYGAUGE_SYSTEM_PROXY_DYNAMIC=0 \
  PROXYGAUGE_SYSTEM_PROXY_HTTPS=0 \
  PROXYGAUGE_TUN_ACTIVE=0 \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "entry" { print $2 "\t" $3 "\t" $4 }')
[ "$http_only_entry" = $'HTTPS 未接管\twarning\t系统代理' ]

bypass_entry=$(PROXYGAUGE_SYSTEM_PROXY_ACTIVE=1 \
  PROXYGAUGE_SYSTEM_PROXY_DYNAMIC=0 \
  PROXYGAUGE_SYSTEM_PROXY_HTTPS=1 \
  PROXYGAUGE_SYSTEM_PROXY_BYPASS=1 \
  PROXYGAUGE_TUN_ACTIVE=0 \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "entry" { print $2 "\t" $3 "\t" $4 }')
[ "$bypass_entry" = $'出口域名被绕过\twarning\t系统代理' ]

wildcard_proxy_state=$'<dictionary> {\n  HTTPSEnable : 1\n  HTTPSProxy : 127.0.0.1\n  HTTPSPort : 7890\n  ExceptionsList : <array> {\n    0 : *ipify*\n  }\n}'
wildcard_bypass_entry=$(PROXYGAUGE_SYSTEM_PROXY_STATE="$wildcard_proxy_state" \
  PROXYGAUGE_TUN_ACTIVE=0 \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "entry" { print $2 "\t" $3 "\t" $4 }')
[ "$wildcard_bypass_entry" = $'出口域名被绕过\twarning\t系统代理' ]

scoped_only_proxy_state=$'<dictionary> {\n  HTTPEnable : 0\n  HTTPSEnable : 0\n  __SCOPED__ : <dictionary> {\n    en0 : <dictionary> {\n      HTTPSEnable : 1\n      HTTPSProxy : 127.0.0.1\n      HTTPSPort : 7890\n    }\n  }\n}'
scoped_only_entry=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_SYSTEM_PROXY_STATE="$scoped_only_proxy_state" \
  PROXYGAUGE_TUN_ACTIVE=0 \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "entry" { print $2 "\t" $3 "\t" $4 }')
[ "$scoped_only_entry" = $'未启用\tidle\t流量入口' ]

listener_mismatch=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CORE_PIDS=41001 \
  PROXYGAUGE_MIXED=127.0.0.1:53012 \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=1 \
  PROXYGAUGE_DISCOVERY_LISTENER_RECORDS=$'p41001\nn127.0.0.2:53012' \
  PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_KIND=none \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "port" { print $2 "\t" $3 }')
[ "$listener_mismatch" = $'53012 监听器未确认\twarning' ]

listener_exact=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CORE_PIDS=41001 \
  PROXYGAUGE_MIXED=127.0.0.1:53012 \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=1 \
  PROXYGAUGE_DISCOVERY_LISTENER_RECORDS=$'p41001\nn127.0.0.1:53012' \
  PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_KIND=none \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "port" { print $2 "\t" $3 }')
[ "$listener_exact" = $'53012 监听中\tok' ]

listener_v4_wildcard=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CORE_PIDS=41001 \
  PROXYGAUGE_MIXED=127.0.0.1:53012 \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=1 \
  PROXYGAUGE_DISCOVERY_LISTENER_RECORDS=$'p41001\nn0.0.0.0:53012' \
  PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_KIND=none \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "port" { print $2 "\t" $3 }')
[ "$listener_v4_wildcard" = $'53012 监听中\tok' ]

listener_wrong_family=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CORE_PIDS=41001 \
  PROXYGAUGE_MIXED='[::1]:53012' \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=1 \
  PROXYGAUGE_DISCOVERY_LISTENER_RECORDS=$'p41001\nn0.0.0.0:53012' \
  PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_KIND=none \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "port" { print $2 "\t" $3 }')
[ "$listener_wrong_family" = $'53012 监听器未确认\twarning' ]

fingerprint_open=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CORE_PIDS=41001 \
  PROXYGAUGE_MIXED=127.0.0.1:53012 \
  PROXYGAUGE_DISCOVERY_LISTENER_RECORDS=$'p41001\nn127.0.0.1:53012' \
  PROXYGAUGE_TUN_ROUTE_TABLE='default 192.0.2.1 UGSc en0' \
  /bin/bash "$BACKEND" fingerprint)
fingerprint_closed=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CORE_PIDS=41001 \
  PROXYGAUGE_MIXED=127.0.0.1:53012 \
  PROXYGAUGE_DISCOVERY_LISTENER_RECORDS='' \
  PROXYGAUGE_TUN_ROUTE_TABLE='default 192.0.2.1 UGSc en0' \
  /bin/bash "$BACKEND" fingerprint)
[ "$fingerprint_open" != "$fingerprint_closed" ]
/usr/bin/grep -Fq 'core=41001;listener=41001' <<< "$fingerprint_open"

single_mihomo_core=$(PROXYGAUGE_CORE_PIDS=41001 \
  PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_ACTIVE=0 \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "core" { print $2 "\t" $3 }')
[ "$single_mihomo_core" = $'运行中\tok' ]

duplicate_mihomo_cores=$(PROXYGAUGE_CORE_PIDS=$'41001\n41002' \
  PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_ACTIVE=0 \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "core" { print $2 "\t" $3 }')
[ "$duplicate_mihomo_cores" = $'2 个核心\twarning' ]

/usr/bin/printf '%s\n' \
  'mixed-port: 7897' \
  'secret: test-must-not-be-returned' > "$TEMP_DIR/clash-verge.yaml"
/usr/bin/printf '%s\n' \
  '{"mixed-port":7788,"secret":"test-must-not-be-returned"}' \
  > "$TEMP_DIR/mihomo-configs.json"
/usr/bin/printf '%s\n' 'PROXYGAUGE_MIXED="127.0.0.1:7000"' > "$TEMP_DIR/proxygauge-config"

saved_endpoint_probe=$(PROXYGAUGE_CONFIG="$TEMP_DIR/proxygauge-config" \
  PROXYGAUGE_MIXED=127.0.0.1:7898 \
  PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_ACTIVE=0 \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "port" { print $2 }')
case "$saved_endpoint_probe" in
  '7898 监听中'|'7898 未监听') ;;
  *) echo "App 保存的入口没有覆盖配置文件: $saved_endpoint_probe" >&2; exit 1 ;;
esac

for retired_action in exit-ip exit-summary; do
  if PROXYGAUGE_CONFIG=/dev/null /bin/bash "$BACKEND" "$retired_action" >/dev/null 2>&1; then
    echo "旧的固定 mixed 端口出口动作不得继续可用: $retired_action" >&2
    exit 1
  fi
done

assert_discovery() {
  local expected output
  expected="$1"
  shift
  output=$(env \
    PROXYGAUGE_CONFIG=/dev/null \
    PROXYGAUGE_DISCOVERY_SOCKET="$TEMP_DIR/missing.sock" \
    PROXYGAUGE_DISCOVERY_PORT_OWNER=mihomo \
    PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
    PROXYGAUGE_TUN_ACTIVE=0 \
    "$@" /bin/bash "$BACKEND" discover)

  /usr/bin/printf '%s\n' "$output" | /usr/bin/grep -Fq "$expected"
  if /usr/bin/printf '%s\n' "$output" | /usr/bin/grep -Fq 'test-must-not-be-returned'; then
    echo '自动检测不得输出配置中的其他字段' >&2
    exit 1
  fi
}

assert_discovery $'endpoint\t127.0.0.1:7897' \
  PROXYGAUGE_DISCOVERY_CLIENT='Clash Verge Rev' \
  PROXYGAUGE_DISCOVERY_CONFIG="$TEMP_DIR/clash-verge.yaml" \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=1

assert_discovery $'source\tMihomo 运行状态' \
  PROXYGAUGE_DISCOVERY_SOCKET_JSON="$TEMP_DIR/mihomo-configs.json" \
  PROXYGAUGE_DISCOVERY_CONFIG="$TEMP_DIR/missing.yaml" \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=1

dynamic_discovery=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_DISCOVERY_SYSTEM_PROXY=127.0.0.1:7999 \
  PROXYGAUGE_DISCOVERY_SOCKET_JSON="$TEMP_DIR/mihomo-configs.json" \
  PROXYGAUGE_DISCOVERY_CONFIG="$TEMP_DIR/missing.yaml" \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=1 \
  PROXYGAUGE_DISCOVERY_PORT_OWNER=mihomo \
  PROXYGAUGE_SYSTEM_PROXY_ACTIVE=1 \
  PROXYGAUGE_SYSTEM_PROXY_DYNAMIC=1 \
  PROXYGAUGE_TUN_ACTIVE=0 \
  /bin/bash "$BACKEND" discover)
/usr/bin/printf '%s\n' "$dynamic_discovery" | /usr/bin/grep -Fq $'endpoint\t127.0.0.1:7788'
/usr/bin/printf '%s\n' "$dynamic_discovery" | /usr/bin/grep -Fq $'mode\tPAC / 自动代理'

system_discovery=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_DISCOVERY_SYSTEM_PROXY=127.0.0.1:7891 \
  PROXYGAUGE_DISCOVERY_CONFIG="$TEMP_DIR/missing.yaml" \
  PROXYGAUGE_DISCOVERY_SOCKET="$TEMP_DIR/missing.sock" \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=1 \
  PROXYGAUGE_DISCOVERY_PORT_OWNER=mihomo \
  PROXYGAUGE_SYSTEM_PROXY_ACTIVE=1 \
  PROXYGAUGE_TUN_ACTIVE=0 \
  /bin/bash "$BACKEND" discover)
/usr/bin/printf '%s\n' "$system_discovery" | /usr/bin/grep -Fq $'source\tmacOS 系统代理'
/usr/bin/printf '%s\n' "$system_discovery" | /usr/bin/grep -Fq $'mode\t系统代理'

assert_discovery $'endpoint\t127.42.0.9:7891' \
  PROXYGAUGE_DISCOVERY_SYSTEM_PROXY=127.42.0.9:7891 \
  PROXYGAUGE_DISCOVERY_CONFIG="$TEMP_DIR/missing.yaml" \
  PROXYGAUGE_SYSTEM_PROXY_ACTIVE=1 \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=1

assert_discovery $'endpoint\t[::1]:7891' \
  PROXYGAUGE_DISCOVERY_SYSTEM_PROXY='[::1]:7891' \
  PROXYGAUGE_DISCOVERY_CONFIG="$TEMP_DIR/missing.yaml" \
  PROXYGAUGE_SYSTEM_PROXY_ACTIVE=1 \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=1

assert_discovery $'endpoint\t[::1]:7891' \
  PROXYGAUGE_DISCOVERY_SYSTEM_PROXY='0:0:0:0:0:0:0:1:7891' \
  PROXYGAUGE_DISCOVERY_CONFIG="$TEMP_DIR/missing.yaml" \
  PROXYGAUGE_SYSTEM_PROXY_ACTIVE=1 \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=1

missing_discovery=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_DISCOVERY_CONFIG="$TEMP_DIR/missing.yaml" \
  PROXYGAUGE_DISCOVERY_SOCKET="$TEMP_DIR/missing.sock" \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=0 \
  PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_ACTIVE=0 \
  /bin/bash "$BACKEND" discover)
/usr/bin/printf '%s\n' "$missing_discovery" | /usr/bin/grep -Fq $'found\t0'
/usr/bin/printf '%s\n' "$missing_discovery" | /usr/bin/grep -Fq $'source\t手动设置'

unowned_common_port=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_DISCOVERY_CONFIG="$TEMP_DIR/missing.yaml" \
  PROXYGAUGE_DISCOVERY_SOCKET="$TEMP_DIR/missing.sock" \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=1 \
  PROXYGAUGE_DISCOVERY_PORT_OWNER=other \
  PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_ACTIVE=0 \
  /bin/bash "$BACKEND" discover)
/usr/bin/printf '%s\n' "$unowned_common_port" | /usr/bin/grep -Fq $'found\t0'

for retired_admin_action in kill-status kill-on kill-off kill-pause; do
  if /bin/bash "$BACKEND" "$retired_admin_action" >/dev/null 2>&1; then
    echo "后端脚本不得保留管理员执行入口: $retired_admin_action" >&2
    exit 1
  fi
done

MALICIOUS_MARKER="$TEMP_DIR/config-code-executed"
/usr/bin/printf '%s\n' \
  'PROXYGAUGE_MIXED="127.0.0.1:7001"' \
  'KILL_HELPER="/tmp/evil-helper"' \
  'PROXYGAUGE_OSASCRIPT="/tmp/evil-osascript"' \
  'PROXYGAUGE_KILL_TOKEN="/tmp/evil-token"' \
  "PROXYGAUGE_SECONDARY_LABEL=\$(/usr/bin/touch '$MALICIOUS_MARKER')" \
  'readonly PROXYGAUGE_MIXED="127.0.0.1:1"' \
  'trap "touch /tmp/proxygauge-debug-trap" DEBUG' \
  > "$TEMP_DIR/malicious-config"
/bin/chmod 600 "$TEMP_DIR/malicious-config"
safe_config_port=$(PROXYGAUGE_CONFIG="$TEMP_DIR/malicious-config" \
  PROXYGAUGE_SYSTEM_PROXY_ACTIVE=0 \
  PROXYGAUGE_TUN_ACTIVE=0 \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "port" { print $2 }')
case "$safe_config_port" in
  '7001 监听中'|'7001 未监听'|'7001 监听器未确认') ;;
  *) echo "安全配置解析没有保留受支持入口: $safe_config_port" >&2; exit 1 ;;
esac
[ ! -e "$MALICIOUS_MARKER" ]
[ ! -e /tmp/proxygauge-debug-trap ]

CONFIG_COMPAT_DIR="$TEMP_DIR/config-compat"
/bin/mkdir -p "$CONFIG_COMPAT_DIR"
/bin/cp "$BACKEND" "$CONFIG_COMPAT_DIR/proxygauge-backend.sh"
/usr/bin/printf '%s\n' \
  '#!/bin/bash' \
  '/usr/bin/printf "%s|%s|%s|%s|%s\\n" "$PROXYGAUGE_TIMEOUT" "$PROXYGAUGE_EXPECT_IP" "$PROXYGAUGE_MIHOMO_SOCKET" "$PROXYGAUGE_EXPECT_SECONDARY_IP" "$PROXYGAUGE_ACTIVE_AI_PROBES"' \
  > "$CONFIG_COMPAT_DIR/proxygauge-check.sh"
/bin/chmod 755 "$CONFIG_COMPAT_DIR/proxygauge-check.sh"
/usr/bin/printf '%s\n' \
  'PROXYGAUGE_TIMEOUT=17' \
  'PROXYGAUGE_EXPECT_IP=8.8.8.8' \
  "PROXYGAUGE_MIHOMO_SOCKET=$TEMP_DIR/controller.sock" \
  'PROXYGAUGE_EXPECT_SECONDARY_IP=1.1.1.1' \
  'PROXYGAUGE_ACTIVE_AI_PROBES=1' \
  > "$TEMP_DIR/compat-config"
/bin/chmod 600 "$TEMP_DIR/compat-config"
config_compat=$(/usr/bin/env -u PROXYGAUGE_TIMEOUT -u PROXYGAUGE_EXPECT_IP \
  -u PROXYGAUGE_MIHOMO_SOCKET -u PROXYGAUGE_EXPECT_SECONDARY_IP \
  -u PROXYGAUGE_ACTIVE_AI_PROBES PROXYGAUGE_CONFIG="$TEMP_DIR/compat-config" \
  /bin/bash "$CONFIG_COMPAT_DIR/proxygauge-backend.sh" health)
[ "$config_compat" = "17|8.8.8.8|$TEMP_DIR/controller.sock|1.1.1.1|1" ]

socket_override=$(/usr/bin/env PROXYGAUGE_CONFIG="$TEMP_DIR/compat-config" \
  PROXYGAUGE_TIMEOUT=9 \
  PROXYGAUGE_MIHOMO_SOCKET="$TEMP_DIR/environment.sock" \
  PROXYGAUGE_ACTIVE_AI_PROBES=0 \
  /bin/bash "$CONFIG_COMPAT_DIR/proxygauge-backend.sh" health)
[ "$socket_override" = "9|8.8.8.8|$TEMP_DIR/environment.sock|1.1.1.1|0" ]

fingerprint_expire_30=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CORE_PIDS='' \
  PROXYGAUGE_DISCOVERY_LISTENER_RECORDS='' \
  PROXYGAUGE_TUN_ROUTE_TABLE=$'Routing tables\nInternet:\ndefault 10.0.0.1 UGScg en0\n198.18/15 utun4 USc 30' \
  /bin/bash "$BACKEND" fingerprint)
fingerprint_expire_29=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CORE_PIDS='' \
  PROXYGAUGE_DISCOVERY_LISTENER_RECORDS='' \
  PROXYGAUGE_TUN_ROUTE_TABLE=$'Routing tables\nInternet:\ndefault 10.0.0.1 UGScg en0\n198.18/15 utun4 USc 29' \
  /bin/bash "$BACKEND" fingerprint)
[ "$fingerprint_expire_30" = "$fingerprint_expire_29" ] || {
  echo '路由有效期倒计时不得触发本地状态变化。' >&2
  exit 1
}
fingerprint_other_utun=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CORE_PIDS='' \
  PROXYGAUGE_DISCOVERY_LISTENER_RECORDS='' \
  PROXYGAUGE_TUN_ROUTE_TABLE=$'Routing tables\nInternet:\ndefault 10.0.0.1 UGScg en0\n198.18/15 utun5 USc 29' \
  /bin/bash "$BACKEND" fingerprint)
[ "$fingerprint_expire_29" != "$fingerprint_other_utun" ] || {
  echo 'utun 路由身份变化必须更新本地状态指纹。' >&2
  exit 1
}
fingerprint_ppp=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CORE_PIDS='' \
  PROXYGAUGE_DISCOVERY_LISTENER_RECORDS='' \
  PROXYGAUGE_TUN_ROUTE_TABLE=$'Routing tables\nInternet:\ndefault 10.0.0.1 UGScg ppp0' \
  /bin/bash "$BACKEND" fingerprint)
[ "$fingerprint_ppp" != "$fingerprint_other_utun" ] || {
  echo '非 utun VPN 路由变化必须更新本地状态指纹。' >&2
  exit 1
}

echo 'ProxyGauge backend state parsing tests passed.'
