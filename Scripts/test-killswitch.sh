#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
HELPER="$SCRIPT_DIR/proxygauge-killswitch"
TEST_ROOT=$(/usr/bin/mktemp -d /tmp/proxygauge-killswitch-test.XXXXXX)
trap '/bin/rm -rf "$TEST_ROOT"' EXIT
PERSIST_HELPER="$TEST_ROOT/Library/PrivilegedHelperTools/com.valenlan.proxygauge.killswitch"
PERSIST_PLIST="$TEST_ROOT/Library/LaunchDaemons/com.valenlan.proxygauge.killswitch.plist"
PERSIST_MARKER="$TEST_ROOT/var/db/proxygauge/enabled"
LEGACY_PERSIST_MARKER="$TEST_ROOT/var/db/cloudcheck/enabled"

if /usr/bin/grep -Fq 'LEGACY_HELPER' "$HELPER"; then
  echo 'Root helper must not execute a user-owned legacy helper.' >&2
  exit 1
fi

/bin/mkdir -p "$TEST_ROOT/etc/pf.anchors" "$TEST_ROOT/bin"
/usr/bin/printf '%s\n' 'set skip on lo0' > "$TEST_ROOT/etc/pf.conf"
/usr/bin/printf '%s\n' \
  '#!/bin/bash' \
  'case "$*" in' \
  '  "-s info") echo "Status: Enabled" ;;' \
  '  "-a proxygauge -sr") echo "block return out on en0 all" ;;' \
  '  "-a cloudcheck -sr") echo "block return out on en0 all" ;;' \
  '  "-a killswitch -sr") echo "block return out on en0 all" ;;' \
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

/bin/mkdir -p "$(/usr/bin/dirname "$LEGACY_PERSIST_MARKER")"
/usr/bin/printf '%s\n' enabled > "$LEGACY_PERSIST_MARKER"
bootstrap_output=$(run_helper on)
/usr/bin/printf '%s\n' "$bootstrap_output" | /usr/bin/grep -Fq '规则已安装，当前保持关闭'
/usr/bin/printf '%s\n' "$bootstrap_output" | /usr/bin/grep -Fq 'Kill Switch 已开启'
/usr/bin/grep -Fq 'anchor "proxygauge"' "$TEST_ROOT/etc/pf.conf"
/usr/bin/grep -Fq 'phys = "{ en0 en1 }"' "$TEST_ROOT/etc/pf.anchors/proxygauge"
if /usr/bin/grep -Eq '__VPS_IP__|cloudlink_guard_(lan|vps)' "$TEST_ROOT/etc/pf.anchors/proxygauge"; then
  echo '内置规则不得依赖服务器 IP 参数' >&2
  exit 1
fi
[ -r "$TEST_ROOT/etc/pf.conf.proxygauge.bak" ]
[ -s "$TEST_ROOT/var/run/proxygauge-killswitch.pf-token" ]
[ -x "$PERSIST_HELPER" ]
[ -r "$PERSIST_PLIST" ]
[ -r "$PERSIST_MARKER" ]
[ ! -e "$LEGACY_PERSIST_MARKER" ]
/usr/bin/plutil -lint "$PERSIST_PLIST" >/dev/null
/usr/bin/grep -Fq '<string>restore</string>' "$PERSIST_PLIST"

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
cloudcheck_output=$(run_helper on)
/usr/bin/printf '%s\n' "$cloudcheck_output" | /usr/bin/grep -Fq 'Kill Switch 已开启'
/usr/bin/grep -Fq 'anchor "cloudcheck"' "$TEST_ROOT/etc/pf.conf"
[ -s "$TEST_ROOT/var/run/cloudcheck-killswitch.pf-token" ]
/bin/mkdir -p "$(/usr/bin/dirname "$LEGACY_PERSIST_MARKER")"
/usr/bin/printf '%s\n' enabled > "$LEGACY_PERSIST_MARKER"
run_helper off >/dev/null
[ ! -e "$LEGACY_PERSIST_MARKER" ]
[ ! -e "$TEST_ROOT/var/run/cloudcheck-killswitch.pf-token" ]
/bin/rm -f "$TEST_ROOT/etc/pf.anchors/cloudcheck"
/usr/bin/printf '%s\n' 'set skip on lo0' > "$TEST_ROOT/etc/pf.conf"

/usr/bin/printf '%s\n' 'block return out on en0 all' > "$TEST_ROOT/etc/pf.anchors/killswitch"
anchor_hash_before=$(/usr/bin/shasum -a 256 "$TEST_ROOT/etc/pf.anchors/killswitch" | /usr/bin/awk '{print $1}')
recovery_output=$(run_helper on)
/usr/bin/printf '%s\n' "$recovery_output" | /usr/bin/grep -Fq '已恢复原有 Kill Switch 规则入口'
/usr/bin/printf '%s\n' "$recovery_output" | /usr/bin/grep -Fq 'Kill Switch 已开启'
/usr/bin/grep -Fq 'anchor "killswitch"' "$TEST_ROOT/etc/pf.conf"
[ -r "$TEST_ROOT/etc/pf.conf.proxygauge-entry.bak" ]
[ -s "$TEST_ROOT/var/run/proxy-tools-killswitch.pf-token" ]
anchor_hash_after=$(/usr/bin/shasum -a 256 "$TEST_ROOT/etc/pf.anchors/killswitch" | /usr/bin/awk '{print $1}')
[ "$anchor_hash_before" = "$anchor_hash_after" ]

if run_helper install >/dev/null 2>&1; then
  echo '旧版 killswitch 存在时不得自动叠加新 anchor' >&2
  exit 1
fi

/usr/bin/printf '%s\n' 'set skip on lo0' > "$TEST_ROOT/etc/pf.conf"
/usr/bin/printf '%s\n' 'block return out on en0 all' > "$TEST_ROOT/etc/pf.anchors/cloudroute"
if run_helper on >/dev/null 2>&1; then
  echo '多套未注册规则存在时不得猜测启用目标' >&2
  exit 1
fi

/bin/rm -f "$TEST_ROOT/etc/pf.anchors/killswitch" "$TEST_ROOT/etc/pf.anchors/cloudroute"
fresh_output=$(run_helper on)
/usr/bin/printf '%s\n' "$fresh_output" | /usr/bin/grep -Fq '规则已安装，当前保持关闭'
/usr/bin/printf '%s\n' "$fresh_output" | /usr/bin/grep -Fq 'Kill Switch 已开启'

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
disabled_restore_output=$(run_persisted_helper restore)
/usr/bin/printf '%s\n' "$disabled_restore_output" | /usr/bin/grep -Fq '保持关闭'
[ ! -e "$TEST_ROOT/var/run/proxygauge-killswitch.pf-token" ]

if run_helper install unexpected >/dev/null 2>&1; then
  echo '内置安装不得接收用户配置参数' >&2
  exit 1
fi

echo 'ProxyGauge Kill Switch self-contained installation and recovery safety tests passed.'
