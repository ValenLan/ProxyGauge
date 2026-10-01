#!/bin/bash
# test-ne-fault-paths.sh — Kill Switch NE 故障路径与升级路径行为回归
#   · selection-failed / restore-failed 两分支 fail-closed（fault 后运行时 anchor 必含 block-all）
#   · fault 幂等：反复失败不叠加副作用（anchor 内容稳定、无状态清理、pf.conf/令牌/选择不漂移）
#   · 旧格式模板守卫：含 __NE_ENDPOINT_RULES__ 的模板在首次安装与 restore 刷新时均被拒绝
#   · 旧版 ne-endpoints 文件在 enable / restore / off 时被清理，且内容永不进入渲染产物
#   · 进入锁定 purge 恰好一次（停留在锁定不重复 purge，再次入锁仍恰好一次）
#   · NE→root 切换 purge 恰好一次（restore 路径与 on 路径均覆盖）
# 假 PID 池：52100/52101（Shadowrocket NE 提供者）、52200（root mihomo 核心）。
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
HELPER="$SCRIPT_DIR/proxygauge-killswitch"
TEST_ROOT=$(/usr/bin/mktemp -d /tmp/proxygauge-killswitch-test.XXXXXX)
trap '/bin/rm -rf "$TEST_ROOT"' EXIT
PERSIST_HELPER="$TEST_ROOT/Library/PrivilegedHelperTools/com.valenlan.proxygauge.killswitch"
PERSIST_PLIST="$TEST_ROOT/Library/LaunchDaemons/com.valenlan.proxygauge.killswitch.plist"
PERSIST_MARKER="$TEST_ROOT/var/db/proxygauge/enabled"
MANAGED_MARKER="$TEST_ROOT/var/db/proxygauge/managed-anchor.sha256"
NE_ENDPOINTS_FILE="$TEST_ROOT/var/db/proxygauge/ne-endpoints"
RUNTIME_STATE="$TEST_ROOT/var/run/proxygauge-killswitch.state"
SELECTION_RUNTIME="$TEST_ROOT/var/run/proxygauge-killswitch.selection"
PERSIST_TEMPLATE="$TEST_ROOT/Library/PrivilegedHelperTools/proxygauge.conf.template"
MAIN_CONF="$TEST_ROOT/etc/pf.conf"
ANCHOR_CONF="$TEST_ROOT/etc/pf.anchors/proxygauge"
TOKEN_FILE="$TEST_ROOT/var/run/proxygauge-killswitch.pf-token"
MOCK_ANCHOR="$TEST_ROOT/var/run/pfctl-state/anchor.conf"
PFCTL_LOG="$TEST_ROOT/var/run/pfctl.log"

# Static wiring gates (auxiliary only; every behavior below is exercised for real).
/usr/bin/grep -Fq '__NE_ENDPOINT_RULES__' "$HELPER"
/usr/bin/grep -Fq 'write_runtime_state fault selection-failed' "$HELPER"
/usr/bin/grep -Fq 'write_runtime_state fault restore-failed' "$HELPER"
/usr/bin/grep -Fq 'load_fail_closed_transition || true' "$HELPER"
/usr/bin/grep -Fq '/bin/rm -f "$NE_ENDPOINTS_FILE"' "$HELPER"

/bin/mkdir -p "$TEST_ROOT/etc/pf.anchors" "$TEST_ROOT/bin" "$TEST_ROOT/var/run"
/usr/bin/printf '%s\n' \
  'set skip on lo0' \
  'scrub-anchor "com.apple/*" all fragment reassemble' \
  'pass out quick all' \
  'anchor "com.apple/*"' > "$MAIN_CONF"
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

run_helper() {
  PROXYGAUGE_KILLSWITCH_TEST_ROOT="$TEST_ROOT" \
  PROXYGAUGE_KILLSWITCH_TEST_PFCTL="$TEST_ROOT/bin/pfctl" \
  PROXYGAUGE_KILLSWITCH_TEST_INTERFACES="${PROXYGAUGE_KILLSWITCH_TEST_INTERFACES:-en0 en1}" \
  PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES="${PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES-utun0}" \
  PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_PID="${PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_PID-52200}" \
  PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_DEVICE="${PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_DEVICE-${PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES:-utun0}}" \
  PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="${PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS-verge-mihomo:52200:0}" \
  /bin/bash "$HELPER" "$@"
}

