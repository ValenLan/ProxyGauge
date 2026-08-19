#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
HELPER="$SCRIPT_DIR/cloudcheck-killswitch"
TEST_ROOT=$(/usr/bin/mktemp -d /tmp/cloudcheck-killswitch-test.XXXXXX)
trap '/bin/rm -rf "$TEST_ROOT"' EXIT

/bin/mkdir -p "$TEST_ROOT/etc/pf.anchors" "$TEST_ROOT/bin"
/usr/bin/printf '%s\n' 'set skip on lo0' > "$TEST_ROOT/etc/pf.conf"
/usr/bin/printf '%s\n' '#!/bin/bash' 'exit 0' > "$TEST_ROOT/bin/pfctl"
/bin/chmod 755 "$TEST_ROOT/bin/pfctl"

run_helper() {
  CLOUDCHECK_KILLSWITCH_TEST_ROOT="$TEST_ROOT" \
  CLOUDCHECK_KILLSWITCH_TEST_PFCTL="$TEST_ROOT/bin/pfctl" \
  /bin/bash "$HELPER" "$@"
}

install_output=$(run_helper install 203.0.113.10 'en0 en1')
/usr/bin/printf '%s\n' "$install_output" | /usr/bin/grep -Fq '规则已安装，当前保持关闭'
/usr/bin/grep -Fq 'anchor "cloudcheck"' "$TEST_ROOT/etc/pf.conf"
/usr/bin/grep -Fq '203.0.113.10' "$TEST_ROOT/etc/pf.anchors/cloudcheck"
/usr/bin/grep -Fq 'phys = "{ en0 en1 }"' "$TEST_ROOT/etc/pf.anchors/cloudcheck"
[ -r "$TEST_ROOT/etc/pf.conf.cloudcheck.bak" ]

if run_helper install 203.0.113.999 'en0 en1' >/dev/null 2>&1; then
  echo '越界 IPv4 不应通过校验' >&2
  exit 1
fi
if run_helper install 203.0.113.010 'en0 en1' >/dev/null 2>&1; then
  echo '带前导零的 IPv4 不应通过校验' >&2
  exit 1
fi
if run_helper install 203.0.113.10 'en0; reboot' >/dev/null 2>&1; then
  echo '非法接口参数不应通过校验' >&2
  exit 1
fi
if run_helper install 203.0.113.10 'utun0' >/dev/null 2>&1; then
  echo '隧道接口不应被当作物理接口' >&2
  exit 1
fi

/usr/bin/printf '%s\n' 'anchor "killswitch"' > "$TEST_ROOT/etc/pf.conf"
if run_helper install 203.0.113.10 'en0 en1' >/dev/null 2>&1; then
  echo '旧版 killswitch 存在时不得自动叠加新 anchor' >&2
  exit 1
fi

echo 'CloudCheck Kill Switch installation safety tests passed.'
