#!/bin/bash
# Live read-only integration smoke test.
#
# Every probe below is read-only: process listing, lsof, stat, ls, the
# backend's discover/probe renderers, and the diagnostic check script. Nothing
# here touches pf, network settings, or any application UI. Each item is
# gated on live preconditions; when a precondition is absent the item prints
# SKIP with its reason instead of failing, so the suite stays green on
# machines without the installed app or without a running Shadowrocket.
set -uo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
APP_BUNDLE=/Applications/ProxyGauge.app
APP_BACKEND="$APP_BUNDLE/Contents/Resources/proxygauge-backend.sh"
REPO_CHECK="$SCRIPT_DIR/proxygauge-check.sh"
SELECTION_FILE=/var/run/proxygauge-killswitch.selection
EXPECTED_CLIENT=Shadowrocket
EXPECTED_ENDPOINT=127.0.0.1:1082
EXPECTED_PORT="${EXPECTED_ENDPOINT##*:}"

TEST_ROOT=$(/usr/bin/mktemp -d /tmp/proxygauge-live-test.XXXXXX)
trap '/bin/rm -rf "$TEST_ROOT"' EXIT

PASS=0
FAIL=0
SKIPPED=0

pass() {
  PASS=$((PASS + 1))
  /usr/bin/printf 'PASS: %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  /usr/bin/printf 'FAIL: %s\n' "$1" >&2
}

skip() {
  SKIPPED=$((SKIPPED + 1))
  /usr/bin/printf 'SKIP: %s (%s)\n' "$1" "$2"
}

shadowrocket_running() {
  /usr/bin/pgrep -x Shadowrocket >/dev/null 2>&1 \
    || /usr/bin/pgrep -x MacPacketTunnel >/dev/null 2>&1
}

mihomo_core_running() {
  /usr/bin/pgrep -x verge-mihomo >/dev/null 2>&1 \
    || /usr/bin/pgrep -x mihomo >/dev/null 2>&1 \
    || /usr/bin/pgrep -x clash-meta >/dev/null 2>&1 \
    || /usr/bin/pgrep -x clash >/dev/null 2>&1
}

expected_port_listening() {
  /usr/sbin/lsof -nP -i4TCP:"$EXPECTED_PORT" -sTCP:LISTEN 2>/dev/null \
    | /usr/bin/grep -q "127.0.0.1:$EXPECTED_PORT"
}

# 1. discover must name the live client and its real mixed endpoint.
if [ ! -f "$APP_BACKEND" ]; then
  skip 'discover client' "$APP_BACKEND not installed"
  skip 'discover endpoint' "$APP_BACKEND not installed"
elif ! shadowrocket_running; then
  skip 'discover client' 'Shadowrocket is not running'
  skip 'discover endpoint' 'Shadowrocket is not running'
elif ! expected_port_listening; then
  skip 'discover client' "$EXPECTED_ENDPOINT is not listening"
  skip 'discover endpoint' "$EXPECTED_ENDPOINT is not listening"
else
  if /bin/bash "$APP_BACKEND" discover > "$TEST_ROOT/discover.out" 2>&1; then
    discovered_client=$(/usr/bin/awk -F '\t' '$1 == "client" { print $2 }' \
      "$TEST_ROOT/discover.out")
    discovered_endpoint=$(/usr/bin/awk -F '\t' '$1 == "endpoint" { print $2 }' \
      "$TEST_ROOT/discover.out")
    if [ "$discovered_client" = "$EXPECTED_CLIENT" ]; then
      pass "discover reports client=$EXPECTED_CLIENT"
    else
      fail "discover client: expected $EXPECTED_CLIENT, got '$discovered_client'"
    fi
    if [ "$discovered_endpoint" = "$EXPECTED_ENDPOINT" ]; then
      pass "discover reports endpoint=$EXPECTED_ENDPOINT"
    else
      fail "discover endpoint: expected $EXPECTED_ENDPOINT, got '$discovered_endpoint'"
    fi
  else
    fail 'discover exited non-zero on the live Shadowrocket scenario'
  fi
fi

