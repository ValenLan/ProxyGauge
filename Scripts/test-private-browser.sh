#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
APP_SOURCE="$PROJECT_ROOT/Sources/CloudRouteApp.swift"

default_output=$(CLOUDROUTE_CONFIG=/dev/null \
  CLOUDROUTE_PRIVATE_BROWSER_DRY_RUN=1 \
  /bin/bash "$PROJECT_ROOT/Scripts/cloudroute-private-browser.sh" default 198.51.100.10)
google_output=$(CLOUDROUTE_CONFIG=/dev/null \
  CLOUDROUTE_PRIVATE_BROWSER_DRY_RUN=1 \
  /bin/bash "$PROJECT_ROOT/Scripts/cloudroute-private-browser.sh" google 203.0.113.20)
legacy_output=$(PUFFROUTE_CONFIG=/dev/null \
  PUFFROUTE_PRIVATE_BROWSER_DRY_RUN=1 \
  PUFFROUTE_MIXED=127.0.0.1:7892 \
  /bin/bash "$PROJECT_ROOT/Scripts/cloudroute-private-browser.sh" default 198.51.100.10)

/usr/bin/grep -q '^route=默认出口$' <<< "$default_output"
/usr/bin/grep -q '^proxy=127.0.0.1:7890$' <<< "$default_output"
/usr/bin/grep -q '^url_count=5$' <<< "$default_output"
/usr/bin/grep -q '^route=Google / Gemini 链路$' <<< "$google_output"
/usr/bin/grep -q '^proxy=127.0.0.1:7891$' <<< "$google_output"
/usr/bin/grep -q '^url_count=5$' <<< "$google_output"
/usr/bin/grep -q '^proxy=127.0.0.1:7892$' <<< "$legacy_output"
/usr/bin/grep -Fq 'item.text.contains("确认 Google / Gemini 出口一致")' "$APP_SOURCE"
/usr/bin/grep -Fq 'isolationMessage = "已用\(route.label)打开隔离窗口' "$APP_SOURCE"

if /usr/bin/grep -Fq 'isolationMessage = "已用(route.label)' "$APP_SOURCE"; then
  echo "The isolated-browser status must interpolate the selected route label." >&2
  exit 1
fi

echo "CloudRoute isolated browser tests passed."
