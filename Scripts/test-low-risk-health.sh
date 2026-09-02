#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
CHECK="$PROJECT_ROOT/Scripts/proxygauge-check.sh"
APP_SOURCE="$PROJECT_ROOT/Sources/ProxyGaugeApp.swift"
WINDOWS_MODEL="$PROJECT_ROOT/Windows/Models/HealthReport.cs"
WINDOWS_SERVICE="$PROJECT_ROOT/Windows/Services/HealthCheckService.cs"
WINDOWS_MAIN="$PROJECT_ROOT/Windows/MainWindow.xaml"
TEMP_ROOT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/proxygauge-health-ip-test.XXXXXX")
cleanup() {
  /bin/rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

/usr/bin/grep -Fq 'ACTIVE_AI_PROBES="${PROXYGAUGE_ACTIVE_AI_PROBES:-0}"' "$CHECK"
/usr/bin/grep -Fq 'GEMINI_PROBE_PROXY="$MIXED_PROXY_ENDPOINT"' "$CHECK"
/usr/bin/grep -Fq 'GEMINI_PROBE_PROXY="$GOOGLE_PROXY_ENDPOINT"' "$CHECK"
/usr/bin/grep -q 'url=https://cp.cloudflare.com/generate_204' "$CHECK"
/usr/bin/grep -Fq '"$DSCACHEUTIL" -q host -a name www.cloudflare.com' "$CHECK"
/usr/bin/grep -Fq 'SECONDARY_ENABLED="${PROXYGAUGE_SECONDARY_ENABLED:-auto}"' "$CHECK"
/usr/bin/grep -Fq 'run_secondary_checks() {' "$CHECK"
/usr/bin/grep -Fq '===== 5. 主动平台探测 (手动启用) =====' "$CHECK"
/usr/bin/grep -Fq '===== 6. 分流确认 (不访问账号站点) =====' "$CHECK"
/usr/bin/grep -Fq '===== 7. 出口结论 (不新增外部请求) =====' "$CHECK"
/usr/bin/grep -Fq '系统代理与 TUN 同时开启 — 通常只需保留一个流量入口' "$CHECK"
/usr/bin/grep -Fq 'ENCODED_GOOGLE_GROUP=$(encode_path_segment "$GOOGLE_GROUP")' "$CHECK"
/usr/bin/grep -Fq 'http://localhost/proxies/$ENCODED_GOOGLE_GROUP/delay' "$CHECK"
/usr/bin/grep -Fq -- '--max-filesize 256' "$CHECK"
/usr/bin/grep -Fq -- '--max-filesize 4194304' "$CHECK"

if /usr/bin/grep -q '社区深度复核\|Claude 登录会话验证\|ChatGPT 登录会话验证' "$CHECK"; then
  echo "Manual browser and account checks must stay outside the routine health report." >&2
  exit 1
fi

if /usr/bin/grep -q 'check_site "\(ChatGPT\|Claude\) ' "$CHECK"; then
  echo "Account-facing web probes must not run from the health check." >&2
  exit 1
fi

if /usr/bin/grep -q 'www.google.com/generate_204' "$CHECK"; then
  echo "AI-safe mode must not use a Google connectivity endpoint." >&2
  exit 1
fi

if /usr/bin/grep -Eqi 'ipapi\.is|proxycheck\.io|peeringdb' "$CHECK" "$WINDOWS_SERVICE"; then
  echo "Routine link checks must not submit exit IPs to reputation services." >&2
  exit 1
fi

if /usr/bin/grep -Fq 'check no "尚未确认 Gemini 的独立出口 IP"' "$CHECK"; then
  echo "Optional chain diagnostics must not fail an otherwise healthy default route." >&2
  exit 1
fi

score_weights=$(/usr/bin/awk '
  /private static let standardWeights:/ {mode="standard"; next}
  /private static let extendedWeights:/ {mode="extended"; next}
  mode != "" && /^    ]/ {print mode "=" sum; mode=""; sum=0; next}
  mode != "" && /"[1-8]":/ {gsub(/,/, "", $2); sum += $2}
' "$APP_SOURCE")
/usr/bin/grep -Fq 'standard=100' <<< "$score_weights"
/usr/bin/grep -Fq 'extended=100' <<< "$score_weights"
/usr/bin/grep -Fq 'value = min(value, 49)' "$APP_SOURCE"
/usr/bin/grep -Fq 'sectionWeights[$0.number] != nil && $0.hasFailure' "$APP_SOURCE"
/usr/bin/grep -Fq 'Label("\(report.planName) · IP 纯净度复核不计分"' "$APP_SOURCE"
/usr/bin/grep -Fq '.progressViewStyle(.linear)' "$APP_SOURCE"

/usr/bin/grep -Fq 'new HealthCheckSection("本地代理", localItems, 45, IsCritical: true)' "$WINDOWS_SERVICE"
/usr/bin/grep -Fq 'new HealthCheckSection("代理出口", [exitResult.Item], 45, IsCritical: true)' "$WINDOWS_SERVICE"
/usr/bin/grep -Fq 'new HealthCheckSection($"{config.SecondaryLabel} · 策略与规则", planItems, 20, IsCritical: true)' "$WINDOWS_SERVICE"
/usr/bin/grep -Fq 'CreateBoundarySection(10)' "$WINDOWS_SERVICE"
/usr/bin/grep -Fq 'new("检测边界（默认低风险模式）"' "$WINDOWS_SERVICE"
/usr/bin/grep -Fq 'snapshot.Route.Level == HealthLevel.Idle' "$WINDOWS_SERVICE"
/usr/bin/grep -Fq 'value = Math.Min(value, 49)' "$WINDOWS_MODEL"
if /usr/bin/grep -Fq 'Click="HealthButton_Click"' "$WINDOWS_MAIN"; then
  echo "The redesigned dashboard must not expose the removed routine link-check action." >&2
  exit 1
fi

generic_output=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CORE_PIDS=41001 \
  PROXYGAUGE_MIXED=127.0.0.1:9 \
  PROXYGAUGE_SECONDARY_ENABLED=0 \
  PROXYGAUGE_ACTIVE_AI_PROBES=0 \
  PROXYGAUGE_TIMEOUT=1 \
  /bin/bash "$CHECK" 2>&1 || true)
