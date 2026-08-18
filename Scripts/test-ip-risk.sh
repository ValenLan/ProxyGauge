#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)

output=$(/usr/bin/osascript -l JavaScript \
  "$PROJECT_ROOT/Scripts/puffroute-ip-risk.jxa" \
  "$PROJECT_ROOT/Tests/Fixtures/ipapi-risk.json" \
  "$PROJECT_ROOT/Tests/Fixtures/proxycheck-risk.json" \
  "203.0.113.8")

/usr/bin/grep -q 'ASN: AS64500 · Example ASN' <<< "$output"
/usr/bin/grep -q '风险分: 42/100（中） · 置信度 96%' <<< "$output"
/usr/bin/grep -q '风险标签: 数据中心 / 滥用记录' <<< "$output"
/usr/bin/grep -q '滥用指标: 组织 0.014 (Elevated) · ASN 0.0072 (Low)' <<< "$output"

/usr/bin/grep -q '^prepend-rules:' "$PROJECT_ROOT/Rules/PuffRoute-Merge.yaml"
if /usr/bin/grep -qE '^[[:space:]]*(proxies|proxy-providers):' "$PROJECT_ROOT/Rules/PuffRoute-Merge.yaml"; then
  echo "Rule pack must not contain proxy nodes or subscriptions." >&2
  exit 1
fi

echo "PuffRoute IP risk and portable rule pack tests passed."
