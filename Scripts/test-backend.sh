#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
BACKEND="$SCRIPT_DIR/cloudroute-backend.sh"
TEMP_DIR=$(/usr/bin/mktemp -d /tmp/cloudroute-backend-test.XXXXXX)
trap '/bin/rm -rf "$TEMP_DIR"' EXIT

assert_kill_state() {
  local message expected actual
  message="$1"
  expected="$2"

  /usr/bin/printf '%s\n__STATUS__=0\n' "$message" > "$TEMP_DIR/admin-result"
  actual=$(CLOUDROUTE_ADMIN_RESULT="$TEMP_DIR/admin-result" \
    CLOUDROUTE_KILL_TOKEN="$TEMP_DIR/token" \
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

/usr/bin/printf '%s\n__STATUS__=0\n' 'Kill Switch: Enabled' > "$TEMP_DIR/legacy-admin-result"
legacy_actual=$(PUFFROUTE_ADMIN_RESULT="$TEMP_DIR/legacy-admin-result" \
  PUFFROUTE_KILL_TOKEN="$TEMP_DIR/legacy-token" \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "kill" { print $2 "\t" $3 }')
[ "$legacy_actual" = $'已开启\tok' ]

FAKE_OSASCRIPT="$TEMP_DIR/fake-osascript"
/usr/bin/printf '%s\n' \
  '#!/bin/bash' \
  'case "${CLOUDROUTE_FAKE_ADMIN_MODE:-enabled}" in' \
  '  enabled) echo "✅ Kill Switch: Enabled (3 条 anchor 规则)" ;;' \
  '  disabled) echo "⚪️ Kill Switch: Disabled (PF 当前未启用)" ;;' \
  '  canceled) echo "execution error: User canceled. (-128)" >&2; exit 1 ;;' \
  '  *) echo "unexpected test mode" >&2; exit 2 ;;' \
  'esac' > "$FAKE_OSASCRIPT"
/bin/chmod 755 "$FAKE_OSASCRIPT"

ADMIN_SCRIPT="$SCRIPT_DIR/../Helpers/CloudRoute Admin.applescript"
NEW_RESULT="$TEMP_DIR/cache/admin-result"
admin_output=$(CLOUDROUTE_ADMIN_SCRIPT="$ADMIN_SCRIPT" \
  CLOUDROUTE_OSASCRIPT="$FAKE_OSASCRIPT" \
  CLOUDROUTE_ADMIN_RESULT="$NEW_RESULT" \
  CLOUDROUTE_KILL_TOKEN="$TEMP_DIR/new-token" \
  /bin/bash "$BACKEND" kill-status)
/usr/bin/printf '%s\n' "$admin_output" | /usr/bin/grep -Fq 'Kill Switch: Enabled'
[ "$(/usr/bin/stat -f '%Lp' "$NEW_RESULT")" = "600" ]

cached_actual=$(CLOUDROUTE_ADMIN_RESULT="$NEW_RESULT" \
  CLOUDROUTE_KILL_TOKEN="$TEMP_DIR/new-token" \
  /bin/bash "$BACKEND" probe | /usr/bin/awk -F '\t' '$1 == "kill" { print $2 "\t" $3 }')
[ "$cached_actual" = $'已开启\tok' ]

if cancel_output=$(CLOUDROUTE_FAKE_ADMIN_MODE=canceled \
  CLOUDROUTE_ADMIN_SCRIPT="$ADMIN_SCRIPT" \
  CLOUDROUTE_OSASCRIPT="$FAKE_OSASCRIPT" \
  CLOUDROUTE_ADMIN_RESULT="$NEW_RESULT" \
  CLOUDROUTE_KILL_TOKEN="$TEMP_DIR/new-token" \
  /bin/bash "$BACKEND" kill-status 2>&1); then
  echo '取消授权测试应返回失败' >&2
  exit 1
fi
/usr/bin/printf '%s\n' "$cancel_output" | /usr/bin/grep -Fq '已取消管理员授权，未修改 Kill Switch'

echo 'CloudRoute backend state parsing tests passed.'