/usr/bin/grep -Fq '检测方案: 通用检测' <<< "$generic_output"
/usr/bin/grep -Fq 'Mihomo 核心运行中 (PID 41001)' <<< "$generic_output"
[ "$(/usr/bin/grep -c '^===== [1-7]\.' <<< "$generic_output")" = "4" ]
if /usr/bin/grep -Fq '===== 5.' <<< "$generic_output"; then
  echo "The generic plan must not render optional placeholder sections." >&2
  exit 1
fi

extended_output=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_MIXED=127.0.0.1:9 \
  PROXYGAUGE_SECONDARY_ENABLED=1 \
  PROXYGAUGE_SECONDARY_MIXED=127.0.0.1:10 \
  PROXYGAUGE_MIHOMO_SOCKET=/private/tmp/proxygauge-missing-test.sock \
  PROXYGAUGE_ACTIVE_AI_PROBES=0 \
  PROXYGAUGE_TIMEOUT=1 \
  /bin/bash "$CHECK" 2>&1 || true)
/usr/bin/grep -Fq '检测方案: 通用检测 + Google / Gemini / Claude' <<< "$extended_output"
[ "$(/usr/bin/grep -c '^===== [1-7]\.' <<< "$extended_output")" = "7" ]

FAKE_CURL="$TEMP_ROOT/fake-curl"
/usr/bin/printf '%s\n' \
  '#!/bin/bash' \
  '[ "$1" = "--disable" ] || exit 91' \
  'case "$2" in --noproxy|--proxy) ;; *) exit 92 ;; esac' \
  '[ -z "$3" ] || exit 93' \
  'case "${PROXYGAUGE_FAKE_EXIT_KIND:-ipv6}:$*" in' \
  '  private:*) /usr/bin/printf "%s\\n" "10.0.0.1" ;;' \
  '  padded:*) /usr/bin/printf "%s\\n" "008.8.8.8" ;;' \
  '  mappedpadded:*) /usr/bin/printf "%s\\n" "::ffff:008.8.8.8" ;;' \
  '  tie:*api.ipify.org*) /usr/bin/printf "%s\\n" "8.8.8.8" ;;' \
  '  tie:*ifconfig.me*) /usr/bin/printf "%s\\n" "1.1.1.1" ;;' \
  '  tie:*ip.sb*) /usr/bin/printf "%s\\n" "9.9.9.9" ;;' \
  '  ipv6:*api.ipify.org*) /usr/bin/printf "%s\\n" "2606:4700:4700:0:0:0:0:1111" ;;' \
  '  ipv6:*ifconfig.me*) /usr/bin/printf "%s\\n" "2606:4700:4700::1111" ;;' \
  '  ipv6:*ip.sb*) /usr/bin/printf "%s\\n" "2606:4700:4700:0000:0000:0000:0000:1111" ;;' \
  '  *) exit 94 ;;' \
  'esac' > "$FAKE_CURL"
