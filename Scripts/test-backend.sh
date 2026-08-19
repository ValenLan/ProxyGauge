#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
BACKEND="$SCRIPT_DIR/cloudlink-guard-backend.sh"
TEMP_DIR=$(/usr/bin/mktemp -d /tmp/cloudlink-guard-backend-test.XXXXXX)
trap '/bin/rm -rf "$TEMP_DIR"' EXIT

assert_kill_state() {
  local message expected actual
  message="$1"
  expected="$2"

  /usr/bin/printf '%s\n__STATUS__=0\n' "$message" > "$TEMP_DIR/admin-result"
  actual=$(CLOUDLINK_GUARD_ADMIN_RESULT="$TEMP_DIR/admin-result" \
    CLOUDLINK_GUARD_KILL_TOKEN="$TEMP_DIR/token" \
    /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "kill" { print $2 "\t" $3 }')

  if [ "$actual" != "$expected" ]; then
    echo "状态解析失败: $message => $actual (期望 $expected)" >&2
    exit 1
  fi
}

assert_kill_state 'Kill Switch 已开启' $'已开启\tok'
assert_kill_state 'Kill Switch: Enabled' $'已开启\tok'
assert_kill_state 'Kill Switch 已关闭' $'已关闭\twarning'
assert_kill_state 'Kill Switch: Disabled' $'已关闭\twarning'

assert_entry_state() {
  local system_active tun_active expected actual
  system_active="$1"
  tun_active="$2"
  expected="$3"

  actual=$(CLOUDLINK_GUARD_SYSTEM_PROXY_ACTIVE="$system_active" \
    CLOUDLINK_GUARD_TUN_ACTIVE="$tun_active" \
    CLOUDLINK_GUARD_ADMIN_RESULT="$TEMP_DIR/missing-admin-result" \
    CLOUDLINK_GUARD_KILL_TOKEN="$TEMP_DIR/missing-token" \
    /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "entry" { print $2 "\t" $3 "\t" $4 "\t" $5 }')

  if [ "$actual" != "$expected" ]; then
    echo "入口状态解析失败: system=$system_active tun=$tun_active => $actual (期望 $expected)" >&2
    exit 1
  fi
}

assert_entry_state 1 0 $'已启用\tok\t系统代理\tarrow.left.arrow.right'
assert_entry_state 0 1 $'已接管\tok\tTUN 路由\tarrow.triangle.2.circlepath'
assert_entry_state 1 1 $'同时开启\twarning\t双重入口\texclamationmark.triangle.fill'
assert_entry_state 0 0 $'未启用\tidle\t流量入口\tarrow.triangle.branch'

/usr/bin/printf '%s\n' \
  'mixed-port: 7897' \
  'secret: test-must-not-be-returned' > "$TEMP_DIR/clash-verge.yaml"
/usr/bin/printf '%s\n' \
  '{"mixed-port":7788,"secret":"test-must-not-be-returned"}' \
  > "$TEMP_DIR/mihomo-configs.json"
/usr/bin/printf '%s\n' 'CLOUDLINK_GUARD_MIXED="127.0.0.1:7000"' > "$TEMP_DIR/cloudlink-guard-config"

saved_endpoint_probe=$(CLOUDLINK_GUARD_CONFIG="$TEMP_DIR/cloudlink-guard-config" \
  CLOUDLINK_GUARD_MIXED=127.0.0.1:7898 \
  CLOUDLINK_GUARD_SYSTEM_PROXY_ACTIVE=0 \
  CLOUDLINK_GUARD_TUN_ACTIVE=0 \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "port" { print $2 }')
case "$saved_endpoint_probe" in
  '7898 监听中'|'7898 未监听') ;;
  *) echo "App 保存的入口没有覆盖配置文件: $saved_endpoint_probe" >&2; exit 1 ;;
esac

assert_discovery() {
  local expected output
  expected="$1"
  shift
  output=$(env \
    CLOUDLINK_GUARD_CONFIG=/dev/null \
    CLOUDLINK_GUARD_DISCOVERY_SOCKET="$TEMP_DIR/missing.sock" \
    CLOUDLINK_GUARD_SYSTEM_PROXY_ACTIVE=0 \
    CLOUDLINK_GUARD_TUN_ACTIVE=0 \
    "$@" /bin/bash "$BACKEND" discover)

  /usr/bin/printf '%s\n' "$output" | /usr/bin/grep -Fq "$expected"
  if /usr/bin/printf '%s\n' "$output" | /usr/bin/grep -Fq 'test-must-not-be-returned'; then
    echo '自动检测不得输出配置中的其他字段' >&2
    exit 1
  fi
}

assert_discovery $'endpoint\t127.0.0.1:7897' \
  CLOUDLINK_GUARD_DISCOVERY_CLIENT='Clash Verge Rev' \
  CLOUDLINK_GUARD_DISCOVERY_CONFIG="$TEMP_DIR/clash-verge.yaml" \
  CLOUDLINK_GUARD_DISCOVERY_PORT_ACTIVE=1

assert_discovery $'source\tMihomo 运行状态' \
  CLOUDLINK_GUARD_DISCOVERY_SOCKET_JSON="$TEMP_DIR/mihomo-configs.json" \
  CLOUDLINK_GUARD_DISCOVERY_CONFIG="$TEMP_DIR/missing.yaml" \
  CLOUDLINK_GUARD_DISCOVERY_PORT_ACTIVE=1

system_discovery=$(CLOUDLINK_GUARD_CONFIG=/dev/null \
  CLOUDLINK_GUARD_DISCOVERY_SYSTEM_PROXY=127.0.0.1:7891 \
  CLOUDLINK_GUARD_DISCOVERY_CONFIG="$TEMP_DIR/missing.yaml" \
  CLOUDLINK_GUARD_DISCOVERY_SOCKET="$TEMP_DIR/missing.sock" \
  CLOUDLINK_GUARD_DISCOVERY_PORT_ACTIVE=1 \
  CLOUDLINK_GUARD_SYSTEM_PROXY_ACTIVE=1 \
  CLOUDLINK_GUARD_TUN_ACTIVE=0 \
  /bin/bash "$BACKEND" discover)
/usr/bin/printf '%s\n' "$system_discovery" | /usr/bin/grep -Fq $'source\tmacOS 系统代理'
/usr/bin/printf '%s\n' "$system_discovery" | /usr/bin/grep -Fq $'mode\t系统代理'

missing_discovery=$(CLOUDLINK_GUARD_CONFIG=/dev/null \
  CLOUDLINK_GUARD_DISCOVERY_CONFIG="$TEMP_DIR/missing.yaml" \
  CLOUDLINK_GUARD_DISCOVERY_SOCKET="$TEMP_DIR/missing.sock" \
  CLOUDLINK_GUARD_DISCOVERY_PORT_ACTIVE=0 \
  CLOUDLINK_GUARD_SYSTEM_PROXY_ACTIVE=0 \
  CLOUDLINK_GUARD_TUN_ACTIVE=0 \
  /bin/bash "$BACKEND" discover)
/usr/bin/printf '%s\n' "$missing_discovery" | /usr/bin/grep -Fq $'found\t0'
/usr/bin/printf '%s\n' "$missing_discovery" | /usr/bin/grep -Fq $'source\t手动设置'

/usr/bin/printf '%s\n__STATUS__=0\n' 'Kill Switch: Enabled' > "$TEMP_DIR/legacy-admin-result"
cloudroute_actual=$(CLOUDROUTE_ADMIN_RESULT="$TEMP_DIR/legacy-admin-result" \
  CLOUDROUTE_KILL_TOKEN="$TEMP_DIR/cloudroute-token" \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "kill" { print $2 "\t" $3 }')
[ "$cloudroute_actual" = $'已开启\tok' ]

legacy_actual=$(PUFFROUTE_ADMIN_RESULT="$TEMP_DIR/legacy-admin-result" \
  PUFFROUTE_KILL_TOKEN="$TEMP_DIR/legacy-token" \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "kill" { print $2 "\t" $3 }')
[ "$legacy_actual" = $'已开启\tok' ]

cloudroute_config_probe=$(CLOUDROUTE_CONFIG="$TEMP_DIR/cloudlink-guard-config" \
  CLOUDROUTE_MIXED=127.0.0.1:7896 \
  CLOUDROUTE_SYSTEM_PROXY_ACTIVE=0 \
  CLOUDROUTE_TUN_ACTIVE=0 \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "port" { print $2 }')
case "$cloudroute_config_probe" in
  '7896 监听中'|'7896 未监听') ;;
  *) echo "CloudRoute 环境变量兼容失败: $cloudroute_config_probe" >&2; exit 1 ;;
esac

FAKE_OSASCRIPT="$TEMP_DIR/fake-osascript"
/usr/bin/printf '%s\n' \
  '#!/bin/bash' \
  'case "${CLOUDLINK_GUARD_FAKE_ADMIN_MODE:-enabled}" in' \
  '  enabled) echo "✅ Kill Switch: Enabled (3 条 anchor 规则)" ;;' \
  '  disabled) echo "⚪️ Kill Switch: Disabled (PF 当前未启用)" ;;' \
  '  canceled) echo "execution error: User canceled. (-128)" >&2; exit 1 ;;' \
  '  *) echo "unexpected test mode" >&2; exit 2 ;;' \
  'esac' > "$FAKE_OSASCRIPT"
/bin/chmod 755 "$FAKE_OSASCRIPT"

ADMIN_SCRIPT="$SCRIPT_DIR/../Helpers/CloudLinkGuard Admin.applescript"
NEW_RESULT="$TEMP_DIR/cache/admin-result"
admin_output=$(CLOUDLINK_GUARD_ADMIN_SCRIPT="$ADMIN_SCRIPT" \
  CLOUDLINK_GUARD_OSASCRIPT="$FAKE_OSASCRIPT" \
  CLOUDLINK_GUARD_ADMIN_RESULT="$NEW_RESULT" \
  CLOUDLINK_GUARD_KILL_TOKEN="$TEMP_DIR/new-token" \
  /bin/bash "$BACKEND" kill-status)
/usr/bin/printf '%s\n' "$admin_output" | /usr/bin/grep -Fq 'Kill Switch: Enabled'
[ "$(/usr/bin/stat -f '%Lp' "$NEW_RESULT")" = "600" ]

cached_actual=$(CLOUDLINK_GUARD_ADMIN_RESULT="$NEW_RESULT" \
  CLOUDLINK_GUARD_KILL_TOKEN="$TEMP_DIR/new-token" \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "kill" { print $2 "\t" $3 }')
[ "$cached_actual" = $'已开启\tok' ]

if cancel_output=$(CLOUDLINK_GUARD_FAKE_ADMIN_MODE=canceled \
  CLOUDLINK_GUARD_ADMIN_SCRIPT="$ADMIN_SCRIPT" \
  CLOUDLINK_GUARD_OSASCRIPT="$FAKE_OSASCRIPT" \
  CLOUDLINK_GUARD_ADMIN_RESULT="$NEW_RESULT" \
  CLOUDLINK_GUARD_KILL_TOKEN="$TEMP_DIR/new-token" \
  /bin/bash "$BACKEND" kill-status 2>&1); then
  echo '取消授权测试应返回失败' >&2
  exit 1
fi
/usr/bin/printf '%s\n' "$cancel_output" | /usr/bin/grep -Fq '已取消管理员授权，未修改 Kill Switch'

echo 'CloudCheck backend state parsing tests passed.'
