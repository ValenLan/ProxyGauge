#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
DEFAULT_CONFIG="$HOME/.config/cloudcheck/config"
CLOUDLINK_GUARD_CONFIG_PATH="$HOME/.config/cloudlink-guard/config"
CLOUDROUTE_CONFIG_PATH="$HOME/.config/cloudroute/config"
PUFFROUTE_CONFIG_PATH="$HOME/.config/puffroute/config"

import_legacy_compat() {
  local suffix current legacy_prefix legacy
  for suffix in "$@"; do
    current="CLOUDCHECK_$suffix"
    declare -p "$current" >/dev/null 2>&1 && continue
    for legacy_prefix in CLOUDLINK_GUARD CLOUDROUTE PUFFROUTE; do
      legacy="${legacy_prefix}_$suffix"
      if declare -p "$legacy" >/dev/null 2>&1; then
        printf -v "$current" '%s' "${!legacy}"
        export "$current"
        break
      fi
    done
  done
}

import_legacy_compat CONFIG VPS_IP INTERFACES
CONFIG_FILE="${CLOUDCHECK_CONFIG:-$DEFAULT_CONFIG}"
if [ -z "${CLOUDCHECK_CONFIG:-}" ] && [ ! -r "$CONFIG_FILE" ]; then
  if [ -r "$CLOUDLINK_GUARD_CONFIG_PATH" ]; then
    CONFIG_FILE="$CLOUDLINK_GUARD_CONFIG_PATH"
  elif [ -r "$CLOUDROUTE_CONFIG_PATH" ]; then
    CONFIG_FILE="$CLOUDROUTE_CONFIG_PATH"
  elif [ -r "$PUFFROUTE_CONFIG_PATH" ]; then
    CONFIG_FILE="$PUFFROUTE_CONFIG_PATH"
  fi
fi

if [ ! -r "$CONFIG_FILE" ]; then
  echo "Missing config: $CONFIG_FILE" >&2
  exit 1
fi

. "$CONFIG_FILE"
import_legacy_compat VPS_IP INTERFACES
CLOUDCHECK_VPS_IP="${CLOUDCHECK_VPS_IP:-}"
CLOUDCHECK_INTERFACES="${CLOUDCHECK_INTERFACES:-en0 en1}"

if [ -z "$CLOUDCHECK_VPS_IP" ]; then
  echo "Set CLOUDCHECK_VPS_IP in $CONFIG_FILE" >&2
  exit 1
fi

if ! echo "$CLOUDCHECK_VPS_IP" | /usr/bin/grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
  echo "CLOUDCHECK_VPS_IP must be an IPv4 address" >&2
  exit 1
fi
if ! echo "$CLOUDCHECK_INTERFACES" | /usr/bin/grep -qE '^[a-zA-Z0-9 ]+$'; then
  echo "CLOUDCHECK_INTERFACES contains unsupported characters" >&2
  exit 1
fi

TEMP_DIR=$(/usr/bin/mktemp -d /tmp/cloudcheck-pf.XXXXXX)
trap '/bin/rm -rf "$TEMP_DIR"' EXIT

ANCHOR_NAME=cloudcheck
ANCHOR_PATH=/etc/pf.anchors/cloudcheck
if /usr/bin/grep -qE '^[[:space:]]*anchor[[:space:]]+"cloudlink-guard"' /etc/pf.conf \
  && [ -r /etc/pf.anchors/cloudlink-guard ]; then
  ANCHOR_NAME=cloudlink-guard
  ANCHOR_PATH=/etc/pf.anchors/cloudlink-guard
elif /usr/bin/grep -qE '^[[:space:]]*anchor[[:space:]]+"cloudroute"' /etc/pf.conf \
  && [ -r /etc/pf.anchors/cloudroute ]; then
  ANCHOR_NAME=cloudroute
  ANCHOR_PATH=/etc/pf.anchors/cloudroute
elif /usr/bin/grep -qE '^[[:space:]]*anchor[[:space:]]+"puffroute"' /etc/pf.conf \
  && [ -r /etc/pf.anchors/puffroute ]; then
  ANCHOR_NAME=puffroute
  ANCHOR_PATH=/etc/pf.anchors/puffroute
elif /usr/bin/grep -qE '^[[:space:]]*anchor[[:space:]]+"killswitch"' /etc/pf.conf; then
  echo "Detected the older killswitch anchor; CloudCheck already delegates to its helper." >&2
  echo "Refusing to add a second PF anchor automatically. Migrate that rule separately." >&2
  exit 1
fi

/usr/bin/sed \
  -e "s/__VPS_IP__/$CLOUDCHECK_VPS_IP/g" \
  -e "s/__INTERFACES__/$CLOUDCHECK_INTERFACES/g" \
  "$PROJECT_ROOT/PF/cloudcheck.conf.template" > "$TEMP_DIR/$ANCHOR_NAME"

/bin/cp /etc/pf.conf "$TEMP_DIR/pf.conf"
if ! /usr/bin/grep -qE "^[[:space:]]*anchor[[:space:]]+\"$ANCHOR_NAME\"" "$TEMP_DIR/pf.conf"; then
  /bin/echo '' >> "$TEMP_DIR/pf.conf"
  /bin/echo "anchor \"$ANCHOR_NAME\"" >> "$TEMP_DIR/pf.conf"
fi

/usr/bin/sudo /usr/bin/install -o root -g wheel -m 644 "$TEMP_DIR/$ANCHOR_NAME" "$ANCHOR_PATH"
/usr/bin/sudo /sbin/pfctl -nf "$TEMP_DIR/pf.conf"

if [ ! -e /etc/pf.conf.cloudcheck.bak ]; then
  /usr/bin/sudo /bin/cp -p /etc/pf.conf /etc/pf.conf.cloudcheck.bak
fi
/usr/bin/sudo /usr/bin/install -o root -g wheel -m 644 "$TEMP_DIR/pf.conf" /etc/pf.conf

echo "Installed $ANCHOR_PATH and registered anchor $ANCHOR_NAME in /etc/pf.conf"
echo "Backup: /etc/pf.conf.cloudcheck.bak"