/bin/chmod 755 "$FAKE_CURL"

FAKE_DNS="$TEMP_ROOT/fake-dscacheutil"
/usr/bin/printf '%s\n' '#!/bin/bash' 'exec /bin/sleep 10' > "$FAKE_DNS"
/bin/chmod 755 "$FAKE_DNS"

unowned_listener_output=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CURL="$FAKE_CURL" \
  PROXYGAUGE_CORE_PIDS=41001 \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=1 \
  PROXYGAUGE_DISCOVERY_PORT_OWNER=other \
  PROXYGAUGE_MIXED=127.0.0.1:53011 \
  PROXYGAUGE_SECONDARY_ENABLED=0 \
  PROXYGAUGE_TUN_ACTIVE=1 \
  PROXYGAUGE_TUN_KIND=other \
  PROXYGAUGE_TIMEOUT=1 \
  /bin/bash "$CHECK" 2>&1 || true)
/usr/bin/grep -Fq '可以连接，但监听器不属于已检测的 Mihomo 核心' <<< "$unowned_listener_output"

host_mismatch_listener_output=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CURL="$FAKE_CURL" \
  PROXYGAUGE_CORE_PIDS=41001 \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=1 \
  PROXYGAUGE_DISCOVERY_LISTENER_RECORDS=$'p41001\nn127.0.0.2:53011' \
  PROXYGAUGE_MIXED=127.0.0.1:53011 \
  PROXYGAUGE_SYSTEM_PROXY_STATE=$'<dictionary> {\n  HTTPEnable : 0\n  HTTPSEnable : 0\n}' \
  PROXYGAUGE_SECONDARY_ENABLED=0 \
  PROXYGAUGE_TUN_KIND=none \
  PROXYGAUGE_TIMEOUT=1 \
  /bin/bash "$CHECK" 2>&1 || true)
/usr/bin/grep -Fq '可以连接，但监听器不属于已检测的 Mihomo 核心' <<< "$host_mismatch_listener_output"

host_exact_listener_output=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CURL="$FAKE_CURL" \
  PROXYGAUGE_CORE_PIDS=41001 \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=1 \
  PROXYGAUGE_DISCOVERY_LISTENER_RECORDS=$'p41001\nn127.0.0.1:53011' \
  PROXYGAUGE_MIXED=127.0.0.1:53011 \
  PROXYGAUGE_SYSTEM_PROXY_STATE=$'<dictionary> {\n  HTTPEnable : 0\n  HTTPSEnable : 0\n}' \
  PROXYGAUGE_SECONDARY_ENABLED=0 \
  PROXYGAUGE_TUN_KIND=none \
  PROXYGAUGE_TIMEOUT=1 \
  /bin/bash "$CHECK" 2>&1 || true)
/usr/bin/grep -Fq '监听中，且属于已检测的 Mihomo 核心' <<< "$host_exact_listener_output"

dns_start=$(/bin/date +%s)
dns_timeout_output=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CURL="$FAKE_CURL" \
  PROXYGAUGE_DSCACHEUTIL="$FAKE_DNS" \
  PROXYGAUGE_TUN_ACTIVE=1 \
  PROXYGAUGE_TUN_KIND=mihomo \
  PROXYGAUGE_SYSTEM_PROXY_STATE=$'<dictionary> {\n  HTTPEnable : 0\n  HTTPSEnable : 0\n}' \
  PROXYGAUGE_CORE_PIDS=41001 \
  PROXYGAUGE_MIXED=127.0.0.1:9 \
  PROXYGAUGE_SECONDARY_ENABLED=0 \
  PROXYGAUGE_TIMEOUT=1 \
  /bin/bash "$CHECK" 2>&1 || true)
