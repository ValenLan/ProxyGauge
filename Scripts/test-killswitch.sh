#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
HELPER="$SCRIPT_DIR/proxygauge-killswitch"
TEST_ROOT=$(/usr/bin/mktemp -d /tmp/proxygauge-killswitch-test.XXXXXX)
trap '/bin/rm -rf "$TEST_ROOT"' EXIT
PERSIST_HELPER="$TEST_ROOT/Library/PrivilegedHelperTools/com.valenlan.proxygauge.killswitch"
PERSIST_PLIST="$TEST_ROOT/Library/LaunchDaemons/com.valenlan.proxygauge.killswitch.plist"
PERSIST_MARKER="$TEST_ROOT/var/db/proxygauge/enabled"
MANAGED_MARKER="$TEST_ROOT/var/db/proxygauge/managed-anchor.sha256"
RUNTIME_STATE="$TEST_ROOT/var/run/proxygauge-killswitch.state"
PERSIST_TEMPLATE="$TEST_ROOT/Library/PrivilegedHelperTools/proxygauge.conf.template"

if /usr/bin/grep -Eq \
  'ANCHOR=(cloudcheck|cloudlink-guard|cloudroute|puffroute|killswitch)|TOKEN_FILE=.*(cloudcheck|cloudlink-guard|cloudroute|puffroute|proxy-tools)' \
  "$HELPER"; then
  echo 'Root helper must never select another product anchor or token.' >&2
  exit 1
fi

# Every test injection point must stay inert in production: the ps-output
# stub may only win when TEST_MODE=1, like the CORE_RECORDS default above it.
/usr/bin/grep -Fq \
  'if [ "$TEST_MODE" -eq 1 ] && [ -n "${PROXYGAUGE_KILLSWITCH_TEST_PS_OUTPUT:-}" ]; then' \
  "$HELPER"

/bin/mkdir -p "$TEST_ROOT/etc/pf.anchors" "$TEST_ROOT/bin" "$TEST_ROOT/var/run"
/usr/bin/printf '%s\n' \
  'set skip on lo0' \
  'scrub-anchor "com.apple/*" all fragment reassemble' \
  'pass out quick all' \
  'anchor "com.apple/*"' > "$TEST_ROOT/etc/pf.conf"
/usr/bin/printf '%s\n' \
  '#!/bin/bash' \
  'state_dir="$PROXYGAUGE_KILLSWITCH_TEST_ROOT/var/run/pfctl-state"' \
  '/bin/mkdir -p "$state_dir"' \
  '/usr/bin/printf "%s\\n" "$*" >> "$PROXYGAUGE_KILLSWITCH_TEST_ROOT/var/run/pfctl.log"' \
  'if [ "$1" = "-s" ] && [ "${2:-}" = "info" ]; then echo "Status: Enabled"; exit 0; fi' \
  'if [ "$1" = "-E" ]; then echo "Token : 12345"; exit 0; fi' \
  'if [ "$1" = "-sr" ]; then' \
  '  if [ -n "${PROXYGAUGE_KILLSWITCH_TEST_RUNTIME_RULES:-}" ]; then' \
  '    /usr/bin/printf "%b\\n" "$PROXYGAUGE_KILLSWITCH_TEST_RUNTIME_RULES"' \
  '  else' \
  '    source="$state_dir/main.conf"' \
  '    [ -r "$source" ] || source="$PROXYGAUGE_KILLSWITCH_TEST_ROOT/etc/pf.conf"' \
  '    /usr/bin/awk '\''/^[[:space:]]*(scrub-anchor|anchor|block|pass|match|antispoof)([[:space:]]|$)/ { sub(/^[[:space:]]*/, ""); print }'\'' "$source"' \
  '  fi' \
  '  exit 0' \
  'fi' \
  'if [ "$1" = "-a" ] && [ "${2:-}" = "proxygauge" ] && [ "${3:-}" = "-sr" ]; then' \
  '  [ ! -r "$state_dir/anchor.conf" ] || /bin/cat "$state_dir/anchor.conf"' \
  '  exit 0' \
  'fi' \
  'if [ "$1" = "-a" ] && [ "${2:-}" = "proxygauge" ] && [ "${3:-}" = "-f" ]; then' \
  '  /bin/cp "$4" "$state_dir/anchor.conf"; exit 0' \
  'fi' \
  'if [ "$1" = "-a" ] && [ "${2:-}" = "proxygauge" ] && [ "${3:-}" = "-F" ]; then' \
  '  : > "$state_dir/anchor.conf"; exit 0' \
  'fi' \
  'if [ "$1" = "-f" ]; then /bin/cp "$2" "$state_dir/main.conf"; exit 0; fi' \
  'exit 0' > "$TEST_ROOT/bin/pfctl"
