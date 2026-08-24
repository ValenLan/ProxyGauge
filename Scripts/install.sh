#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
USER_BIN="$HOME/.local/bin"
SUPPORT_DIR="$HOME/.local/share/proxygauge"
CONFIG_DIR="$HOME/.config/proxygauge"
CLOUDCHECK_CONFIG_PATH="$HOME/.config/cloudcheck/config"
CLOUDLINK_GUARD_CONFIG_PATH="$HOME/.config/cloudlink-guard/config"
CLOUDROUTE_CONFIG_PATH="$HOME/.config/cloudroute/config"
PUFFROUTE_CONFIG_PATH="$HOME/.config/puffroute/config"
APP_DIR="$HOME/Applications"

"$PROJECT_ROOT/Scripts/build.sh"

/bin/mkdir -p "$USER_BIN" "$SUPPORT_DIR" "$CONFIG_DIR" "$APP_DIR"
/usr/bin/install -m 755 "$PROJECT_ROOT/Scripts/proxygauge-check.sh" "$USER_BIN/proxygauge-check"
/usr/bin/install -m 755 "$PROJECT_ROOT/Scripts/proxygauge-ip-risk.jxa" "$USER_BIN/proxygauge-ip-risk.jxa"
/usr/bin/install -m 755 "$PROJECT_ROOT/Scripts/proxygauge-chain-check.jxa" "$USER_BIN/proxygauge-chain-check.jxa"
/usr/bin/install -m 755 "$PROJECT_ROOT/Scripts/proxygauge-private-browser.sh" "$USER_BIN/proxygauge-private-browser"
/usr/bin/install -m 755 "$PROJECT_ROOT/Scripts/proxygauge-killswitch" "$USER_BIN/proxygauge-killswitch"
/usr/bin/install -m 755 "$PROJECT_ROOT/Scripts/proxygauge-backend.sh" "$SUPPORT_DIR/proxygauge-backend.sh"
/usr/bin/install -m 644 "$PROJECT_ROOT/Helpers/ProxyGauge Admin.applescript" \
  "$SUPPORT_DIR/proxygauge-admin.applescript"
/usr/bin/install -m 644 "$PROJECT_ROOT/PF/proxygauge.conf.template" \
  "$SUPPORT_DIR/proxygauge.conf.template"

# Keep previous command names as upgrade shims rather than stale copies.
/bin/ln -sfn proxygauge-check "$USER_BIN/cloudcheck-check"
/bin/ln -sfn proxygauge-ip-risk.jxa "$USER_BIN/cloudcheck-ip-risk.jxa"
/bin/ln -sfn proxygauge-chain-check.jxa "$USER_BIN/cloudcheck-chain-check.jxa"
/bin/ln -sfn proxygauge-private-browser "$USER_BIN/cloudcheck-private-browser"
/bin/ln -sfn proxygauge-killswitch "$USER_BIN/cloudcheck-killswitch"
/bin/ln -sfn proxygauge-check "$USER_BIN/cloudlink-guard-check"
/bin/ln -sfn proxygauge-ip-risk.jxa "$USER_BIN/cloudlink-guard-ip-risk.jxa"
/bin/ln -sfn proxygauge-chain-check.jxa "$USER_BIN/cloudlink-guard-chain-check.jxa"
/bin/ln -sfn proxygauge-private-browser "$USER_BIN/cloudlink-guard-private-browser"
/bin/ln -sfn proxygauge-killswitch "$USER_BIN/cloudlink-guard-killswitch"
/bin/ln -sfn proxygauge-check "$USER_BIN/cloudroute-check"
/bin/ln -sfn proxygauge-ip-risk.jxa "$USER_BIN/cloudroute-ip-risk.jxa"
/bin/ln -sfn proxygauge-chain-check.jxa "$USER_BIN/cloudroute-chain-check.jxa"
/bin/ln -sfn proxygauge-private-browser "$USER_BIN/cloudroute-private-browser"
/bin/ln -sfn proxygauge-killswitch "$USER_BIN/cloudroute-killswitch"
/bin/ln -sfn proxygauge-check "$USER_BIN/puffroute-check"
/bin/ln -sfn proxygauge-ip-risk.jxa "$USER_BIN/puffroute-ip-risk.jxa"
/bin/ln -sfn proxygauge-chain-check.jxa "$USER_BIN/puffroute-chain-check.jxa"
/bin/ln -sfn proxygauge-private-browser "$USER_BIN/puffroute-private-browser"
/bin/ln -sfn proxygauge-killswitch "$USER_BIN/puffroute-killswitch"

if [ ! -e "$CONFIG_DIR/config" ]; then
  if [ -r "$CLOUDCHECK_CONFIG_PATH" ]; then
    /bin/cp "$CLOUDCHECK_CONFIG_PATH" "$CONFIG_DIR/config"
  elif [ -r "$CLOUDLINK_GUARD_CONFIG_PATH" ]; then
    /bin/cp "$CLOUDLINK_GUARD_CONFIG_PATH" "$CONFIG_DIR/config"
  elif [ -r "$CLOUDROUTE_CONFIG_PATH" ]; then
    /bin/cp "$CLOUDROUTE_CONFIG_PATH" "$CONFIG_DIR/config"
  elif [ -r "$PUFFROUTE_CONFIG_PATH" ]; then
    /bin/cp "$PUFFROUTE_CONFIG_PATH" "$CONFIG_DIR/config"
  else
    /bin/cp "$PROJECT_ROOT/config.example" "$CONFIG_DIR/config"
  fi
  /bin/chmod 600 "$CONFIG_DIR/config"
fi

/usr/bin/ditto "$PROJECT_ROOT/build/ProxyGauge.app" "$APP_DIR/ProxyGauge.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP_DIR/ProxyGauge.app"

echo "Installed $APP_DIR/ProxyGauge.app"
echo "Configuration: $CONFIG_DIR/config"
echo "Optional Kill Switch rules can now be configured from the ProxyGauge app."