dns_elapsed=$(( $(/bin/date +%s) - dns_start ))
[ "$dns_elapsed" -lt 5 ]
/usr/bin/grep -Fq 'TUN 代表性路由已确认，但系统 DNS 无法解析域名' <<< "$dns_timeout_output"
/usr/bin/grep -Fq '未监听；当前 TUN 系统路径不依赖 mixed 入口' <<< "$dns_timeout_output"
/usr/bin/grep -Fq '出口 IP (TUN 系统路径)' <<< "$dns_timeout_output"

other_tunnel_output=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CURL="$FAKE_CURL" \
  PROXYGAUGE_TUN_ACTIVE=1 \
  PROXYGAUGE_TUN_KIND=other \
  PROXYGAUGE_CORE_PIDS=41001 \
  PROXYGAUGE_MIXED=127.0.0.1:9 \
  PROXYGAUGE_SECONDARY_ENABLED=0 \
  PROXYGAUGE_TIMEOUT=1 \
  /bin/bash "$CHECK" 2>&1 || true)
/usr/bin/grep -Fq '检测到其他 VPN / TUN；请以系统实际出口确认当前路径' <<< "$other_tunnel_output"
if /usr/bin/grep -Fq 'TUN DNS 返回 Fake-IP' <<< "$other_tunnel_output"; then
  echo 'A generic VPN route must not be attributed to Mihomo TUN.' >&2
  exit 1
fi

generic_route_output=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CURL="$FAKE_CURL" \
  PROXYGAUGE_TUN_ROUTE_TABLE=$'default            10.0.0.1           UGScg                 utun7' \
  PROXYGAUGE_MIHOMO_SOCKET="$TEMP_ROOT/missing.sock" \
  PROXYGAUGE_CORE_PIDS=41001 \
  PROXYGAUGE_MIXED=127.0.0.1:9 \
  PROXYGAUGE_SECONDARY_ENABLED=0 \
  PROXYGAUGE_TIMEOUT=1 \
  /bin/bash "$CHECK" 2>&1 || true)
/usr/bin/grep -Fq '检测到其他 VPN / TUN；请以系统实际出口确认当前路径' <<< "$generic_route_output"

TUN_CONFIG_WITHOUT_DEVICE="$TEMP_ROOT/tun-config-without-device.json"
/usr/bin/printf '%s\n' '{"tun":{"enable":true}}' > "$TUN_CONFIG_WITHOUT_DEVICE"
ROUTES_UTUN7_V4=$'inet 1.1.1.1 utun7\ninet 8.8.8.8 utun7\ninet 9.9.9.9 utun7\ninet 208.67.222.222 utun7\ninet6 2606:4700:4700::1111 unavailable\ninet6 2001:4860:4860::8888 unavailable\ninet6 2620:fe::fe unavailable\ninet6 2620:119:35::35 unavailable'
ROUTES_PHYSICAL_V4=${ROUTES_UTUN7_V4//utun7/en0}
enabled_config_generic_route_output=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CURL="$FAKE_CURL" \
  PROXYGAUGE_TUN_ROUTE_TABLE=$'default            10.0.0.1           UGScg                 utun7' \
  PROXYGAUGE_DISCOVERY_SOCKET_JSON="$TUN_CONFIG_WITHOUT_DEVICE" \
  PROXYGAUGE_CORE_PIDS=41001 \
  PROXYGAUGE_MIXED=127.0.0.1:9 \
  PROXYGAUGE_SECONDARY_ENABLED=0 \
  PROXYGAUGE_TIMEOUT=1 \
  /bin/bash "$CHECK" 2>&1 || true)
/usr/bin/grep -Fq 'Mihomo TUN 已启用，但路由归属仍需确认；请以系统实际出口为准' <<< "$enabled_config_generic_route_output"