# 2. probe must not blame Mihomo when no Mihomo core is running.
if [ ! -f "$APP_BACKEND" ]; then
  skip 'probe attribution' "$APP_BACKEND not installed"
elif mihomo_core_running; then
  skip 'probe attribution' 'a Mihomo-family core is running'
else
  if /bin/bash "$APP_BACKEND" probe > "$TEST_ROOT/probe.out" 2>&1; then
    if /usr/bin/grep -qi 'mihomo' "$TEST_ROOT/probe.out"; then
      fail 'probe mentions Mihomo although no Mihomo core is running'
    else
      pass 'probe output carries no Mihomo wording without a Mihomo core'
    fi
  else
    fail 'probe exited non-zero while no Mihomo core is running'
  fi
fi

# 3. The diagnostic check must clear sections 1-4 on the live link.
if [ ! -f "$REPO_CHECK" ]; then
  skip 'check.sh sections 1-4' "$REPO_CHECK missing"
elif ! shadowrocket_running || ! expected_port_listening; then
  skip 'check.sh sections 1-4' 'live Shadowrocket scenario is not active'
else
  /bin/bash "$REPO_CHECK" > "$TEST_ROOT/check.out" 2>&1 || true
  sections=$(/usr/bin/awk '
    /^===== 1\./ { capture = 1 }
    /^===== 5\./ { capture = 0 }
    capture
  ' "$TEST_ROOT/check.out")
  if /usr/bin/grep -q '^===== 1\.' <<< "$sections" \
    && /usr/bin/grep -q '^===== 4\.' <<< "$sections"; then
    pass 'check.sh rendered sections 1 through 4'
  else
    fail 'check.sh output did not cover sections 1 through 4'
  fi
  if /usr/bin/grep -q '❌' <<< "$sections"; then
    fail 'check.sh sections 1-4 contain ❌'
  else
    pass 'check.sh sections 1-4 contain no ❌'
  fi
fi

# 4. A persisted kill switch selection must point at the Shadowrocket core.
if [ ! -e "$SELECTION_FILE" ]; then
  skip 'killswitch selection' "$SELECTION_FILE does not exist"
elif [ ! -r "$SELECTION_FILE" ]; then
  skip 'killswitch selection' "$SELECTION_FILE is not readable"
else
  selected_path=$(/usr/bin/sed -n '2p' "$SELECTION_FILE")
  case "$selected_path" in
    *Shadowrocket*)
      pass "killswitch selection path names Shadowrocket ($selected_path)"
      ;;
    *)
      fail "killswitch selection path does not name Shadowrocket: '$selected_path'"
      ;;
  esac
fi

# 5. The installed app bundle must stay root-owned, unwritable, ACL-free.
if [ ! -d "$APP_BUNDLE" ]; then
  skip 'app bundle owner' "$APP_BUNDLE not installed"
  skip 'app bundle write bits' "$APP_BUNDLE not installed"
  skip 'app bundle ACL' "$APP_BUNDLE not installed"
else
  bundle_owner=$(/usr/bin/stat -f '%Su:%Sg' "$APP_BUNDLE")
  if [ "$bundle_owner" = 'root:wheel' ]; then
    pass 'app bundle owned by root:wheel'
  else
    fail "app bundle owner: expected root:wheel, got $bundle_owner"
  fi
  bundle_mode=$(/usr/bin/stat -f '%Lp' "$APP_BUNDLE")
  if [ -n "$bundle_mode" ] && [ $((8#$bundle_mode & 022)) -eq 0 ]; then
    pass "app bundle mode $bundle_mode has no group/other write bits"
  else
    fail "app bundle mode $bundle_mode grants group/other write bits"
  fi
  bundle_perms=$(/bin/ls -led "$APP_BUNDLE" | /usr/bin/awk 'NR == 1 { print $1 }')
  case "$bundle_perms" in
    *+*) fail "app bundle carries an extended ACL ($bundle_perms)" ;;
    *) pass 'app bundle carries no extended ACL' ;;
  esac
fi

/usr/bin/printf 'live integration: %d passed / %d skipped / %d failed\n' \
  "$PASS" "$SKIPPED" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
echo 'ProxyGauge live integration smoke test passed.'
