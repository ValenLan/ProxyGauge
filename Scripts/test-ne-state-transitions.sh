#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
HELPER="$SCRIPT_DIR/proxygauge-killswitch"
TEST_ROOT=$(/usr/bin/mktemp -d /tmp/proxygauge-killswitch-test.XXXXXX)
trap '/bin/rm -rf "$TEST_ROOT"' EXIT
PERSIST_HELPER="$TEST_ROOT/Library/PrivilegedHelperTools/com.valenlan.proxygauge.killswitch"
PERSIST_MARKER="$TEST_ROOT/var/db/proxygauge/enabled"
SELECTION_FILE="$TEST_ROOT/var/db/proxygauge/selection"
RUNTIME_STATE="$TEST_ROOT/var/run/proxygauge-killswitch.state"
SELECTION_RUNTIME="$TEST_ROOT/var/run/proxygauge-killswitch.selection"
ANCHOR_CONF="$TEST_ROOT/etc/pf.anchors/proxygauge"
MOCK_ANCHOR="$TEST_ROOT/var/run/pfctl-state/anchor.conf"
PFCTL_LOG="$TEST_ROOT/var/run/pfctl.log"

# Static gates only back up the behavioural checks below: the NE monitor /
# lockdown state machine, its lockdown-entry state purge and the fail-closed
# restore fault paths must stay in place for these transitions to be safe.
/usr/bin/grep -Fq 'NE_LOCKDOWN=1' "$HELPER"
/usr/bin/grep -Fq 'elif [ "${SELECTED_NE:-0}" = 1 ] && [ "${NE_LOCKDOWN:-0}" = 0 ]; then' "$HELPER"
/usr/bin/grep -Fq 'if [ "$prior_block" -eq 0 ] && [ "$final_block" -eq 1 ]; then' "$HELPER"
/usr/bin/grep -Fq 'write_runtime_state fault selection-failed' "$HELPER"
/usr/bin/grep -Fq 'write_runtime_state fault restore-failed' "$HELPER"

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
  '  source="$state_dir/main.conf"' \
  '  [ -r "$source" ] || source="$PROXYGAUGE_KILLSWITCH_TEST_ROOT/etc/pf.conf"' \
  '  /usr/bin/awk '\''/^[[:space:]]*(scrub-anchor|anchor|block|pass|match|antispoof)([[:space:]]|$)/ { sub(/^[[:space:]]*/, ""); print }'\'' "$source"' \
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

SR_PATH='/Applications/Shadowrocket.app/Contents/MacOS/Shadowrocket'
MPT_PATH='/Applications/Shadowrocket.app/Contents/PlugIns/MacPacketTunnel.appex/Contents/MacOS/MacPacketTunnel'
NE_RECORDS="Shadowrocket:51001:501:$SR_PATH:ne
MacPacketTunnel:51002:501:$MPT_PATH:ne"
MPT_ONLY_RECORDS="MacPacketTunnel:51002:501:$MPT_PATH:ne"
SR_ONLY_RECORDS="Shadowrocket:51001:501:$SR_PATH:ne"
ROOT_RECORDS='verge-mihomo:51003:0'
BOTH_RECORDS="verge-mihomo:51003:0
$NE_RECORDS"

run_helper() {
  PROXYGAUGE_KILLSWITCH_TEST_ROOT="$TEST_ROOT" \
  PROXYGAUGE_KILLSWITCH_TEST_PFCTL="$TEST_ROOT/bin/pfctl" \
  PROXYGAUGE_KILLSWITCH_TEST_INTERFACES="${PROXYGAUGE_KILLSWITCH_TEST_INTERFACES:-en0 en1}" \
  PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES="${PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES-utun0}" \
  PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_PID="${PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_PID-51003}" \
  PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_DEVICE="${PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_DEVICE-utun0}" \
  PROXYGAUGE_KILLSWITCH_TEST_STATE_ADDRESSES="${PROXYGAUGE_KILLSWITCH_TEST_STATE_ADDRESSES:-192.0.2.10 2001:db8::10}" \
  PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="${PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS-$NE_RECORDS}" \
  PROXYGAUGE_KILLSWITCH_TEST_PS_OUTPUT="${PROXYGAUGE_KILLSWITCH_TEST_PS_OUTPUT-}" \
  /bin/bash "$HELPER" "$@"
}