enabled_config_fake_ip_route_output=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CURL="$FAKE_CURL" \
  PROXYGAUGE_TUN_ROUTE_TABLE=$'198.18/15          link#24            UCS                   utun7' \
  PROXYGAUGE_DISCOVERY_SOCKET_JSON="$TUN_CONFIG_WITHOUT_DEVICE" \
  PROXYGAUGE_ROUTE_LOOKUP_RESULTS="$ROUTES_PHYSICAL_V4" \
  PROXYGAUGE_CORE_PIDS=41001 \
  PROXYGAUGE_MIXED=127.0.0.1:9 \
  PROXYGAUGE_SECONDARY_ENABLED=0 \
  PROXYGAUGE_TIMEOUT=1 \
  /bin/bash "$CHECK" 2>&1 || true)
/usr/bin/grep -Fq '代表性公网目标走不同接口，可能存在同族或 IPv4 / IPv6 分流' <<< "$enabled_config_fake_ip_route_output"
if /usr/bin/grep -Fq '代表性 IPv4 / IPv6 路由已确认' <<< "$enabled_config_fake_ip_route_output"; then
  echo 'A Fake-IP ownership hint must not prove the public route.' >&2
  exit 1
fi

confirmed_fake_ip_route_output=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CURL="$FAKE_CURL" \
  PROXYGAUGE_DSCACHEUTIL=/usr/bin/true \
  PROXYGAUGE_SYSTEM_PROXY_STATE=$'<dictionary> {\n  HTTPEnable : 0\n  HTTPSEnable : 0\n}' \
  PROXYGAUGE_TUN_ROUTE_TABLE=$'198.18/15          link#24            UCS                   utun7' \
  PROXYGAUGE_DISCOVERY_SOCKET_JSON="$TUN_CONFIG_WITHOUT_DEVICE" \
  PROXYGAUGE_ROUTE_LOOKUP_RESULTS="$ROUTES_UTUN7_V4" \
  PROXYGAUGE_CORE_PIDS=41001 \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=0 \
  PROXYGAUGE_MIXED=127.0.0.1:9 \
  PROXYGAUGE_SECONDARY_ENABLED=0 \
  PROXYGAUGE_TIMEOUT=1 \
  /bin/bash "$CHECK" 2>&1 || true)
/usr/bin/grep -Fq 'TUN: 代表性 IPv4 / IPv6 路由已确认' <<< "$confirmed_fake_ip_route_output"
/usr/bin/grep -Fq '未监听；当前 TUN 系统路径不依赖 mixed 入口' <<< "$confirmed_fake_ip_route_output"

FAKE_TUN_DNS="$TEMP_ROOT/fake-tun-dns"
/usr/bin/printf '%s\n' '#!/bin/bash' 'echo "ip_address: 198.18.0.2"' > "$FAKE_TUN_DNS"
/bin/chmod 755 "$FAKE_TUN_DNS"
if ! tun_only_success_output=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CURL="$FAKE_CURL" \
  PROXYGAUGE_DSCACHEUTIL="$FAKE_TUN_DNS" \
  PROXYGAUGE_SYSTEM_PROXY_STATE=$'<dictionary> {\n  HTTPEnable : 0\n  HTTPSEnable : 0\n}' \
  PROXYGAUGE_TUN_ROUTE_TABLE=$'198.18/15 link#24 UCS utun7' \
  PROXYGAUGE_DISCOVERY_SOCKET_JSON="$TUN_CONFIG_WITHOUT_DEVICE" \
  PROXYGAUGE_ROUTE_LOOKUP_RESULTS="$ROUTES_UTUN7_V4" \
  PROXYGAUGE_CORE_PIDS=41001 \
  PROXYGAUGE_DISCOVERY_PORT_ACTIVE=0 \
  PROXYGAUGE_MIXED=127.0.0.1:9 \
  PROXYGAUGE_SECONDARY_ENABLED=0 \
  PROXYGAUGE_TIMEOUT=1 \
  /bin/bash "$CHECK" 2>&1); then
  echo 'A confirmed TUN-only path must pass without a mixed listener.' >&2
  exit 1
fi
/usr/bin/grep -Fq '出口 IP (TUN 系统路径)' <<< "$tun_only_success_output"
/usr/bin/grep -Fq '代理链路检查通过' <<< "$tun_only_success_output"

