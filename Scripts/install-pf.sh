#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
DEFAULT_CONFIG="$HOME/.config/cloudroute/config"
LEGACY_CONFIG="$HOME/.config/puffroute/config"
CONFIG_FILE="${CLOUDROUTE_CONFIG:-${PUFFROUTE_CONFIG:-$DEFAULT_CONFIG}}"
if [ -z "${CLOUDROUTE_CONFIG:-}" ] && [ -z "${PUFFROUTE_CONFIG:-}" ] \
  && [ ! -r "$CONFIG_FILE" ] && [ -r "$LEGACY_CONFIG" ]; then
  CONFIG_FILE="$LEGACY_CONFIG"
fi

if [ ! -r "$CONFIG_FILE" ]; then
  echo "Missing config: $CONFIG_FILE" >&2
  exit 1
fi

. "$CONFIG_FILE"
CLOUDROUTE_VPS_IP="${CLOUDROUTE_VPS_IP:-${PUFFROUTE_VPS_IP:-}}"
CLOUDROUTE_INTERFACES="${CLOUDROUTE_INTERFACES:-${PUFFROUTE_INTERFACES:-en0 en1}}"

if [ -z "$CLOUDROUTE_VPS_IP" ]; then
  echo "Set CLOUDROUTE_VPS_IP in $CONFIG_FILE" >&2
  exit 1
fi

if ! echo "$CLOUDROUTE_VPS_IP" | /usr/bin/grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
  echo "CLOUDROUTE_VPS_IP must be an IPv4 address" >&2
  exit 1
fi
if ! echo "$CLOUDROUTE_INTERFACES" | /usr/bin/grep -qE '^[a-zA-Z0-9 ]+$'; then
  echo "CLOUDROUTE_INTERFACES contains unsupported characters" >&2
  exit 1
fi

TEMP_DIR=$(/usr/bin/mktemp -d /tmp/cloudroute-pf.XXXXXX)
trap '/bin/rm -rf "$TEMP_DIR"' EXIT

/usr/bin/sed \
  -e "s/__VPS_IP__/$CLOUDROUTE_VPS_IP/g" \
  -e "s/__INTERFACES__/$CLOUDROUTE_INTERFACES/g" \
  "$PROJECT_ROOT/PF/cloudroute.conf.template" > "$TEMP_DIR/cloudroute"

/bin/cp /etc/pf.conf "$TEMP_DIR/pf.conf"
if ! /usr/bin/grep -qE '^[[:space:]]*anchor[[:space:]]+"cloudroute"' "$TEMP_DIR/pf.conf"; then
  /bin/echo '' >> "$TEMP_DIR/pf.conf"
  /bin/echo 'anchor "cloudroute"' >> "$TEMP_DIR/pf.conf"
fi

/usr/bin/sudo /usr/bin/install -o root -g wheel -m 644 "$TEMP_DIR/cloudroute" /etc/pf.anchors/cloudroute
/usr/bin/sudo /sbin/pfctl -nf "$TEMP_DIR/pf.conf"

if [ ! -e /etc/pf.conf.cloudroute.bak ]; then
  /usr/bin/sudo /bin/cp -p /etc/pf.conf /etc/pf.conf.cloudroute.bak
fi
/usr/bin/sudo /usr/bin/install -o root -g wheel -m 644 "$TEMP_DIR/pf.conf" /etc/pf.conf

echo "Installed /etc/pf.anchors/cloudroute and registered its anchor in /etc/pf.conf"
echo "Backup: /etc/pf.conf.cloudroute.bak"