run_persisted_helper() {
  PROXYGAUGE_KILLSWITCH_TEST_ROOT="$TEST_ROOT" \
  PROXYGAUGE_KILLSWITCH_TEST_PFCTL="$TEST_ROOT/bin/pfctl" \
  PROXYGAUGE_KILLSWITCH_TEST_INTERFACES="${PROXYGAUGE_KILLSWITCH_TEST_INTERFACES:-en0 en1}" \
  PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES="${PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES-utun0}" \
  PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_PID="${PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_PID-51003}" \
  PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_DEVICE="${PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_DEVICE-utun0}" \
  PROXYGAUGE_KILLSWITCH_TEST_STATE_ADDRESSES="${PROXYGAUGE_KILLSWITCH_TEST_STATE_ADDRESSES:-192.0.2.10 2001:db8::10}" \
  PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="${PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS-$NE_RECORDS}" \
  PROXYGAUGE_KILLSWITCH_TEST_PS_OUTPUT="${PROXYGAUGE_KILLSWITCH_TEST_PS_OUTPUT-}" \
  /bin/bash "$PERSIST_HELPER" "$@"
}

assert_monitoring() {
  # NE provider alive with a public routed utun: pass rules stay, no catch-all
  # block, runtime state enabled, qualified tunnels recorded, PF in sync.
  /usr/bin/grep -Fq 'trusted_tunnels = "{ lo0 utun0 }"' "$ANCHOR_CONF"
  if /usr/bin/grep -Fq 'block return out quick all' "$ANCHOR_CONF"; then
    echo "$1: NE 监控态不得渲染 catch-all block" >&2
    exit 1
  fi
  [ "$(/usr/bin/head -1 "$RUNTIME_STATE")" = "enabled" ]
  [ "$(/usr/bin/sed -n '4p' "$SELECTION_RUNTIME")" = 'lo0 utun0' ]
  /usr/bin/cmp -s "$ANCHOR_CONF" "$MOCK_ANCHOR"
  if /usr/bin/grep -qE '__TUN_INTERFACES__|__BLOCK_ALL_RULE__|__NE_ENDPOINT_RULES__' "$ANCHOR_CONF"; then
    echo "$1: 渲染产物不得残留模板占位符" >&2
    exit 1
  fi
}

assert_lockdown() {
  # Provider or public utun gone while armed: catch-all block rendered, only
  # lo0 trusted, runtime state still enabled, PF in sync.
  /usr/bin/grep -Fq 'trusted_tunnels = "{ lo0 }"' "$ANCHOR_CONF"
  /usr/bin/grep -Fq 'block return out quick all' "$ANCHOR_CONF"
  [ "$(/usr/bin/head -1 "$RUNTIME_STATE")" = "enabled" ]
  [ "$(/usr/bin/sed -n '4p' "$SELECTION_RUNTIME")" = 'lo0' ]
  /usr/bin/cmp -s "$ANCHOR_CONF" "$MOCK_ANCHOR"
  if /usr/bin/grep -qE '__TUN_INTERFACES__|__BLOCK_ALL_RULE__|__NE_ENDPOINT_RULES__' "$ANCHOR_CONF"; then
    echo "$1: 渲染产物不得残留模板占位符" >&2
    exit 1
  fi
}

assert_lockdown_entry_effects() {
  # Entering lockdown from a block-less monitoring anchor reloads the anchor
  # exactly once and purges physical public states exactly once.
  /usr/bin/grep -Fq -- '-k 0.0.0.0/0 -k ' "$PFCTL_LOG"
  /usr/bin/grep -Fq -- '-k ::/0 -k ' "$PFCTL_LOG"
  ! /usr/bin/grep -Fq -- '-F states' "$PFCTL_LOG"
  [ "$(/usr/bin/grep -c -- '^-a proxygauge -f ' "$PFCTL_LOG")" -eq 1 ]
}

assert_steady_effects() {
  # Any flip that does not enter lockdown must never purge public states.
  ! /usr/bin/grep -q -- '^-k ' "$PFCTL_LOG"
  [ "$(/usr/bin/grep -c -- '^-a proxygauge -f ' "$PFCTL_LOG")" -eq 1 ]
}

# --- restore before the Kill Switch was ever armed must be a no-op -----------
# off installs the LaunchDaemon helper without ever arming the Kill Switch.
run_helper off >/dev/null
[ ! -e "$PERSIST_MARKER" ]
[ "$(/usr/bin/head -1 "$RUNTIME_STATE")" = "disabled" ]
: > "$PFCTL_LOG"
never_armed_output=$(run_persisted_helper restore)
/usr/bin/printf '%s\n' "$never_armed_output" | /usr/bin/grep -Fq '保持关闭'
[ "$(/usr/bin/head -1 "$RUNTIME_STATE")" = "disabled" ]
[ ! -e "$ANCHOR_CONF" ]
[ ! -s "$MOCK_ANCHOR" ]
! /usr/bin/grep -q -- '^-a proxygauge -f ' "$PFCTL_LOG"