mismatched_mihomo_route_output=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CURL="$FAKE_CURL" \
  PROXYGAUGE_TUN_ROUTE_TABLE=$'default            10.0.0.1           UGScg                 utun7' \
  PROXYGAUGE_MIHOMO_TUN_ACTIVE=1 \
  PROXYGAUGE_MIHOMO_TUN_DEVICE=utun8 \
  PROXYGAUGE_ROUTE_LOOKUP_RESULTS="$ROUTES_UTUN7_V4" \
  PROXYGAUGE_CORE_PIDS=41001 \
  PROXYGAUGE_MIXED=127.0.0.1:9 \
  PROXYGAUGE_SECONDARY_ENABLED=0 \
  PROXYGAUGE_TIMEOUT=1 \
  /bin/bash "$CHECK" 2>&1 || true)
/usr/bin/grep -Fq '代表性公网目标走不同接口，可能存在同族或 IPv4 / IPv6 分流' <<< "$mismatched_mihomo_route_output"
if /usr/bin/grep -Fq '代表性 IPv4 / IPv6 路由已确认' <<< "$mismatched_mihomo_route_output"; then
  echo 'A route owned by another utun device must not be attributed to Mihomo.' >&2
  exit 1
fi

mismatched_mihomo_fake_ip_output=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CURL="$FAKE_CURL" \
  PROXYGAUGE_TUN_ROUTE_TABLE=$'198.18/15          link#24            UCS                   utun7' \
  PROXYGAUGE_MIHOMO_TUN_ACTIVE=1 \
  PROXYGAUGE_MIHOMO_TUN_DEVICE=utun8 \
  PROXYGAUGE_ROUTE_LOOKUP_RESULTS="$ROUTES_UTUN7_V4" \
  PROXYGAUGE_CORE_PIDS=41001 \
  PROXYGAUGE_MIXED=127.0.0.1:9 \
  PROXYGAUGE_SECONDARY_ENABLED=0 \
  PROXYGAUGE_TIMEOUT=1 \
  /bin/bash "$CHECK" 2>&1 || true)
/usr/bin/grep -Fq '代表性公网目标走不同接口，可能存在同族或 IPv4 / IPv6 分流' <<< "$mismatched_mihomo_fake_ip_output"

ipv6_output=$(NO_PROXY='*' no_proxy='*' \
  PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CURL="$FAKE_CURL" \
  PROXYGAUGE_MIXED=127.0.0.1:9 \
  PROXYGAUGE_EXPECT_IP=2606:4700:4700:0000:0000:0000:0000:1111 \
  PROXYGAUGE_SECONDARY_ENABLED=0 \
  PROXYGAUGE_ACTIVE_AI_PROBES=0 \
  PROXYGAUGE_TIMEOUT=1 \
  /bin/bash "$CHECK" 2>&1 || true)
/usr/bin/grep -Fq '3 个查询源确认出口一致 (2606:4700:4700::1111)' <<< "$ipv6_output"
/usr/bin/grep -Fq '出口符合配置 (2606:4700:4700::1111)' <<< "$ipv6_output"

wildcard_proxy_state=$'<dictionary> {\n  HTTPSEnable : 1\n  HTTPSProxy : 127.0.0.1\n  HTTPSPort : 9\n  ExceptionsList : <array> {\n    0 : *config*\n  }\n}'
wildcard_bypass_output=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CURL="$FAKE_CURL" \
  PROXYGAUGE_MIXED=127.0.0.1:9 \
  PROXYGAUGE_SYSTEM_PROXY_STATE="$wildcard_proxy_state" \
  PROXYGAUGE_SECONDARY_ENABLED=0 \
  PROXYGAUGE_TIMEOUT=1 \
  /bin/bash "$CHECK" 2>&1 || true)
/usr/bin/grep -Fq '系统代理: 出口查询域名命中绕过列表' <<< "$wildcard_bypass_output"

scoped_only_proxy_state=$'<dictionary> {\n  HTTPEnable : 0\n  HTTPSEnable : 0\n  __SCOPED__ : <dictionary> {\n    en0 : <dictionary> {\n      HTTPSEnable : 1\n      HTTPSProxy : 127.0.0.1\n      HTTPSPort : 9\n    }\n  }\n}'
scoped_only_output=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CURL="$FAKE_CURL" \
  PROXYGAUGE_MIXED=127.0.0.1:9 \
  PROXYGAUGE_SYSTEM_PROXY_STATE="$scoped_only_proxy_state" \
  PROXYGAUGE_SECONDARY_ENABLED=0 \
  PROXYGAUGE_TUN_KIND=none \
  PROXYGAUGE_TIMEOUT=1 \
  /bin/bash "$CHECK" 2>&1 || true)
