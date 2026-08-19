#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
USER_BIN="$HOME/.local/bin"
SUPPORT_DIR="$HOME/.local/share/cloudlink-guard"
CONFIG_DIR="$HOME/.config/cloudlink-guard"
CLOUDROUTE_CONFIG_PATH="$HOME/.config/cloudroute/config"
PUFFROUTE_CONFIG_PATH="$HOME/.config/puffroute/config"
APP_DIR="$HOME/Applications"

"$PROJECT_ROOT/Scripts/build.sh"

/bin/mkdir -p "$USER_BIN" "$SUPPORT_DIR" "$CONFIG_DIR" "$APP_DIR"
/usr/bin/install -m 755 "$PROJECT_ROOT/Scripts/cloudlink-guard-check.sh" "$USER_BIN/cloudlink-guard-check"
/usr/bin/install -m 755 "$PROJECT_ROOT/Scripts/cloudlink-guard-ip-risk.jxa" "$USER_BIN/cloudlink-guard-ip-risk.jxa"
/usr/bin/install -m 755 "$PROJECT_ROOT/Scripts/cloudlink-guard-chain-check.jxa" "$USER_BIN/cloudlink-guard-chain-check.jxa"
/usr/bin/install -m 755 "$PROJECT_ROOT/Scripts/cloudlink-guard-private-browser.sh" "$USER_BIN/cloudlink-guard-private-browser"
/usr/bin/install -m 755 "$PROJECT_ROOT/Scripts/cloudlink-guard-killswitch" "$USER_BIN/cloudlink-guard-killswitch"
/usr/bin/install -m 755 "$PROJECT_ROOT/Scripts/cloudlink-guard-backend.sh" "$SUPPORT_DIR/cloudlink-guard-backend.sh"
/usr/bin/install -m 644 "$PROJECT_ROOT/Helpers/CloudLinkGuard Admin.applescript" \
  "$SUPPORT_DIR/cloudlink-guard-admin.applescript"

# Keep the previous CloudRoute command names as upgrade shims rather than stale copies.
/bin/ln -sfn cloudlink-guard-check "$USER_BIN/cloudroute-check"
/bin/ln -sfn cloudlink-guard-ip-risk.jxa "$USER_BIN/cloudroute-ip-risk.jxa"
/bin/ln -sfn cloudlink-guard-chain-check.jxa "$USER_BIN/cloudroute-chain-check.jxa"
/bin/ln -sfn cloudlink-guard-private-browser "$USER_BIN/cloudroute-private-browser"
/bin/ln -sfn cloudlink-guard-killswitch "$USER_BIN/cloudroute-killswitch"

if [ ! -e "$CONFIG_DIR/config" ]; then
  if [ -r "$CLOUDROUTE_CONFIG_PATH" ]; then
    /bin/cp "$CLOUDROUTE_CONFIG_PATH" "$CONFIG_DIR/config"
  elif [ -r "$PUFFROUTE_CONFIG_PATH" ]; then
    /bin/cp "$PUFFROUTE_CONFIG_PATH" "$CONFIG_DIR/config"
  else
    /bin/cp "$PROJECT_ROOT/config.example" "$CONFIG_DIR/config"
  fi
  /bin/chmod 600 "$CONFIG_DIR/config"
fi

/usr/bin/ditto "$PROJECT_ROOT/build/CloudCheck.app" "$APP_DIR/CloudCheck.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP_DIR/CloudCheck.app"

echo "Installed $APP_DIR/CloudCheck.app"
echo "Configuration: $CONFIG_DIR/config"
echo "To configure the optional Kill Switch, review and run Scripts/install-pf.sh"