run_persisted_helper() {
  PROXYGAUGE_KILLSWITCH_TEST_ROOT="$TEST_ROOT" \
  PROXYGAUGE_KILLSWITCH_TEST_PFCTL="$TEST_ROOT/bin/pfctl" \
  PROXYGAUGE_KILLSWITCH_TEST_INTERFACES="${PROXYGAUGE_KILLSWITCH_TEST_INTERFACES:-en0 en1}" \
  PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES="${PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES-utun0}" \
  PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_PID="${PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_PID-52200}" \
  PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_DEVICE="${PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_DEVICE-${PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES:-utun0}}" \
  PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="${PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS-verge-mihomo:52200:0}" \
  /bin/bash "$PERSIST_HELPER" "$@"
}

NE_RECORDS='Shadowrocket:52100:501:/Applications/Shadowrocket.app/Contents/MacOS/Shadowrocket:ne
MacPacketTunnel:52101:501:/Applications/Shadowrocket.app/Contents/PlugIns/MacPacketTunnel.appex/Contents/MacOS/MacPacketTunnel:ne'
NE_PATH='/Applications/Shadowrocket.app/Contents/MacOS/Shadowrocket'
ROOT_RECORDS='verge-mihomo:52200:0'
ROOT_PATH='/Applications/verge-mihomo'
# A non-numeric pid fails record validation inside resolve_core_selection.
BAD_RECORDS='mihomo:dead:0'

# Old-format persisted template (upgrade race): the retired NE endpoint token
# must fault the render guard, never leak literal placeholders.
OLD_TEMPLATE="$TEST_ROOT/var/run/old-format-template.conf"
/bin/cat > "$OLD_TEMPLATE" <<'OLD_FORMAT_TEMPLATE'
table <proxygauge_lan> persist { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/24, 239.0.0.0/8, 255.255.255.255/32, fc00::/7, fe80::/10, ff02::/16 }
trusted_tunnels = "{ __TUN_INTERFACES__ }"
pass quick on lo0 all keep state (if-bound)
pass out quick on $trusted_tunnels all keep state (if-bound)
pass out quick from any to <proxygauge_lan> keep state (if-bound)
pass out quick all user = 0 keep state (if-bound)
__NE_ENDPOINT_RULES__
block return out quick all
OLD_FORMAT_TEMPLATE

assert_single_purge_pass() {
  # Exactly one complement sweep: first/last IPv4 and IPv6 sentinels once each.
  [ "$(/usr/bin/grep -Fc -- '-k 0.0.0.0/0 -k 0.0.0.0/5' "$PFCTL_LOG")" -eq 1 ]
  [ "$(/usr/bin/grep -Fc -- '-k 0.0.0.0/0 -k 255.255.255.254/32' "$PFCTL_LOG")" -eq 1 ]
  [ "$(/usr/bin/grep -Fc -- '-k ::/0 -k ::/128' "$PFCTL_LOG")" -eq 1 ]
  [ "$(/usr/bin/grep -Fc -- '-k ::/0 -k ff80::/9' "$PFCTL_LOG")" -eq 1 ]
  # A full sweep covers the whole public complement, not a token subset.
  [ "$(/usr/bin/grep -c -- '^-k ' "$PFCTL_LOG")" -gt 200 ]
  ! /usr/bin/grep -Fq -- '-F states' "$PFCTL_LOG"
}

assert_no_purge() {
  ! /usr/bin/grep -q -- '^-k ' "$PFCTL_LOG"
}

# --- Old-format template guard: fresh install must be rejected -------------
if PROXYGAUGE_KILLSWITCH_TEST_TEMPLATE="$OLD_TEMPLATE" run_helper on >/dev/null 2>&1; then
  echo '含 __NE_ENDPOINT_RULES__ 的旧格式模板不得通过首次安装' >&2
  exit 1
fi
if /usr/bin/grep -Fq 'anchor "proxygauge"' "$MAIN_CONF"; then
  echo '被拒绝的旧格式模板不得注册 PF anchor' >&2
  exit 1
fi
[ ! -e "$ANCHOR_CONF" ]
[ ! -e "$MANAGED_MARKER" ]
[ ! -e "$PERSIST_MARKER" ]
[ ! -e "$MOCK_ANCHOR" ]
# The persisted template is now the old format; the next good `on` must heal it.
/usr/bin/grep -Fq '__NE_ENDPOINT_RULES__' "$PERSIST_TEMPLATE"