/usr/bin/grep -Fq '系统代理: 未启用' <<< "$scoped_only_output"
if /usr/bin/grep -Fq '系统代理: 已启用' <<< "$scoped_only_output"; then
  echo 'A scoped proxy dictionary must not be promoted to a top-level global proxy.' >&2
  exit 1
fi

equivalent_loopback_output=$(NO_PROXY='*' no_proxy='*' \
  PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CURL="$FAKE_CURL" \
  PROXYGAUGE_MIXED='[::1]:9' \
  PROXYGAUGE_SECONDARY_ENABLED=1 \
  PROXYGAUGE_SECONDARY_MIXED='0:0:0:0:0:0:0:1:9' \
  PROXYGAUGE_MIHOMO_SOCKET="$TEMP_ROOT/missing.sock" \
  PROXYGAUGE_TIMEOUT=1 \
  /bin/bash "$CHECK" 2>&1 || true)
/usr/bin/grep -Fq '入口与默认 mixed 端口相同，无法区分两个出口' <<< "$equivalent_loopback_output"

remote_endpoint_output=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CURL="$FAKE_CURL" \
  PROXYGAUGE_MIXED='192.0.2.1:7890' \
  PROXYGAUGE_SECONDARY_ENABLED=0 \
  PROXYGAUGE_TIMEOUT=1 \
  /bin/bash "$CHECK" 2>&1 || true)
/usr/bin/grep -Fq '默认 mixed 入口配置无效或不是本机回环地址 (192.0.2.1:7890)' <<< "$remote_endpoint_output"

private_output=$(PROXYGAUGE_FAKE_EXIT_KIND=private \
  PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CURL="$FAKE_CURL" \
  PROXYGAUGE_MIXED=127.0.0.1:9 \
  PROXYGAUGE_SECONDARY_ENABLED=0 \
  PROXYGAUGE_TIMEOUT=1 \
  /bin/bash "$CHECK" 2>&1 || true)
/usr/bin/grep -Fq '无法经代理获取出口 IP (多个查询源均失败)' <<< "$private_output"

padded_output=$(PROXYGAUGE_FAKE_EXIT_KIND=padded \
  PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CURL="$FAKE_CURL" \
  PROXYGAUGE_MIXED=127.0.0.1:9 \
  PROXYGAUGE_SECONDARY_ENABLED=0 \
  PROXYGAUGE_TIMEOUT=1 \
  /bin/bash "$CHECK" 2>&1 || true)
/usr/bin/grep -Fq '无法经代理获取出口 IP (多个查询源均失败)' <<< "$padded_output"
if /usr/bin/grep -Fq '8.8.8.8' <<< "$padded_output"; then
  echo 'Non-canonical IPv4 text with leading zeroes must fail closed.' >&2
  exit 1
fi

mapped_padded_output=$(PROXYGAUGE_FAKE_EXIT_KIND=mappedpadded \
  PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CURL="$FAKE_CURL" \
  PROXYGAUGE_MIXED=127.0.0.1:9 \
  PROXYGAUGE_SECONDARY_ENABLED=0 \
  PROXYGAUGE_TIMEOUT=1 \
  /bin/bash "$CHECK" 2>&1 || true)
/usr/bin/grep -Fq '无法经代理获取出口 IP (多个查询源均失败)' <<< "$mapped_padded_output"

tie_output=$(PROXYGAUGE_FAKE_EXIT_KIND=tie \
  PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_CURL="$FAKE_CURL" \
  PROXYGAUGE_MIXED=127.0.0.1:9 \
  PROXYGAUGE_SECONDARY_ENABLED=0 \
  PROXYGAUGE_TIMEOUT=1 \
  /bin/bash "$CHECK" 2>&1 || true)
/usr/bin/grep -Fq '出口查询无多数一致结果，不选择任意地址' <<< "$tie_output"
if /usr/bin/grep -Fq '默认出口已由多个 IP 查询源确认' <<< "$tie_output"; then
  echo 'A tied health-check result must not be promoted as the default exit.' >&2
  exit 1
fi

echo "ProxyGauge low-risk health tests passed."
