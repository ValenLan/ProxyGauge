#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
USER_BIN="$HOME/.local/bin"
SUPPORT_DIR="$HOME/.local/share/proxygauge"
CONFIG_DIR="$HOME/.config/proxygauge"
APP_DIR="$HOME/Applications"

"$PROJECT_ROOT/Scripts/build.sh"

/bin/mkdir -p "$USER_BIN" "$SUPPORT_DIR" "$CONFIG_DIR" "$APP_DIR"
/bin/rm -f "$USER_BIN/proxygauge-private-browser"
/usr/bin/install -m 755 "$PROJECT_ROOT/Scripts/proxygauge-check.sh" "$USER_BIN/proxygauge-check"
/usr/bin/install -m 755 "$PROJECT_ROOT/Scripts/proxygauge-ip-risk.jxa" "$USER_BIN/proxygauge-ip-risk.jxa"
/usr/bin/install -m 755 "$PROJECT_ROOT/Scripts/proxygauge-chain-check.jxa" "$USER_BIN/proxygauge-chain-check.jxa"
/usr/bin/install -m 755 "$PROJECT_ROOT/Scripts/proxygauge-killswitch" "$USER_BIN/proxygauge-killswitch"
/usr/bin/install -m 755 "$PROJECT_ROOT/Scripts/proxygauge-backend.sh" "$SUPPORT_DIR/proxygauge-backend.sh"
/usr/bin/install -m 644 "$PROJECT_ROOT/Helpers/ProxyGauge Admin.applescript" \
  "$SUPPORT_DIR/proxygauge-admin.applescript"
/usr/bin/install -m 644 "$PROJECT_ROOT/PF/proxygauge.conf.template" \
  "$SUPPORT_DIR/proxygauge.conf.template"

if [ ! -e "$CONFIG_DIR/config" ]; then
  /bin/cp "$PROJECT_ROOT/config.example" "$CONFIG_DIR/config"
  /bin/chmod 600 "$CONFIG_DIR/config"
fi

/usr/bin/ditto "$PROJECT_ROOT/build/ProxyGauge.app" "$APP_DIR/ProxyGauge.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP_DIR/ProxyGauge.app"

echo "Installed $APP_DIR/ProxyGauge.app"
echo "Configuration: $CONFIG_DIR/config"
echo "Optional Kill Switch rules can now be configured from the ProxyGauge app."