# --- Baseline install with a root core --------------------------------------
baseline_output=$(run_helper on)
/usr/bin/printf '%s\n' "$baseline_output" | /usr/bin/grep -Fq '规则已安装，当前保持关闭'
/usr/bin/printf '%s\n' "$baseline_output" | /usr/bin/grep -Fq 'Kill Switch 已开启'
/usr/bin/grep -Fq 'trusted_tunnels = "{ lo0 utun0 }"' "$ANCHOR_CONF"
/usr/bin/grep -Fq 'block return out quick all' "$ANCHOR_CONF"
[ "$(/usr/bin/grep -Fc 'keep state (if-bound)' "$ANCHOR_CONF")" -eq 4 ]
[ -x "$PERSIST_HELPER" ]
[ -r "$PERSIST_PLIST" ]
[ -r "$PERSIST_MARKER" ]
[ -r "$MANAGED_MARKER" ]
/usr/bin/grep -Fq '__BLOCK_ALL_RULE__' "$PERSIST_TEMPLATE"
! /usr/bin/grep -Fq '__NE_ENDPOINT_RULES__' "$PERSIST_TEMPLATE"
[ "$(/usr/bin/head -1 "$RUNTIME_STATE")" = "enabled" ]
[ "$(/usr/bin/sed -n '2p' "$SELECTION_RUNTIME")" = "$ROOT_PATH" ]

