#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
USER_BIN="$HOME/.local/bin"
SUPPORT_DIR="$HOME/.local/share/cloudroute"
CONFIG_DIR="$HOME/.config/cloudroute"
LEGACY_CONFIG="$HOME/.config/puffroute/config"
APP_DIR="$HOME/Applications"

"$PROJECT_ROOT/Scripts/build.sh"

/bin/mkdir -p "$USER_BIN" "$SUPPORT_DIR" "$CONFIG_DIR" "$APP_DIR"
/usr/bin/install -m 755 "$PROJECT_ROOT/Scripts/cloudroute-check.sh" "$USER_BIN/cloudroute-check"
/usr/bin/install -m 755 "$PROJECT_ROOT/Scripts/cloudroute-ip-risk.jxa" "$USER_BIN/cloudroute-ip-risk.jxa"
/usr/bin/install -m 755 "$PROJECT_ROOT/Scripts/cloudroute-chain-check.jxa" "$USER_BIN/cloudroute-chain-check.jxa"
/usr/bin/install -m 755 "$PROJECT_ROOT/Scripts/cloudroute-private-browser.sh" "$USER_BIN/cloudroute-private-browser"
/usr/bin/install -m 755 "$PROJECT_ROOT/Scripts/cloudroute-killswitch" "$USER_BIN/cloudroute-killswitch"
/usr/bin/install -m 755 "$PROJECT_ROOT/Scripts/cloudroute-backend.sh" "$SUPPORT_DIR/cloudroute-backend.sh"
/usr/bin/install -m 644 "$PROJECT_ROOT/Helpers/CloudRoute Admin.applescript" \
  "$SUPPORT_DIR/cloudroute-admin.applescript"

if [ ! -e "$CONFIG_DIR/config" ]; then
  if [ -r "$LEGACY_CONFIG" ]; then
    /bin/cp "$LEGACY_CONFIG" "$CONFIG_DIR/config"
  else
    /bin/cp "$PROJECT_ROOT/config.example" "$CONFIG_DIR/config"
  fi
  /bin/chmod 600 "$CONFIG_DIR/config"
fi

/usr/bin/ditto "$PROJECT_ROOT/build/CloudRoute.app" "$APP_DIR/CloudRoute.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP_DIR/CloudRoute.app"

echo "Installed $APP_DIR/CloudRoute.app"
echo "Configuration: $CONFIG_DIR/config"
echo "To configure the optional Kill Switch, review and run Scripts/install-pf.sh"
