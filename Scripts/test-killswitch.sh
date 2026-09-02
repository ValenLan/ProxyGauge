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

/bin/mkdir -p "$TEST_ROOT/etc/pf.anchors" "$TEST_ROOT/bin" "$TEST_ROOT/var/run"
/usr/bin/printf '%s\n' \
  'set skip on lo0' \
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
  '    /usr/bin/awk '\''/^[[:space:]]*(anchor|block|pass|match|antispoof)([[:space:]]|$)/ { sub(/^[[:space:]]*/, ""); print }'\'' "$source"' \
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
  PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES="${PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES:-utun0}" \
  PROXYGAUGE_KILLSWITCH_TEST_STATE_ADDRESSES="${PROXYGAUGE_KILLSWITCH_TEST_STATE_ADDRESSES:-192.0.2.10 2001:db8::10}" \
  PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="${PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS-verge-mihomo:1001:0}" \
  PROXYGAUGE_KILLSWITCH_TEST_RUNTIME_RULES="${PROXYGAUGE_KILLSWITCH_TEST_RUNTIME_RULES:-}" \
  /bin/bash "$HELPER" "$@"
}

run_persisted_helper() {
  PROXYGAUGE_KILLSWITCH_TEST_ROOT="$TEST_ROOT" \
  PROXYGAUGE_KILLSWITCH_TEST_PFCTL="$TEST_ROOT/bin/pfctl" \
  PROXYGAUGE_KILLSWITCH_TEST_INTERFACES="${PROXYGAUGE_KILLSWITCH_TEST_INTERFACES:-en0 en1}" \
  PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES="${PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES:-utun0}" \
  PROXYGAUGE_KILLSWITCH_TEST_STATE_ADDRESSES="${PROXYGAUGE_KILLSWITCH_TEST_STATE_ADDRESSES:-192.0.2.10 2001:db8::10}" \
  PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="${PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS-verge-mihomo:1001:0}" \
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
[ -r "$TEST_ROOT/etc/pf.conf.proxygauge.bak" ]
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
/usr/bin/grep -Fq '<integer>15</integer>' "$PERSIST_PLIST"
/usr/bin/grep -Fq -- '-k 192.0.2.10' "$TEST_ROOT/var/run/pfctl.log"
/usr/bin/grep -Fq -- '-k 2001:db8::10' "$TEST_ROOT/var/run/pfctl.log"
/usr/bin/grep -Fq -- '-F states' "$TEST_ROOT/var/run/pfctl.log"

/usr/bin/printf '%s\n' \
  'pass quick on lo0 all' \
  'pass out quick on utun0 all' \
  'block return out quick all' > "$TEST_ROOT/etc/pf.anchors/proxygauge"
/usr/bin/shasum -a 256 "$TEST_ROOT/etc/pf.anchors/proxygauge" \
  | /usr/bin/awk '{ print $1 }' > "$MANAGED_MARKER"
: > "$TEST_ROOT/var/run/pfctl.log"
run_persisted_helper restore >/dev/null
/usr/bin/grep -Fq -- '-F states' "$TEST_ROOT/var/run/pfctl.log"
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
  "$TEST_ROOT/bin/pfctl" -sr | /usr/bin/awk 'NF { print; exit }')
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
/usr/bin/grep -Fq -- '-k 198.51.100.20' "$TEST_ROOT/var/run/pfctl.log"
/usr/bin/grep -Fq -- '-k 2001:db8::20' "$TEST_ROOT/var/run/pfctl.log"
transition_line=$(/usr/bin/grep -n -- '^-a proxygauge -f ' "$TEST_ROOT/var/run/pfctl.log" \
  | /usr/bin/head -1 | /usr/bin/cut -d: -f1)
state_clear_line=$(/usr/bin/grep -n -- '^-k 198.51.100.20$' "$TEST_ROOT/var/run/pfctl.log" \
  | /usr/bin/head -1 | /usr/bin/cut -d: -f1)
final_rule_line=$(/usr/bin/grep -n -- '^-a proxygauge -f ' "$TEST_ROOT/var/run/pfctl.log" \
  | /usr/bin/tail -1 | /usr/bin/cut -d: -f1)
[ "$transition_line" -lt "$state_clear_line" ]
[ "$state_clear_line" -lt "$final_rule_line" ]

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
[ -r "$TEST_ROOT/etc/pf.conf.proxygauge-entry.bak" ]
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

if run_helper install unexpected >/dev/null 2>&1; then
  echo '内置安装不得接收用户配置参数' >&2
  exit 1
fi

if run_helper pause >/dev/null 2>&1; then
  echo 'Kill Switch 只保留持久开关，不得重新加入限时暂停动作' >&2
  exit 1
fi

echo 'ProxyGauge Kill Switch self-contained installation and recovery safety tests passed.'