# --- NE monitoring: opening direction (root block-all -> NE) never purges ---
: > "$PFCTL_LOG"
ne_on_output=$(PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$NE_RECORDS" run_helper on)
/usr/bin/printf '%s\n' "$ne_on_output" | /usr/bin/grep -Fq 'Kill Switch 已开启'
[ "$(/usr/bin/sed -n '2p' "$SELECTION_RUNTIME")" = "$NE_PATH" ]
/usr/bin/grep -Fq 'trusted_tunnels = "{ lo0 utun0 }"' "$ANCHOR_CONF"
if /usr/bin/grep -Fq 'block return out quick all' "$ANCHOR_CONF"; then
  echo 'NE 监控态不得渲染 catch-all block' >&2
  exit 1
fi
if /usr/bin/grep -Fq 'block return out quick all' "$MOCK_ANCHOR"; then
  echo 'NE 监控态运行时 anchor 不得含 catch-all block' >&2
  exit 1
fi
[ "$(/usr/bin/grep -Fc 'keep state (if-bound)' "$ANCHOR_CONF")" -eq 4 ]
assert_no_purge

# --- Lockdown entry purges exactly once; staying in lockdown purges never ---
: > "$PFCTL_LOG"
PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$NE_RECORDS" \
PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES='' \
  run_persisted_helper restore >/dev/null
/usr/bin/grep -Fq 'trusted_tunnels = "{ lo0 }"' "$ANCHOR_CONF"
/usr/bin/grep -Fq 'block return out quick all' "$ANCHOR_CONF"
/usr/bin/grep -Fq 'block return out quick all' "$MOCK_ANCHOR"
/usr/bin/grep -Fq 'pass out quick from any to <proxygauge_lan> keep state (if-bound)' "$ANCHOR_CONF"
/usr/bin/grep -Fq 'pass out quick all user = 0 keep state (if-bound)' "$ANCHOR_CONF"
[ "$(/usr/bin/head -1 "$RUNTIME_STATE")" = "enabled" ]
assert_single_purge_pass

: > "$PFCTL_LOG"
PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$NE_RECORDS" \
PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES='' \
  run_persisted_helper restore >/dev/null
assert_no_purge
/usr/bin/grep -Fq 'block return out quick all' "$ANCHOR_CONF"

# --- Lockdown -> root switch (block stays on both sides) purges never -------
: > "$PFCTL_LOG"
PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$ROOT_RECORDS" \
PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES='' \
  run_persisted_helper restore >/dev/null
assert_no_purge
/usr/bin/grep -Fq 'block return out quick all' "$ANCHOR_CONF"
/usr/bin/grep -Fq 'trusted_tunnels = "{ lo0 }"' "$ANCHOR_CONF"
[ "$(/usr/bin/sed -n '2p' "$SELECTION_RUNTIME")" = "$ROOT_PATH" ]

# --- Back to NE monitoring (opening direction) purges never -----------------
: > "$PFCTL_LOG"
PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$NE_RECORDS" \
  run_persisted_helper restore >/dev/null
assert_no_purge
if /usr/bin/grep -Fq 'block return out quick all' "$ANCHOR_CONF"; then
  echo '隧道恢复后必须回到监控态（省略 catch-all block）' >&2
  exit 1
fi
/usr/bin/grep -Fq 'trusted_tunnels = "{ lo0 utun0 }"' "$ANCHOR_CONF"
[ "$(/usr/bin/sed -n '2p' "$SELECTION_RUNTIME")" = "$NE_PATH" ]

# --- Second lockdown entry purges exactly once again -------------------------
: > "$PFCTL_LOG"
PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$NE_RECORDS" \
PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES='' \
  run_persisted_helper restore >/dev/null
assert_single_purge_pass
/usr/bin/grep -Fq 'block return out quick all' "$ANCHOR_CONF"

: > "$PFCTL_LOG"
PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$NE_RECORDS" \
  run_persisted_helper restore >/dev/null
assert_no_purge
if /usr/bin/grep -Fq 'block return out quick all' "$ANCHOR_CONF"; then
  echo '锁定解除后必须回到监控态' >&2
  exit 1
fi

# --- NE monitoring -> root switch purges exactly once (restore path) --------
if /usr/bin/grep -Fq 'block return out quick all' "$ANCHOR_CONF"; then
  echo '切换前必须处于无 block 的监控态，否则无法证明 purge 由切换触发' >&2
  exit 1
fi
: > "$PFCTL_LOG"
PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$ROOT_RECORDS" \
  run_persisted_helper restore >/dev/null
assert_single_purge_pass
/usr/bin/grep -Fq 'block return out quick all' "$ANCHOR_CONF"
/usr/bin/grep -Fq 'block return out quick all' "$MOCK_ANCHOR"
/usr/bin/grep -Fq 'trusted_tunnels = "{ lo0 utun0 }"' "$ANCHOR_CONF"
[ "$(/usr/bin/sed -n '2p' "$SELECTION_RUNTIME")" = "$ROOT_PATH" ]
[ "$(/usr/bin/head -1 "$RUNTIME_STATE")" = "enabled" ]

# --- selection-failed branch fails closed -----------------------------------
PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$NE_RECORDS" \
  run_persisted_helper restore >/dev/null
if /usr/bin/grep -Fq 'block return out quick all' "$MOCK_ANCHOR"; then
  echo '故障注入前运行时 anchor 必须是无 block 的监控态' >&2
  exit 1
fi
if PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$BAD_RECORDS" \
  run_persisted_helper restore >/dev/null 2>&1; then
  echo 'restore 选择失败必须返回非零' >&2
  exit 1
fi
/usr/bin/grep -Eq '^fault[[:space:]]+selection-failed$' "$RUNTIME_STATE"
/usr/bin/grep -Fq 'block return out quick all' "$MOCK_ANCHOR"
/usr/bin/grep -Fq 'trusted_tunnels = "{ lo0 }"' "$MOCK_ANCHOR"
[ -r "$PERSIST_MARKER" ]

# --- selection-failed idempotency: repeated faults stack no side effects ----
/bin/cp "$MOCK_ANCHOR" "$TEST_ROOT/var/run/snap-anchor"
/bin/cp "$MAIN_CONF" "$TEST_ROOT/var/run/snap-pf.conf"
/bin/cp "$TOKEN_FILE" "$TEST_ROOT/var/run/snap-token"
: > "$PFCTL_LOG"
for round in 1 2 3; do
  if PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$BAD_RECORDS" \
    run_persisted_helper restore >/dev/null 2>&1; then
    echo '反复的 selection 故障不得意外成功' >&2
    exit 1
  fi
done
/usr/bin/cmp -s "$MOCK_ANCHOR" "$TEST_ROOT/var/run/snap-anchor"
[ "$(/usr/bin/grep -Fc 'block return out quick all' "$MOCK_ANCHOR")" -eq 1 ]
# Each faulted cycle re-arms the same fail-closed render exactly once.
[ "$(/usr/bin/grep -c -- '^-a proxygauge -f ' "$PFCTL_LOG")" -eq 3 ]
assert_no_purge
! /usr/bin/grep -Fxq -- '-E' "$PFCTL_LOG"
/usr/bin/cmp -s "$MAIN_CONF" "$TEST_ROOT/var/run/snap-pf.conf"
/usr/bin/cmp -s "$TOKEN_FILE" "$TEST_ROOT/var/run/snap-token"
/usr/bin/grep -Eq '^fault[[:space:]]+selection-failed$' "$RUNTIME_STATE"
[ "$(/usr/bin/sed -n '2p' "$SELECTION_RUNTIME")" = "$NE_PATH" ]
[ -r "$PERSIST_MARKER" ]

# Recovery from the fault back to the monitoring anchor must succeed.
PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$NE_RECORDS" \
  run_persisted_helper restore >/dev/null
[ "$(/usr/bin/head -1 "$RUNTIME_STATE")" = "enabled" ]
if /usr/bin/grep -Fq 'block return out quick all' "$MOCK_ANCHOR"; then
  echo '故障恢复后必须回到监控态' >&2
  exit 1
fi

# --- restore-failed branch fails closed --------------------------------------
if /usr/bin/grep -Fq 'block return out quick all' "$MOCK_ANCHOR"; then
  echo 'restore-failed 注入前运行时 anchor 必须是无 block 的监控态' >&2
  exit 1
fi
/bin/rm -f "$PERSIST_TEMPLATE"
if PROXYGAUGE_KILLSWITCH_TEST_TEMPLATE="$SCRIPT_DIR/../PF/proxygauge.conf.template" \
  PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$NE_RECORDS" \
  run_persisted_helper restore >/dev/null 2>&1; then
  echo 'restore 启用失败必须返回非零' >&2
  exit 1
fi
/usr/bin/grep -Eq '^fault[[:space:]]+restore-failed$' "$RUNTIME_STATE"
/usr/bin/grep -Fq 'block return out quick all' "$MOCK_ANCHOR"
/usr/bin/grep -Fq 'trusted_tunnels = "{ lo0 }"' "$MOCK_ANCHOR"
[ -r "$PERSIST_MARKER" ]

# --- restore-failed idempotency ----------------------------------------------
/bin/cp "$MOCK_ANCHOR" "$TEST_ROOT/var/run/snap-anchor2"
/bin/cp "$MAIN_CONF" "$TEST_ROOT/var/run/snap-pf2.conf"
/bin/cp "$TOKEN_FILE" "$TEST_ROOT/var/run/snap-token2"
: > "$PFCTL_LOG"
for round in 1 2 3; do
  if PROXYGAUGE_KILLSWITCH_TEST_TEMPLATE="$SCRIPT_DIR/../PF/proxygauge.conf.template" \
    PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$NE_RECORDS" \
    run_persisted_helper restore >/dev/null 2>&1; then
    echo '反复的 restore 故障不得意外成功' >&2
    exit 1
  fi
done
/usr/bin/cmp -s "$MOCK_ANCHOR" "$TEST_ROOT/var/run/snap-anchor2"
[ "$(/usr/bin/grep -Fc 'block return out quick all' "$MOCK_ANCHOR")" -eq 1 ]
[ "$(/usr/bin/grep -c -- '^-a proxygauge -f ' "$PFCTL_LOG")" -eq 3 ]
assert_no_purge
! /usr/bin/grep -Fxq -- '-E' "$PFCTL_LOG"
/usr/bin/cmp -s "$MAIN_CONF" "$TEST_ROOT/var/run/snap-pf2.conf"
/usr/bin/cmp -s "$TOKEN_FILE" "$TEST_ROOT/var/run/snap-token2"
/usr/bin/grep -Eq '^fault[[:space:]]+restore-failed$' "$RUNTIME_STATE"
[ -r "$PERSIST_MARKER" ]
[ ! -e "$PERSIST_TEMPLATE" ]

# --- Old-format persisted template guard on restore ---------------------------
# The guard must fault the refresh; the fail-closed transition render is also
# rejected, so the previously armed block-all stays loaded and no literal
# placeholder may leak into any rendered product.
/bin/cp "$OLD_TEMPLATE" "$PERSIST_TEMPLATE"
: > "$PFCTL_LOG"
if PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$NE_RECORDS" \
  run_persisted_helper restore >/dev/null 2>&1; then
  echo '旧格式持久化模板必须触发故障而非渲染字面占位符' >&2
  exit 1
fi
/usr/bin/grep -Eq '^fault[[:space:]]+restore-failed$' "$RUNTIME_STATE"
/usr/bin/grep -Fq 'block return out quick all' "$MOCK_ANCHOR"
[ "$(/usr/bin/grep -c -- '^-a proxygauge -f ' "$PFCTL_LOG")" -eq 0 ]
if /usr/bin/grep -qE '__TUN_INTERFACES__|__BLOCK_ALL_RULE__|__NE_ENDPOINT_RULES__' "$MOCK_ANCHOR"; then
  echo '运行时规则不得残留已退役的模板占位符' >&2
  exit 1
fi
if /usr/bin/grep -qE '__TUN_INTERFACES__|__BLOCK_ALL_RULE__|__NE_ENDPOINT_RULES__' "$ANCHOR_CONF"; then
  echo '磁盘 anchor 不得残留模板占位符' >&2
  exit 1
fi
if /usr/bin/grep -qE '__TUN_INTERFACES__|__BLOCK_ALL_RULE__|__NE_ENDPOINT_RULES__' "$MAIN_CONF"; then
  echo '系统 PF 配置不得残留模板占位符' >&2
  exit 1
fi

# A user re-enable heals the old-format persisted template (upgrade path).
heal_output=$(PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$NE_RECORDS" run_helper on)
/usr/bin/printf '%s\n' "$heal_output" | /usr/bin/grep -Fq 'Kill Switch 已开启'
! /usr/bin/grep -Fq '__NE_ENDPOINT_RULES__' "$PERSIST_TEMPLATE"
/usr/bin/grep -Fq '__BLOCK_ALL_RULE__' "$PERSIST_TEMPLATE"
if /usr/bin/grep -Fq 'block return out quick all' "$ANCHOR_CONF"; then
  echo '模板自愈后 NE 监控态必须恢复为无 block 渲染' >&2
  exit 1
fi
/usr/bin/grep -Fq 'trusted_tunnels = "{ lo0 utun0 }"' "$ANCHOR_CONF"
[ "$(/usr/bin/head -1 "$RUNTIME_STATE")" = "enabled" ]

# --- Legacy ne-endpoints leftovers are cleaned on enable ----------------------
/usr/bin/printf '%s\n' '203.0.113.9' > "$NE_ENDPOINTS_FILE"
: > "$PFCTL_LOG"
run_helper on AUTO >/dev/null
[ ! -e "$NE_ENDPOINTS_FILE" ]
if /usr/bin/grep -Fq '203.0.113.9' "$ANCHOR_CONF"; then
  echo '旧版端点钉扎内容不得进入渲染产物' >&2
  exit 1
fi
# NE monitoring -> root switch via `on` also purges exactly once.
assert_single_purge_pass
/usr/bin/grep -Fq 'block return out quick all' "$ANCHOR_CONF"
[ "$(/usr/bin/sed -n '2p' "$SELECTION_RUNTIME")" = "$ROOT_PATH" ]

# Cleaned again on a successful armed restore.
/usr/bin/printf '%s\n' '203.0.113.9' > "$NE_ENDPOINTS_FILE"
run_persisted_helper restore >/dev/null
[ ! -e "$NE_ENDPOINTS_FILE" ]

# Cleaned on off, together with the retired PF table flush.
/usr/bin/printf '%s\n' '203.0.113.9' > "$NE_ENDPOINTS_FILE"
: > "$PFCTL_LOG"
off_output=$(run_helper off)
/usr/bin/printf '%s\n' "$off_output" | /usr/bin/grep -Fq 'Kill Switch 已关闭'
[ ! -e "$NE_ENDPOINTS_FILE" ]
/usr/bin/grep -Fq -- '-t proxygauge_ne_endpoints -T flush' "$PFCTL_LOG"
[ ! -e "$PERSIST_MARKER" ]
[ "$(/usr/bin/head -1 "$RUNTIME_STATE")" = "disabled" ]

disabled_restore_output=$(run_persisted_helper restore)
/usr/bin/printf '%s\n' "$disabled_restore_output" | /usr/bin/grep -Fq '保持关闭'
[ ! -e "$TOKEN_FILE" ]

echo 'ProxyGauge Kill Switch NE fault-path and upgrade-path safety tests passed.'