/bin/chmod 755 "$TEST_ROOT/bin/pfctl"

run_helper() {
  PROXYGAUGE_KILLSWITCH_TEST_ROOT="$TEST_ROOT" \
  PROXYGAUGE_KILLSWITCH_TEST_PFCTL="$TEST_ROOT/bin/pfctl" \
  PROXYGAUGE_KILLSWITCH_TEST_INTERFACES="${PROXYGAUGE_KILLSWITCH_TEST_INTERFACES:-en0 en1}" \
  PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES="${PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES-utun0}" \
  PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_PID="${PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_PID-1001}" \
  PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_DEVICE="${PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_DEVICE-${PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES:-utun0}}" \
  PROXYGAUGE_KILLSWITCH_TEST_STATE_ADDRESSES="${PROXYGAUGE_KILLSWITCH_TEST_STATE_ADDRESSES:-192.0.2.10 2001:db8::10}" \
  PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="${PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS-verge-mihomo:1001:0}" \
  PROXYGAUGE_KILLSWITCH_TEST_PS_OUTPUT="${PROXYGAUGE_KILLSWITCH_TEST_PS_OUTPUT-}" \
  PROXYGAUGE_KILLSWITCH_TEST_RUNTIME_RULES="${PROXYGAUGE_KILLSWITCH_TEST_RUNTIME_RULES:-}" \
  /bin/bash "$HELPER" "$@"
}

run_persisted_helper() {
  PROXYGAUGE_KILLSWITCH_TEST_ROOT="$TEST_ROOT" \
  PROXYGAUGE_KILLSWITCH_TEST_PFCTL="$TEST_ROOT/bin/pfctl" \
  PROXYGAUGE_KILLSWITCH_TEST_INTERFACES="${PROXYGAUGE_KILLSWITCH_TEST_INTERFACES:-en0 en1}" \
  PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES="${PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES-utun0}" \
  PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_PID="${PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_PID-1001}" \
  PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_DEVICE="${PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_DEVICE-${PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES:-utun0}}" \
  PROXYGAUGE_KILLSWITCH_TEST_STATE_ADDRESSES="${PROXYGAUGE_KILLSWITCH_TEST_STATE_ADDRESSES:-192.0.2.10 2001:db8::10}" \
  PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="${PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS-verge-mihomo:1001:0}" \
  PROXYGAUGE_KILLSWITCH_TEST_PS_OUTPUT="${PROXYGAUGE_KILLSWITCH_TEST_PS_OUTPUT-}" \
  PROXYGAUGE_KILLSWITCH_TEST_RUNTIME_RULES="${PROXYGAUGE_KILLSWITCH_TEST_RUNTIME_RULES:-}" \
  /bin/bash "$PERSIST_HELPER" "$@"
}

