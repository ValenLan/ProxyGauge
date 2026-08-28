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

/bin/mkdir -p "$TEST_ROOT/etc/pf.anchors" "$TEST_ROOT/bin"
/usr/bin/printf '%s\n' 'set skip on lo0' > "$TEST_ROOT/etc/pf.conf"
/usr/bin/printf '%s\n' \
  '#!/bin/bash' \
  'case "$*" in' \
  '  "-s info") echo "Status: Enabled" ;;' \
  '  "-a proxygauge -sr") echo "block return out on en0 all" ;;' \
  '  "-E") echo "Token : 12345" ;;' \
  'esac' \
  'exit 0' > "$TEST_ROOT/bin/pfctl"
/bin/chmod 755 "$TEST_ROOT/bin/pfctl"

run_helper() {
  PROXYGAUGE_KILLSWITCH_TEST_ROOT="$TEST_ROOT" \
  PROXYGAUGE_KILLSWITCH_TEST_PFCTL="$TEST_ROOT/bin/pfctl" \
  PROXYGAUGE_KILLSWITCH_TEST_INTERFACES="${PROXYGAUGE_KILLSWITCH_TEST_INTERFACES:-en0 en1}" \
  /bin/bash "$HELPER" "$@"
}

run_persisted_helper() {
  PROXYGAUGE_KILLSWITCH_TEST_ROOT="$TEST_ROOT" \
  PROXYGAUGE_KILLSWITCH_TEST_PFCTL="$TEST_ROOT/bin/pfctl" \
  PROXYGAUGE_KILLSWITCH_TEST_INTERFACES="${PROXYGAUGE_KILLSWITCH_TEST_INTERFACES:-en0 en1}" \
  /bin/bash "$PERSIST_HELPER" "$@"
}

bootstrap_output=$(run_helper on)
/usr/bin/printf '%s\n' "$bootstrap_output" | /usr/bin/grep -Fq '规则已安装，当前保持关闭'
/usr/bin/printf '%s\n' "$bootstrap_output" | /usr/bin/grep -Fq 'Kill Switch 已开启'
/usr/bin/grep -Fq 'anchor "proxygauge"' "$TEST_ROOT/etc/pf.conf"
/usr/bin/grep -Fq 'phys = "{ en0 en1 }"' "$TEST_ROOT/etc/pf.anchors/proxygauge"
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

PROXYGAUGE_KILLSWITCH_TEST_INTERFACES='en2' run_persisted_helper restore >/dev/null
/usr/bin/grep -Fq 'phys = "{ en2 }"' "$TEST_ROOT/etc/pf.anchors/proxygauge"

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
/usr/bin/printf '%s\n' 'set skip on lo0' > "$TEST_ROOT/etc/pf.conf"

/usr/bin/printf '%s\n' 'block return out on en0 all' > "$TEST_ROOT/etc/pf.anchors/proxygauge"
anchor_hash_before=$(/usr/bin/shasum -a 256 "$TEST_ROOT/etc/pf.anchors/proxygauge" | /usr/bin/awk '{print $1}')
recovery_output=$(run_helper on)
/usr/bin/printf '%s\n' "$recovery_output" | /usr/bin/grep -Fq '已恢复原有 Kill Switch 规则入口'
/usr/bin/printf '%s\n' "$recovery_output" | /usr/bin/grep -Fq 'Kill Switch 已开启'
/usr/bin/grep -Fq 'anchor "proxygauge"' "$TEST_ROOT/etc/pf.conf"
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
