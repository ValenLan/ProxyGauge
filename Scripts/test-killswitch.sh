#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
HELPER="$SCRIPT_DIR/cloudcheck-killswitch"
TEST_ROOT=$(/usr/bin/mktemp -d /tmp/cloudcheck-killswitch-test.XXXXXX)
trap '/bin/rm -rf "$TEST_ROOT"' EXIT

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
  '  "-a cloudcheck -sr") echo "block return out on en0 all" ;;' \
  '  "-a killswitch -sr") echo "block return out on en0 all" ;;' \
  '  "-E") echo "Token : 12345" ;;' \
  'esac' \
  'exit 0' > "$TEST_ROOT/bin/pfctl"
/bin/chmod 755 "$TEST_ROOT/bin/pfctl"

run_helper() {
  CLOUDCHECK_KILLSWITCH_TEST_ROOT="$TEST_ROOT" \
  CLOUDCHECK_KILLSWITCH_TEST_PFCTL="$TEST_ROOT/bin/pfctl" \
  CLOUDCHECK_KILLSWITCH_TEST_INTERFACES="${CLOUDCHECK_KILLSWITCH_TEST_INTERFACES:-en0 en1}" \
  /bin/bash "$HELPER" "$@"
}

bootstrap_output=$(run_helper on)
/usr/bin/printf '%s\n' "$bootstrap_output" | /usr/bin/grep -Fq '规则已安装，当前保持关闭'
/usr/bin/printf '%s\n' "$bootstrap_output" | /usr/bin/grep -Fq 'Kill Switch 已开启'
/usr/bin/grep -Fq 'anchor "cloudcheck"' "$TEST_ROOT/etc/pf.conf"
/usr/bin/grep -Fq 'phys = "{ en0 en1 }"' "$TEST_ROOT/etc/pf.anchors/cloudcheck"
if /usr/bin/grep -Eq '__VPS_IP__|cloudlink_guard_vps' "$TEST_ROOT/etc/pf.anchors/cloudcheck"; then
  echo '内置规则不得依赖服务器 IP 参数' >&2
  exit 1
fi
[ -r "$TEST_ROOT/etc/pf.conf.cloudcheck.bak" ]
[ -s "$TEST_ROOT/var/run/cloudcheck-killswitch.pf-token" ]

/usr/bin/printf '%s\n' 'set skip on lo0' > "$TEST_ROOT/etc/pf.conf"
/bin/rm -f "$TEST_ROOT/etc/pf.anchors/cloudcheck" \
  "$TEST_ROOT/var/run/cloudcheck-killswitch.pf-token"
if CLOUDCHECK_KILLSWITCH_TEST_INTERFACES='en0; reboot' run_helper on >/dev/null 2>&1; then
  echo '非法接口参数不应通过校验' >&2
  exit 1
fi
if CLOUDCHECK_KILLSWITCH_TEST_INTERFACES='utun0' run_helper on >/dev/null 2>&1; then
  echo '隧道接口不应被当作物理接口' >&2
  exit 1
fi

/usr/bin/printf '%s\n' 'block return out on en0 all' > "$TEST_ROOT/etc/pf.anchors/killswitch"
anchor_hash_before=$(/usr/bin/shasum -a 256 "$TEST_ROOT/etc/pf.anchors/killswitch" | /usr/bin/awk '{print $1}')
recovery_output=$(run_helper on)
/usr/bin/printf '%s\n' "$recovery_output" | /usr/bin/grep -Fq '已恢复原有 Kill Switch 规则入口'
/usr/bin/printf '%s\n' "$recovery_output" | /usr/bin/grep -Fq 'Kill Switch 已开启'
/usr/bin/grep -Fq 'anchor "killswitch"' "$TEST_ROOT/etc/pf.conf"
[ -r "$TEST_ROOT/etc/pf.conf.cloudcheck-entry.bak" ]
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

if run_helper install unexpected >/dev/null 2>&1; then
  echo '内置安装不得接收用户配置参数' >&2
  exit 1
fi

echo 'CloudCheck Kill Switch self-contained installation and recovery safety tests passed.'