# --- Arm in AUTO with a live NE provider: monitoring state -------------------
ne_on_output=$(run_helper on AUTO)
/usr/bin/printf '%s\n' "$ne_on_output" | /usr/bin/grep -Fq 'Kill Switch 已开启'
assert_monitoring 'AUTO 开启'
[ "$(/usr/bin/sed -n '1p' "$SELECTION_RUNTIME")" = 'AUTO' ]
[ "$(/usr/bin/sed -n '2p' "$SELECTION_RUNTIME")" = "$SR_PATH" ]
[ "$(/usr/bin/head -1 "$SELECTION_FILE")" = 'AUTO' ]

# --- Multi-round monitor -> lockdown -> monitor flips (half-dead utun) -------
# The provider stays alive; only the public routed utun comes and goes.
for round in 1 2 3; do
  : > "$PFCTL_LOG"
  PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES='' \
    run_persisted_helper restore >/dev/null
  assert_lockdown "第 $round 轮 utun 消失"
  assert_lockdown_entry_effects
  # Steady lockdown: the next cycle neither purges nor re-renders differently.
  steady_hash=$(/usr/bin/shasum -a 256 "$ANCHOR_CONF" | /usr/bin/awk '{print $1}')
  : > "$PFCTL_LOG"
  PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES='' \
    run_persisted_helper restore >/dev/null
  assert_lockdown "第 $round 轮锁定稳态"
  assert_steady_effects
  [ "$steady_hash" = "$(/usr/bin/shasum -a 256 "$ANCHOR_CONF" | /usr/bin/awk '{print $1}')" ]
  # Tunnel recovery lifts the lockdown without touching public states.
  : > "$PFCTL_LOG"
  run_persisted_helper restore >/dev/null
  assert_monitoring "第 $round 轮 utun 恢复"
  assert_steady_effects
done

# --- NE process death and rebirth in AUTO ------------------------------------
# Partial death (app gone, packet tunnel alive) is still one live provider.
: > "$PFCTL_LOG"
PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$MPT_ONLY_RECORDS" \
  run_persisted_helper restore >/dev/null
assert_monitoring 'NE 部分存活'
assert_steady_effects
[ "$(/usr/bin/sed -n '2p' "$SELECTION_RUNTIME")" = "$MPT_PATH" ]
# Full death locks the machine down on the next restore cycle.
: > "$PFCTL_LOG"
PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS='' \
  run_persisted_helper restore >/dev/null
assert_lockdown 'NE 进程全部死亡'
assert_lockdown_entry_effects
# Rebirth returns to monitoring automatically.
: > "$PFCTL_LOG"
run_persisted_helper restore >/dev/null
assert_monitoring 'NE 进程重生'
assert_steady_effects
[ "$(/usr/bin/sed -n '2p' "$SELECTION_RUNTIME")" = "$SR_PATH" ]

# --- NE restart jitter: rapid consecutive restore calls ----------------------
# Tunnel flapping twice, then process flapping twice, back to back.
: > "$PFCTL_LOG"
PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES='' run_persisted_helper restore >/dev/null
assert_lockdown '抖动 1：隧道断开'
assert_lockdown_entry_effects
: > "$PFCTL_LOG"
run_persisted_helper restore >/dev/null
assert_monitoring '抖动 1：隧道恢复'
assert_steady_effects
: > "$PFCTL_LOG"
PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES='' run_persisted_helper restore >/dev/null
assert_lockdown '抖动 2：隧道断开'
assert_lockdown_entry_effects
: > "$PFCTL_LOG"
run_persisted_helper restore >/dev/null
assert_monitoring '抖动 2：隧道恢复'
assert_steady_effects
# A duplicate restore with unchanged input is idempotent: one reload, no purge.
jitter_hash=$(/usr/bin/shasum -a 256 "$ANCHOR_CONF" | /usr/bin/awk '{print $1}')
: > "$PFCTL_LOG"
run_persisted_helper restore >/dev/null
assert_monitoring '抖动：重复 restore 幂等'
assert_steady_effects
[ "$jitter_hash" = "$(/usr/bin/shasum -a 256 "$ANCHOR_CONF" | /usr/bin/awk '{print $1}')" ]
# Process dying while already in lockdown keeps the block without re-purging.
: > "$PFCTL_LOG"
PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES='' run_persisted_helper restore >/dev/null
assert_lockdown '抖动 3：隧道先断'
assert_lockdown_entry_effects
: > "$PFCTL_LOG"
PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES='' \
PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS='' \
  run_persisted_helper restore >/dev/null
assert_lockdown '抖动 3：锁定中进程死亡'
assert_steady_effects
# Provider rebirth without a tunnel stays locked down; tunnel return unlocks.
: > "$PFCTL_LOG"
PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES='' \
  run_persisted_helper restore >/dev/null
assert_lockdown '抖动 3：无隧道重生仍锁定'
assert_steady_effects
: > "$PFCTL_LOG"
run_persisted_helper restore >/dev/null
assert_monitoring '抖动 3：隧道恢复解锁'
assert_steady_effects