bootstrap_output=$(run_helper on)
/usr/bin/printf '%s\n' "$bootstrap_output" | /usr/bin/grep -Fq '规则已安装，当前保持关闭'
/usr/bin/printf '%s\n' "$bootstrap_output" | /usr/bin/grep -Fq 'Kill Switch 已开启'
first_filter=$(/usr/bin/awk '
  /^[[:space:]]*(anchor|block|pass|match|antispoof)([[:space:]]|$)/ {
    sub(/^[[:space:]]*/, "")
    print
    exit
  }
' "$TEST_ROOT/etc/pf.conf")
[ "$first_filter" = 'anchor "proxygauge" quick' ]
/usr/bin/grep -Fq 'trusted_tunnels = "{ lo0 utun0 }"' "$TEST_ROOT/etc/pf.anchors/proxygauge"
/usr/bin/grep -Fq 'block return out quick all' "$TEST_ROOT/etc/pf.anchors/proxygauge"
[ "$(/usr/bin/grep -Fc 'keep state (if-bound)' "$TEST_ROOT/etc/pf.anchors/proxygauge")" -eq 4 ]
if /usr/bin/grep -Fq 'phys =' "$TEST_ROOT/etc/pf.anchors/proxygauge"; then
  echo 'Kill Switch 规则不得再依赖启用瞬间的物理接口快照' >&2
  exit 1
fi
if /usr/bin/grep -Eq '__VPS_IP__|cloudlink_guard_(lan|vps)' "$TEST_ROOT/etc/pf.anchors/proxygauge"; then
  echo '内置规则不得依赖服务器 IP 参数' >&2
  exit 1
fi
if /usr/bin/grep -Eq 'port[[:space:]]+53' "$TEST_ROOT/etc/pf.anchors/proxygauge"; then
  echo '普通用户不得获得独立的直连 DNS 例外' >&2
  exit 1
fi
[ -r "$TEST_ROOT/backups-only/pf.conf-before-install" ]
[ -s "$TEST_ROOT/var/run/proxygauge-killswitch.pf-token" ]
[ -x "$PERSIST_HELPER" ]
[ -r "$PERSIST_PLIST" ]
[ -r "$PERSIST_MARKER" ]
[ -r "$MANAGED_MARKER" ]
[ -r "$PERSIST_TEMPLATE" ]
[ "$(/usr/bin/head -1 "$RUNTIME_STATE")" = "enabled" ]
/usr/bin/plutil -lint "$PERSIST_PLIST" >/dev/null
/usr/bin/grep -Fq '<string>restore</string>' "$PERSIST_PLIST"
/usr/bin/grep -Fq '<key>StartInterval</key>' "$PERSIST_PLIST"
/usr/bin/grep -Fq '<integer>2</integer>' "$PERSIST_PLIST"
/usr/bin/grep -Fq -- '-k 0.0.0.0/0 -k ' "$TEST_ROOT/var/run/pfctl.log"
/usr/bin/grep -Fq -- '-k ::/0 -k ' "$TEST_ROOT/var/run/pfctl.log"
! /usr/bin/grep -Fq -- '-F states' "$TEST_ROOT/var/run/pfctl.log"

# Legacy unmarked built-in rules must migrate on upgrade.
/bin/rm -f "$MANAGED_MARKER"
cat > "$TEST_ROOT/etc/pf.anchors/proxygauge" <<'LEGACY'
table <proxygauge_lan> persist { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4, 255.255.255.255/32, fe80::/10, ff02::/16 }
phys = "{ en0 en1 }"
pass quick on lo0 all
pass out quick on $phys from any to <proxygauge_lan>
pass out quick on $phys all user = 0
block return out on $phys all
LEGACY
run_helper on >/dev/null
/usr/bin/grep -Fq 'trusted_tunnels = "{ lo0 utun0 }"' "$TEST_ROOT/etc/pf.anchors/proxygauge"
[ -r "$MANAGED_MARKER" ]

/usr/bin/printf '%s\n' \
  'pass quick on lo0 all' \
  'pass out quick on utun0 all' \
  'block return out quick all' > "$TEST_ROOT/etc/pf.anchors/proxygauge"
/usr/bin/shasum -a 256 "$TEST_ROOT/etc/pf.anchors/proxygauge" \
  | /usr/bin/awk '{ print $1 }' > "$MANAGED_MARKER"
: > "$TEST_ROOT/var/run/pfctl.log"
run_persisted_helper restore >/dev/null
! /usr/bin/grep -Fq -- '-F states' "$TEST_ROOT/var/run/pfctl.log"
[ "$(/usr/bin/grep -Fc 'keep state (if-bound)' "$TEST_ROOT/etc/pf.anchors/proxygauge")" -eq 4 ]

unsafe_runtime_status=$(PROXYGAUGE_KILLSWITCH_TEST_RUNTIME_RULES=$'pass out quick all\nanchor "proxygauge" quick all' \
  run_helper status)
/usr/bin/printf '%s\n' "$unsafe_runtime_status" \
  | /usr/bin/grep -Fq 'anchor 注册位置或 PF set skip 配置不安全'

/usr/bin/printf '%s\n' \
  'pass out quick all' \
  'anchor "proxygauge" quick' > "$TEST_ROOT/var/run/pfctl-state/main.conf"
runtime_repair_output=$(run_persisted_helper restore)
/usr/bin/printf '%s\n' "$runtime_repair_output" | /usr/bin/grep -Fq '已修复 Kill Switch 运行时规则入口'
runtime_first_filter=$(PROXYGAUGE_KILLSWITCH_TEST_ROOT="$TEST_ROOT" \
  "$TEST_ROOT/bin/pfctl" -sr | /usr/bin/awk '/^scrub(-anchor)?[[:space:]]/ {next} NF { print; exit }')
[ "$runtime_first_filter" = 'anchor "proxygauge" quick' ]

safe_main_config="$TEST_ROOT/var/run/safe-main.conf"
unsafe_main_config="$TEST_ROOT/var/run/unsafe-main.conf"
/bin/cp "$TEST_ROOT/etc/pf.conf" "$safe_main_config"
/usr/bin/printf '%s\n' \
  'set skip on en0' \
  'anchor "proxygauge" quick' > "$TEST_ROOT/etc/pf.conf"
/bin/cp "$TEST_ROOT/etc/pf.conf" "$unsafe_main_config"
unsafe_skip_status=$(run_helper status)
/usr/bin/printf '%s\n' "$unsafe_skip_status" \
  | /usr/bin/grep -Fq 'PF set skip 配置不安全'
if unsafe_skip_output=$(run_helper on 2>&1); then
  echo '非 loopback set skip 可绕过 PF，必须拒绝开启 Kill Switch' >&2
  exit 1
fi
/usr/bin/printf '%s\n' "$unsafe_skip_output" \
  | /usr/bin/grep -Fq '可绕过保护的 set skip 指令'
/usr/bin/cmp -s "$unsafe_main_config" "$TEST_ROOT/etc/pf.conf"
/bin/cp "$safe_main_config" "$TEST_ROOT/etc/pf.conf"

: > "$TEST_ROOT/var/run/pfctl.log"
PROXYGAUGE_KILLSWITCH_TEST_INTERFACES='en2' \
PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES='utun2' \
PROXYGAUGE_KILLSWITCH_TEST_STATE_ADDRESSES='198.51.100.20 2001:db8::20' \
  run_persisted_helper restore >/dev/null
/usr/bin/grep -Fq 'trusted_tunnels = "{ lo0 utun2 }"' "$TEST_ROOT/etc/pf.anchors/proxygauge"
/usr/bin/grep -Fq 'block return out quick all' "$TEST_ROOT/etc/pf.anchors/proxygauge"
! /usr/bin/grep -q -- '^-k ' "$TEST_ROOT/var/run/pfctl.log"
[ "$(/usr/bin/grep -c -- '^-a proxygauge -f ' "$TEST_ROOT/var/run/pfctl.log")" -eq 1 ]
! /usr/bin/grep -q -- '-F rules' "$TEST_ROOT/var/run/pfctl.log"

# With two resident cores, actual Clash controller + current route wins in AUTO.
PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS=$'verge-mihomo:1001:0\niKuuuVPNCore:1002:0' \
  run_helper on AUTO >/dev/null
[ "$(/usr/bin/sed -n '2p' "${RUNTIME_STATE%.state}.selection")" = /Applications/verge-mihomo ]
# Existing but unselected utuns cannot be granted to a pinned Clash instance.
PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES='utun5' \
PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_DEVICE='utun0' \
  run_helper on /Applications/verge-mihomo >/dev/null
/usr/bin/grep -Fq 'trusted_tunnels = "{ lo0 }"' "$TEST_ROOT/etc/pf.anchors/proxygauge"
# Pinned selection survives process disappearance; the final block stays active.
PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS='iKuuuVPNCore:1002:0' \
  run_persisted_helper restore >/dev/null
[ "$(/usr/bin/head -1 "${RUNTIME_STATE%.state}.selection")" = /Applications/verge-mihomo ]
/usr/bin/grep -Fq 'trusted_tunnels = "{ lo0 }"' "$TEST_ROOT/etc/pf.anchors/proxygauge"
/usr/bin/grep -Fq 'block return out quick all' "$TEST_ROOT/etc/pf.anchors/proxygauge"
run_helper on AUTO >/dev/null

for core_name in verge-mihomo mihomo clash-meta; do
  PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$core_name:2001:0" \
    run_helper on >/dev/null
done
if PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS=$'mihomo:2001:0\nclash-meta:2002:0' \
  run_helper on >/dev/null 2>&1; then
  echo '同时运行多个 Mihomo 核心时不得开启 Kill Switch' >&2
  exit 1
fi
if PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS='mihomo:2001:501' \
  run_helper on >/dev/null 2>&1; then
  echo '非 root Mihomo 核心不得开启 Kill Switch' >&2
  exit 1
fi
if PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS='' run_helper on >/dev/null 2>&1; then
  echo '没有 Mihomo 核心时不得开启 Kill Switch' >&2
  exit 1
fi

/usr/bin/printf '%s\n' 'set skip on lo0' > "$TEST_ROOT/etc/pf.conf"
/bin/rm -f "$TEST_ROOT/etc/pf.anchors/proxygauge" \
  "$TEST_ROOT/var/run/proxygauge-killswitch.pf-token"
if PROXYGAUGE_KILLSWITCH_TEST_INTERFACES='en0; reboot' run_helper on >/dev/null 2>&1; then
  echo '非法接口参数不应通过校验' >&2
  exit 1
fi
if PROXYGAUGE_KILLSWITCH_TEST_INTERFACES='utun0' run_helper on >/dev/null 2>&1; then
  echo '隧道接口不应被当作物理接口' >&2
  exit 1
fi

/usr/bin/printf '%s\n' 'block return out on en0 all' > "$TEST_ROOT/etc/pf.anchors/cloudcheck"
if run_helper install >/dev/null 2>&1; then
  echo '非 ProxyGauge 规则存在时不得安装第二套 anchor' >&2
  exit 1
fi
if unsupported_output=$(run_helper on 2>&1); then
  echo '非 ProxyGauge 规则存在时不得启用或复用它' >&2
  exit 1
fi
/usr/bin/printf '%s\n' "$unsupported_output" | /usr/bin/grep -Fq '非 ProxyGauge 的 Kill Switch 规则'
if /usr/bin/grep -Fq 'anchor "cloudcheck"' "$TEST_ROOT/etc/pf.conf"; then
  echo '不得注册其他产品的 anchor' >&2
  exit 1
fi
/bin/rm -f "$TEST_ROOT/etc/pf.anchors/cloudcheck"
/usr/bin/printf '%s\n' \
  'set skip on lo0' \
  'pass out quick all' \
  'anchor "proxygauge"' > "$TEST_ROOT/etc/pf.conf"

/usr/bin/printf '%s\n' 'block return out on en0 all' > "$TEST_ROOT/etc/pf.anchors/proxygauge"
anchor_hash_before=$(/usr/bin/shasum -a 256 "$TEST_ROOT/etc/pf.anchors/proxygauge" | /usr/bin/awk '{print $1}')
recovery_output=$(run_helper on)
/usr/bin/printf '%s\n' "$recovery_output" | /usr/bin/grep -Fq '已恢复原有 Kill Switch 规则入口'
/usr/bin/printf '%s\n' "$recovery_output" | /usr/bin/grep -Fq 'Kill Switch 已开启'
recovered_first_filter=$(/usr/bin/awk '
  /^[[:space:]]*(anchor|block|pass|match|antispoof)([[:space:]]|$)/ {
    sub(/^[[:space:]]*/, "")
    print
    exit
  }
' "$TEST_ROOT/etc/pf.conf")
[ "$recovered_first_filter" = 'anchor "proxygauge" quick' ]
[ -r "$TEST_ROOT/backups-only/pf.conf-before-entry-repair" ]
[ -s "$TEST_ROOT/var/run/proxygauge-killswitch.pf-token" ]
anchor_hash_after=$(/usr/bin/shasum -a 256 "$TEST_ROOT/etc/pf.anchors/proxygauge" | /usr/bin/awk '{print $1}')
[ "$anchor_hash_before" = "$anchor_hash_after" ]

if run_helper install >/dev/null 2>&1; then
  echo '已存在 ProxyGauge anchor 时不得覆盖安装' >&2
  exit 1
fi

# /var/run is cleared at reboot. The root-owned LaunchDaemon helper must
# restore both the PF rules and this boot-scoped enable reference.
/bin/rm -f "$TEST_ROOT/var/run/proxygauge-killswitch.pf-token"
restore_output=$(run_persisted_helper restore)
/usr/bin/printf '%s\n' "$restore_output" | /usr/bin/grep -Fq 'Kill Switch 已开启'
[ -s "$TEST_ROOT/var/run/proxygauge-killswitch.pf-token" ]

off_output=$(run_helper off)
/usr/bin/printf '%s\n' "$off_output" | /usr/bin/grep -Fq 'Kill Switch 已关闭'
[ ! -e "$PERSIST_MARKER" ]
[ ! -e "$TEST_ROOT/var/run/proxygauge-killswitch.pf-token" ]
[ "$(/usr/bin/head -1 "$RUNTIME_STATE")" = "disabled" ]
disabled_restore_output=$(run_persisted_helper restore)
/usr/bin/printf '%s\n' "$disabled_restore_output" | /usr/bin/grep -Fq '保持关闭'
[ ! -e "$TEST_ROOT/var/run/proxygauge-killswitch.pf-token" ]

# --- User-space NE provider (Shadowrocket/MacPacketTunnel) monitor/lockdown ---
# Reset to a fresh managed installation before exercising NE selection.
/usr/bin/printf '%s\n' \
  'set skip on lo0' \
  'scrub-anchor "com.apple/*" all fragment reassemble' \
  'pass out quick all' \
  'anchor "com.apple/*"' > "$TEST_ROOT/etc/pf.conf"
/bin/rm -f "$TEST_ROOT/etc/pf.anchors/proxygauge" \
  "$TEST_ROOT/var/run/proxygauge-killswitch.pf-token"
run_helper on >/dev/null

# Shadowrocket.app and MacPacketTunnel are two processes of one NE provider:
# a single provider must be selectable in AUTO despite neither running as root.
ne_records='Shadowrocket:1499:501:/Applications/Shadowrocket.app/Contents/MacOS/Shadowrocket:ne
MacPacketTunnel:1500:501:/Applications/Shadowrocket.app/Contents/PlugIns/MacPacketTunnel.appex/Contents/MacOS/MacPacketTunnel:ne'
ne_ps_output=' 1499  501 /Applications/Shadowrocket.app/Contents/MacOS/Shadowrocket
 1500  501 /Applications/Shadowrocket.app/Contents/PlugIns/MacPacketTunnel.appex/Contents/MacOS/MacPacketTunnel'

# Monitoring state: a live NE provider with a public routed utun keeps every
# pass rule but omits the catch-all block — the NE enforces routing itself.
ne_on_output=$(PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$ne_records" run_helper on)
/usr/bin/printf '%s\n' "$ne_on_output" | /usr/bin/grep -Fq 'Kill Switch 已开启'
[ "$(/usr/bin/sed -n '2p' "${RUNTIME_STATE%.state}.selection")" = '/Applications/Shadowrocket.app/Contents/MacOS/Shadowrocket' ]
/usr/bin/grep -Fq 'trusted_tunnels = "{ lo0 utun0 }"' "$TEST_ROOT/etc/pf.anchors/proxygauge"
if /usr/bin/grep -Fq 'block return out quick all' "$TEST_ROOT/etc/pf.anchors/proxygauge"; then
  echo 'NE 监控态不得渲染 catch-all block（NE 存活时路由由 NE 强制执行）' >&2
  exit 1
fi
[ "$(/usr/bin/grep -Fc 'keep state (if-bound)' "$TEST_ROOT/etc/pf.anchors/proxygauge")" -eq 4 ]
[ ! -e "$TEST_ROOT/var/db/proxygauge/ne-endpoints" ]

# A manually pinned NE path skips the root-service requirement, both via
# record injection and through the real ps-scan branch (stubbed ps output).
PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$ne_records" \
  run_helper on '/Applications/Shadowrocket.app/Contents/PlugIns/MacPacketTunnel.appex/Contents/MacOS/MacPacketTunnel' >/dev/null
[ "$(/usr/bin/sed -n '2p' "${RUNTIME_STATE%.state}.selection")" = '/Applications/Shadowrocket.app/Contents/PlugIns/MacPacketTunnel.appex/Contents/MacOS/MacPacketTunnel' ]
PROXYGAUGE_KILLSWITCH_TEST_PS_OUTPUT="$ne_ps_output" \
  run_helper on '/Applications/Shadowrocket.app/Contents/PlugIns/MacPacketTunnel.appex/Contents/MacOS/MacPacketTunnel' >/dev/null
[ "$(/usr/bin/sed -n '2p' "${RUNTIME_STATE%.state}.selection")" = '/Applications/Shadowrocket.app/Contents/PlugIns/MacPacketTunnel.appex/Contents/MacOS/MacPacketTunnel' ]
PROXYGAUGE_KILLSWITCH_TEST_PS_OUTPUT="$ne_ps_output" run_helper on AUTO >/dev/null
[ "$(/usr/bin/sed -n '2p' "${RUNTIME_STATE%.state}.selection")" = '/Applications/Shadowrocket.app/Contents/MacOS/Shadowrocket' ]

# Enabling with an NE provider but no public routed utun is refused unchanged.
ne_anchor_hash_before=$(/usr/bin/shasum -a 256 "$TEST_ROOT/etc/pf.anchors/proxygauge" | /usr/bin/awk '{print $1}')
if ne_no_tunnel_output=$(PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$ne_records" \
  PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES='' \
  run_helper on 2>&1); then
  echo 'NE 客户端无公网路由 utun 时不得开启 Kill Switch' >&2
  exit 1
fi
/usr/bin/printf '%s\n' "$ne_no_tunnel_output" \
  | /usr/bin/grep -Fq 'PROXY_NOT_ROOT：请先开启代理客户端的系统服务或 VPN/TUN。'
[ "$ne_anchor_hash_before" = "$(/usr/bin/shasum -a 256 "$TEST_ROOT/etc/pf.anchors/proxygauge" | /usr/bin/awk '{print $1}')" ]

# Lockdown: an armed restore that finds no public routed utun renders the
# catch-all block while keeping lo0/LAN/root exemptions. Entering lockdown
# from a block-less monitoring anchor must purge physical states exactly once.
: > "$TEST_ROOT/var/run/pfctl.log"
PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$ne_records" \
  PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES='' \
  run_persisted_helper restore >/dev/null
/usr/bin/grep -Fq 'trusted_tunnels = "{ lo0 }"' "$TEST_ROOT/etc/pf.anchors/proxygauge"
/usr/bin/grep -Fq 'block return out quick all' "$TEST_ROOT/etc/pf.anchors/proxygauge"
[ "$(/usr/bin/head -1 "$RUNTIME_STATE")" = "enabled" ]
/usr/bin/grep -Fq -- '-k 0.0.0.0/0 -k ' "$TEST_ROOT/var/run/pfctl.log"
/usr/bin/grep -Fq -- '-k ::/0 -k ' "$TEST_ROOT/var/run/pfctl.log"
! /usr/bin/grep -Fq -- '-F states' "$TEST_ROOT/var/run/pfctl.log"
# Staying in lockdown must not purge again on the next cycle.
: > "$TEST_ROOT/var/run/pfctl.log"
PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$ne_records" \
  PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES='' \
  run_persisted_helper restore >/dev/null
! /usr/bin/grep -q -- '^-k ' "$TEST_ROOT/var/run/pfctl.log"

# The periodic restore flips monitor↔lockdown as the tunnel comes and goes.
PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$ne_records" \
  run_persisted_helper restore >/dev/null
/usr/bin/grep -Fq 'trusted_tunnels = "{ lo0 utun0 }"' "$TEST_ROOT/etc/pf.anchors/proxygauge"
if /usr/bin/grep -Fq 'block return out quick all' "$TEST_ROOT/etc/pf.anchors/proxygauge"; then
  echo '隧道恢复后必须回到监控态（省略 catch-all block）' >&2
  exit 1
fi
# The NE provider dying while armed locks the machine down on the next cycle,
# again purging the physical states the open anchor had accumulated.
: > "$TEST_ROOT/var/run/pfctl.log"
PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS='' \
  run_persisted_helper restore >/dev/null
/usr/bin/grep -Fq 'trusted_tunnels = "{ lo0 }"' "$TEST_ROOT/etc/pf.anchors/proxygauge"
/usr/bin/grep -Fq 'block return out quick all' "$TEST_ROOT/etc/pf.anchors/proxygauge"
/usr/bin/grep -Fq -- '-k 0.0.0.0/0 -k ' "$TEST_ROOT/var/run/pfctl.log"
# The provider returning lifts the lockdown automatically.
PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$ne_records" \
  run_persisted_helper restore >/dev/null
/usr/bin/grep -Fq 'trusted_tunnels = "{ lo0 utun0 }"' "$TEST_ROOT/etc/pf.anchors/proxygauge"
if /usr/bin/grep -Fq 'block return out quick all' "$TEST_ROOT/etc/pf.anchors/proxygauge"; then
  echo 'NE 提供者回归后必须解除锁定态' >&2
  exit 1
fi
# A manually pinned NE selection also locks down when its process dies, and
# resumes monitoring when the process returns.
PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$ne_records" \
  run_helper on '/Applications/Shadowrocket.app/Contents/PlugIns/MacPacketTunnel.appex/Contents/MacOS/MacPacketTunnel' >/dev/null
PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS='' \
  run_persisted_helper restore >/dev/null
/usr/bin/grep -Fq 'block return out quick all' "$TEST_ROOT/etc/pf.anchors/proxygauge"
[ "$(/usr/bin/head -1 "$RUNTIME_STATE")" = "enabled" ]
PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$ne_records" \
  run_persisted_helper restore >/dev/null
if /usr/bin/grep -Fq 'block return out quick all' "$TEST_ROOT/etc/pf.anchors/proxygauge"; then
  echo '手动 NE 选择的进程回归后必须解除锁定态' >&2
  exit 1
fi

# Armed restore hard failures must fail closed even when the last render was
# a block-less monitoring anchor (selection-failed branch).
mock_anchor="$TEST_ROOT/var/run/pfctl-state/anchor.conf"
if PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS='mihomo:abc:0' \
  run_persisted_helper restore >/dev/null 2>&1; then
  echo 'restore 选择失败必须返回非零' >&2
  exit 1
fi
/usr/bin/grep -Fq 'selection-failed' "$RUNTIME_STATE"
/usr/bin/grep -Fq 'trusted_tunnels = "{ lo0 }"' "$mock_anchor"
/usr/bin/grep -Fq 'block return out quick all' "$mock_anchor"
# Recover to the monitoring anchor before the next failure injection.
PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$ne_records" \
  run_persisted_helper restore >/dev/null
if /usr/bin/grep -Fq 'block return out quick all' "$mock_anchor"; then
  echo '故障恢复后必须回到监控态' >&2
  exit 1
fi
# restore-failed branch: enable fails when the persisted template is missing.
/bin/rm -f "$PERSIST_TEMPLATE"
if PROXYGAUGE_KILLSWITCH_TEST_TEMPLATE="$SCRIPT_DIR/../PF/proxygauge.conf.template" \
  PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$ne_records" \
  run_persisted_helper restore >/dev/null 2>&1; then
  echo 'restore 启用失败必须返回非零' >&2
  exit 1
fi
/usr/bin/grep -Fq 'restore-failed' "$RUNTIME_STATE"
/usr/bin/grep -Fq 'block return out quick all' "$mock_anchor"
# The placeholder guard must keep rejecting the retired NE token: an old-format
# persisted template (upgrade race) must fault, never leak literal placeholders.
/bin/cat > "$PERSIST_TEMPLATE" <<'OLD_FORMAT_TEMPLATE'
table <proxygauge_lan> persist { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/24, 239.0.0.0/8, 255.255.255.255/32, fc00::/7, fe80::/10, ff02::/16 }
trusted_tunnels = "{ __TUN_INTERFACES__ }"
pass quick on lo0 all keep state (if-bound)
pass out quick on $trusted_tunnels all keep state (if-bound)
pass out quick from any to <proxygauge_lan> keep state (if-bound)
pass out quick all user = 0 keep state (if-bound)
__NE_ENDPOINT_RULES__
block return out quick all
OLD_FORMAT_TEMPLATE
if PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$ne_records" \
  run_persisted_helper restore >/dev/null 2>&1; then
  echo '旧格式模板必须触发故障而非渲染字面占位符' >&2
  exit 1
fi
/usr/bin/grep -Fq 'restore-failed' "$RUNTIME_STATE"
/usr/bin/grep -Fq 'block return out quick all' "$mock_anchor"
if /usr/bin/grep -Fq '__NE_ENDPOINT_RULES__' "$mock_anchor"; then
  echo '运行时规则不得残留已退役的模板占位符' >&2
  exit 1
fi

# Root core behaviour stays unchanged: the catch-all block is always rendered.
run_helper on AUTO >/dev/null
/usr/bin/grep -Fq 'block return out quick all' "$TEST_ROOT/etc/pf.anchors/proxygauge"
/usr/bin/grep -Fq 'trusted_tunnels = "{ lo0 utun0 }"' "$TEST_ROOT/etc/pf.anchors/proxygauge"
[ "$(/usr/bin/grep -Fc 'keep state (if-bound)' "$TEST_ROOT/etc/pf.anchors/proxygauge")" -eq 4 ]
[ "$(/usr/bin/sed -n '2p' "${RUNTIME_STATE%.state}.selection")" = /Applications/verge-mihomo ]
[ ! -e "$TEST_ROOT/var/db/proxygauge/ne-endpoints" ]
if /usr/bin/grep -qE '__TUN_INTERFACES__|__BLOCK_ALL_RULE__|__NE_ENDPOINT_RULES__' "$TEST_ROOT/etc/pf.anchors/proxygauge"; then
  echo '渲染产物不得残留模板占位符' >&2
  exit 1
fi

# Legacy endpoint-pinning leftovers are removed on enable and on off.
/usr/bin/printf '%s\n' '203.0.113.9' > "$TEST_ROOT/var/db/proxygauge/ne-endpoints"
run_helper on AUTO >/dev/null
[ ! -e "$TEST_ROOT/var/db/proxygauge/ne-endpoints" ]
/usr/bin/printf '%s\n' '203.0.113.9' > "$TEST_ROOT/var/db/proxygauge/ne-endpoints"
: > "$TEST_ROOT/var/run/pfctl.log"
run_helper off >/dev/null
[ ! -e "$TEST_ROOT/var/db/proxygauge/ne-endpoints" ]
/usr/bin/grep -Fq -- '-t proxygauge_ne_endpoints -T flush' "$TEST_ROOT/var/run/pfctl.log"

if run_helper install unexpected >/dev/null 2>&1; then
  echo '内置安装不得接收用户配置参数' >&2
  exit 1
fi

if run_helper pause >/dev/null 2>&1; then
  echo 'Kill Switch 只保留持久开关，不得重新加入限时暂停动作' >&2
  exit 1
fi

echo 'ProxyGauge Kill Switch self-contained installation and recovery safety tests passed.'
