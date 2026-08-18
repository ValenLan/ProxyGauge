#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
USER_BIN="$HOME/.local/bin"
SUPPORT_DIR="$HOME/.local/share/puffroute"
CONFIG_DIR="$HOME/.config/puffroute"
APP_DIR="$HOME/Applications"

"$PROJECT_ROOT/Scripts/build.sh"

/bin/mkdir -p "$USER_BIN" "$SUPPORT_DIR" "$CONFIG_DIR" "$APP_DIR"
/usr/bin/install -m 755 "$PROJECT_ROOT/Scripts/puffroute-check.sh" "$USER_BIN/puffroute-check"
/usr/bin/install -m 755 "$PROJECT_ROOT/Scripts/puffroute-ip-risk.jxa" "$USER_BIN/puffroute-ip-risk.jxa"
/usr/bin/install -m 755 "$PROJECT_ROOT/Scripts/puffroute-chain-check.jxa" "$USER_BIN/puffroute-chain-check.jxa"
/usr/bin/install -m 755 "$PROJECT_ROOT/Scripts/puffroute-private-browser.sh" "$USER_BIN/puffroute-private-browser"
/usr/bin/install -m 755 "$PROJECT_ROOT/Scripts/puffroute-killswitch" "$USER_BIN/puffroute-killswitch"
/usr/bin/install -m 755 "$PROJECT_ROOT/Scripts/puffroute-backend.sh" "$SUPPORT_DIR/puffroute-backend.sh"

if [ ! -e "$CONFIG_DIR/config" ]; then
  /bin/cp "$PROJECT_ROOT/config.example" "$CONFIG_DIR/config"
  /bin/chmod 600 "$CONFIG_DIR/config"
fi

for action in On Off Status; do
  /usr/bin/osacompile -l AppleScript \
    -o "$SUPPORT_DIR/PuffRoute Admin $action.app" \
    "$PROJECT_ROOT/Helpers/PuffRoute Admin $action.applescript"
done

/usr/bin/ditto "$PROJECT_ROOT/build/PuffRoute.app" "$APP_DIR/PuffRoute.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP_DIR/PuffRoute.app"

echo "Installed $APP_DIR/PuffRoute.app"
echo "Configuration: $CONFIG_DIR/config"
echo "To configure the optional Kill Switch, review and run Scripts/install-pf.sh"