# --- Disarmed restore must stay a no-op even with a healthy NE ---------------
run_helper off >/dev/null
[ ! -e "$PERSIST_MARKER" ]
anchor_hash_while_off=$(/usr/bin/shasum -a 256 "$ANCHOR_CONF" | /usr/bin/awk '{print $1}')
: > "$PFCTL_LOG"
disarmed_restore=$(run_persisted_helper restore)
/usr/bin/printf '%s\n' "$disarmed_restore" | /usr/bin/grep -Fq '保持关闭'
[ "$(/usr/bin/head -1 "$RUNTIME_STATE")" = "disabled" ]
[ ! -s "$MOCK_ANCHOR" ]
! /usr/bin/grep -q -- '^-a proxygauge -f ' "$PFCTL_LOG"
[ "$anchor_hash_while_off" = "$(/usr/bin/shasum -a 256 "$ANCHOR_CONF" | /usr/bin/awk '{print $1}')" ]
: > "$PFCTL_LOG"
disarmed_ne_alive=$(PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$NE_RECORDS" \
  run_persisted_helper restore)
/usr/bin/printf '%s\n' "$disarmed_ne_alive" | /usr/bin/grep -Fq '保持关闭'
[ "$(/usr/bin/head -1 "$RUNTIME_STATE")" = "disabled" ]
! /usr/bin/grep -q -- '^-a proxygauge -f ' "$PFCTL_LOG"

# --- Manual pin: same state machine, but tracking the exact pinned process ---
pin_on_output=$(run_helper on "$MPT_PATH")
/usr/bin/printf '%s\n' "$pin_on_output" | /usr/bin/grep -Fq 'Kill Switch 已开启'
assert_monitoring '手动钉选开启'
[ "$(/usr/bin/sed -n '1p' "$SELECTION_RUNTIME")" = "$MPT_PATH" ]
[ "$(/usr/bin/sed -n '2p' "$SELECTION_RUNTIME")" = "$MPT_PATH" ]
[ "$(/usr/bin/head -1 "$SELECTION_FILE")" = "$MPT_PATH" ]
: > "$PFCTL_LOG"
PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES='' run_persisted_helper restore >/dev/null
assert_lockdown '钉选态 utun 消失'
assert_lockdown_entry_effects
[ "$(/usr/bin/sed -n '1p' "$SELECTION_RUNTIME")" = "$MPT_PATH" ]
: > "$PFCTL_LOG"
run_persisted_helper restore >/dev/null
assert_monitoring '钉选态 utun 恢复'
assert_steady_effects
# The provider's other process surviving does not keep a pinned dead process
# monitored: the pin tracks the exact executable and locks down.
: > "$PFCTL_LOG"
PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$SR_ONLY_RECORDS" \
  run_persisted_helper restore >/dev/null
assert_lockdown '钉选进程死亡（同伴存活）'
assert_lockdown_entry_effects
: > "$PFCTL_LOG"
PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$NE_RECORDS" \
  run_persisted_helper restore >/dev/null
assert_monitoring '钉选进程重生'
assert_steady_effects
[ "$(/usr/bin/head -1 "$SELECTION_FILE")" = "$MPT_PATH" ]

# --- AUTO handover between a root core and the NE provider --------------------
# A root core render keeps the catch-all block in every state; losing it to a
# live NE provider flips back to monitoring, and its return flips to blocked.
root_on_output=$(PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$ROOT_RECORDS" run_helper on AUTO)
/usr/bin/printf '%s\n' "$root_on_output" | /usr/bin/grep -Fq 'Kill Switch 已开启'
/usr/bin/grep -Fq 'block return out quick all' "$ANCHOR_CONF"
/usr/bin/grep -Fq 'trusted_tunnels = "{ lo0 utun0 }"' "$ANCHOR_CONF"
[ "$(/usr/bin/sed -n '2p' "$SELECTION_RUNTIME")" = '/Applications/verge-mihomo' ]
[ "$(/usr/bin/head -1 "$RUNTIME_STATE")" = "enabled" ]
: > "$PFCTL_LOG"
run_persisted_helper restore >/dev/null
assert_monitoring 'root 核心死亡后 NE 接管'
assert_steady_effects
: > "$PFCTL_LOG"
PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$BOTH_RECORDS" \
  run_persisted_helper restore >/dev/null
/usr/bin/grep -Fq 'block return out quick all' "$ANCHOR_CONF"
[ "$(/usr/bin/sed -n '2p' "$SELECTION_RUNTIME")" = '/Applications/verge-mihomo' ]
[ "$(/usr/bin/head -1 "$RUNTIME_STATE")" = "enabled" ]
assert_lockdown_entry_effects

echo 'ProxyGauge NE monitor/lockdown state transition tests passed.'
