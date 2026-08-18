#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
CONFIG_FILE="${PUFFROUTE_CONFIG:-$HOME/.config/puffroute/config}"

if [ ! -r "$CONFIG_FILE" ]; then
  echo "Missing config: $CONFIG_FILE" >&2
  exit 1
fi

. "$CONFIG_FILE"
: "${PUFFROUTE_VPS_IP:?Set PUFFROUTE_VPS_IP in $CONFIG_FILE}"
PUFFROUTE_INTERFACES="${PUFFROUTE_INTERFACES:-en0 en1}"

if ! echo "$PUFFROUTE_VPS_IP" | /usr/bin/grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
  echo "PUFFROUTE_VPS_IP must be an IPv4 address" >&2
  exit 1
fi
if ! echo "$PUFFROUTE_INTERFACES" | /usr/bin/grep -qE '^[a-zA-Z0-9 ]+$'; then
  echo "PUFFROUTE_INTERFACES contains unsupported characters" >&2
  exit 1
fi

TEMP_DIR=$(/usr/bin/mktemp -d /tmp/puffroute-pf.XXXXXX)
trap '/bin/rm -rf "$TEMP_DIR"' EXIT

/usr/bin/sed \
  -e "s/__VPS_IP__/$PUFFROUTE_VPS_IP/g" \
  -e "s/__INTERFACES__/$PUFFROUTE_INTERFACES/g" \
  "$PROJECT_ROOT/PF/puffroute.conf.template" > "$TEMP_DIR/puffroute"

/bin/cp /etc/pf.conf "$TEMP_DIR/pf.conf"
if ! /usr/bin/grep -qE '^[[:space:]]*anchor[[:space:]]+"puffroute"' "$TEMP_DIR/pf.conf"; then
  /bin/echo '' >> "$TEMP_DIR/pf.conf"
  /bin/echo 'anchor "puffroute"' >> "$TEMP_DIR/pf.conf"
fi

/usr/bin/sudo /usr/bin/install -o root -g wheel -m 644 "$TEMP_DIR/puffroute" /etc/pf.anchors/puffroute
/usr/bin/sudo /sbin/pfctl -nf "$TEMP_DIR/pf.conf"

if [ ! -e /etc/pf.conf.puffroute.bak ]; then
  /usr/bin/sudo /bin/cp -p /etc/pf.conf /etc/pf.conf.puffroute.bak
fi
/usr/bin/sudo /usr/bin/install -o root -g wheel -m 644 "$TEMP_DIR/pf.conf" /etc/pf.conf

echo "Installed /etc/pf.anchors/puffroute and registered its anchor in /etc/pf.conf"
echo "Backup: /etc/pf.conf.puffroute.bak"
