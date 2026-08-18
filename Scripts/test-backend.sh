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

echo 'CloudRoute backend state parsing tests passed.'
