#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
APP_SOURCE="$PROJECT_ROOT/Sources/CloudCheckApp.swift"
TEMP_DIR=$(/usr/bin/mktemp -d /tmp/cloudcheck-private-browser-test.XXXXXX)
trap '/bin/rm -rf "$TEMP_DIR"' EXIT

/usr/bin/printf '%s\n' 'CLOUDCHECK_MIXED="127.0.0.1:7000"' > "$TEMP_DIR/config"

default_output=$(CLOUDCHECK_CONFIG=/dev/null \
  CLOUDCHECK_PRIVATE_BROWSER_DRY_RUN=1 \
  /bin/bash "$PROJECT_ROOT/Scripts/cloudcheck-private-browser.sh" default 198.51.100.10)
google_output=$(CLOUDCHECK_CONFIG=/dev/null \
  CLOUDCHECK_PRIVATE_BROWSER_DRY_RUN=1 \
  /bin/bash "$PROJECT_ROOT/Scripts/cloudcheck-private-browser.sh" google 203.0.113.20)
legacy_output=$(PUFFROUTE_CONFIG=/dev/null \
  PUFFROUTE_PRIVATE_BROWSER_DRY_RUN=1 \
  PUFFROUTE_MIXED=127.0.0.1:7892 \
  /bin/bash "$PROJECT_ROOT/Scripts/cloudcheck-private-browser.sh" default 198.51.100.10)
cloudroute_output=$(CLOUDROUTE_CONFIG=/dev/null \
  CLOUDROUTE_PRIVATE_BROWSER_DRY_RUN=1 \
  CLOUDROUTE_MIXED=127.0.0.1:7893 \
  /bin/bash "$PROJECT_ROOT/Scripts/cloudcheck-private-browser.sh" default 198.51.100.10)
cloudlink_output=$(CLOUDLINK_GUARD_CONFIG=/dev/null \
  CLOUDLINK_GUARD_PRIVATE_BROWSER_DRY_RUN=1 \
  CLOUDLINK_GUARD_MIXED=127.0.0.1:7894 \
  /bin/bash "$PROJECT_ROOT/Scripts/cloudcheck-private-browser.sh" default 198.51.100.10)
no_ip_output=$(CLOUDCHECK_CONFIG=/dev/null \
  CLOUDCHECK_PRIVATE_BROWSER_DRY_RUN=1 \
  /bin/bash "$PROJECT_ROOT/Scripts/cloudcheck-private-browser.sh" default)
saved_endpoint_output=$(CLOUDCHECK_CONFIG="$TEMP_DIR/config" \
  CLOUDCHECK_MIXED=127.0.0.1:7898 \
  CLOUDCHECK_PRIVATE_BROWSER_DRY_RUN=1 \
  /bin/bash "$PROJECT_ROOT/Scripts/cloudcheck-private-browser.sh" default)
custom_secondary_output=$(CLOUDCHECK_CONFIG=/dev/null \
  CLOUDCHECK_SECONDARY_MIXED=127.0.0.1:7991 \
  CLOUDCHECK_SECONDARY_LABEL='工作出口' \
  CLOUDCHECK_PRIVATE_BROWSER_DRY_RUN=1 \
  /bin/bash "$PROJECT_ROOT/Scripts/cloudcheck-private-browser.sh" google)

/usr/bin/grep -q '^route=默认出口$' <<< "$default_output"
/usr/bin/grep -q '^proxy=127.0.0.1:7890$' <<< "$default_output"
/usr/bin/grep -q '^url_count=5$' <<< "$default_output"
/usr/bin/grep -q '^route=Google / Gemini 链路$' <<< "$google_output"
/usr/bin/grep -q '^proxy=127.0.0.1:7891$' <<< "$google_output"
/usr/bin/grep -q '^url_count=5$' <<< "$google_output"
/usr/bin/grep -q '^proxy=127.0.0.1:7892$' <<< "$legacy_output"
/usr/bin/grep -q '^proxy=127.0.0.1:7893$' <<< "$cloudroute_output"
/usr/bin/grep -q '^proxy=127.0.0.1:7894$' <<< "$cloudlink_output"
/usr/bin/grep -q '^url_count=3$' <<< "$no_ip_output"
/usr/bin/grep -q '^proxy=127.0.0.1:7898$' <<< "$saved_endpoint_output"
/usr/bin/grep -q '^route=工作出口 链路$' <<< "$custom_secondary_output"
/usr/bin/grep -q '^proxy=127.0.0.1:7991$' <<< "$custom_secondary_output"
/usr/bin/grep -Fq 'Text("高级检测")' "$APP_SOURCE"
/usr/bin/grep -Fq 'Text("不计入链路分")' "$APP_SOURCE"
/usr/bin/grep -Fq 'process.arguments = [scriptPath, route.rawValue, ""]' "$APP_SOURCE"
/usr/bin/grep -Fq 'environment["CLOUDCHECK_MIXED"] = endpoint' "$APP_SOURCE"
/usr/bin/grep -Fq 'environment["CLOUDCHECK_SECONDARY_MIXED"] = plan.secondaryEndpoint' "$APP_SOURCE"

echo "CloudCheck isolated browser tests passed."
