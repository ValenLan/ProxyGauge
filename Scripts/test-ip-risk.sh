#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)

output=$(/usr/bin/osascript -l JavaScript \
  "$PROJECT_ROOT/Scripts/cloudroute-ip-risk.jxa" \
  "$PROJECT_ROOT/Tests/Fixtures/ipapi-risk.json" \
  "$PROJECT_ROOT/Tests/Fixtures/proxycheck-risk.json" \
  "$PROJECT_ROOT/Tests/Fixtures/peeringdb-risk.json" \
  "203.0.113.8")

/usr/bin/grep -q '网络归属: AS64500 · Example ASN' <<< "$output"
/usr/bin/grep -q 'ASN 属性: ISP / 网络服务商（PeeringDB）' <<< "$output"
/usr/bin/grep -q 'IP 段用途: 托管 / 数据中心（proxycheck.io）' <<< "$output"
/usr/bin/grep -q '风险分: 42/100（中） · 置信度 96%' <<< "$output"
/usr/bin/grep -q '地址风险标签: 数据中心 / 滥用记录' <<< "$output"
/usr/bin/grep -q '滥用指标: 组织 0.014 (Elevated) · ASN 0.0072 (Low)' <<< "$output"
/usr/bin/grep -q '第三方 IP 情报仅供参考，不代表浏览器环境或具体服务可用性' <<< "$output"

asn=$(/usr/bin/osascript -l JavaScript \
  "$PROJECT_ROOT/Scripts/cloudroute-ip-risk.jxa" \
  extract-asn \
  "$PROJECT_ROOT/Tests/Fixtures/ipapi-risk.json" \
  "$PROJECT_ROOT/Tests/Fixtures/proxycheck-risk.json" \
  "203.0.113.8")
[ "$asn" = "64500" ]

compact_asn=$(/usr/bin/osascript -l JavaScript \
  "$PROJECT_ROOT/Scripts/cloudroute-ip-risk.jxa" \
  extract-asn \
  "$PROJECT_ROOT/Tests/Fixtures/ipapi-risk-compact.json" \
  "$PROJECT_ROOT/Tests/Fixtures/empty-response.txt" \
  "203.0.113.8")
[ "$compact_asn" = "64501" ]

compact_output=$(/usr/bin/osascript -l JavaScript \
  "$PROJECT_ROOT/Scripts/cloudroute-ip-risk.jxa" \
  "$PROJECT_ROOT/Tests/Fixtures/ipapi-risk-compact.json" \
  "$PROJECT_ROOT/Tests/Fixtures/empty-response.txt" \
  "$PROJECT_ROOT/Tests/Fixtures/empty-response.txt" \
  "203.0.113.8")
/usr/bin/grep -q '网络归属: AS64501 · Compact Example ISP' <<< "$compact_output"
/usr/bin/grep -q '地区: US' <<< "$compact_output"

fallback_output=$(/usr/bin/osascript -l JavaScript \
  "$PROJECT_ROOT/Scripts/cloudroute-ip-risk.jxa" \
  "$PROJECT_ROOT/Tests/Fixtures/ipapi-risk.json" \
  "$PROJECT_ROOT/Tests/Fixtures/proxycheck-risk.json" \
  "$PROJECT_ROOT/Tests/Fixtures/empty-response.txt" \
  "203.0.113.8")
/usr/bin/grep -q 'ASN 属性: 托管 / 数据中心（ipapi.is）' <<< "$fallback_output"

/usr/bin/grep -Fq '个查询源确认出口一致' "$PROJECT_ROOT/Scripts/cloudroute-check.sh"
/usr/bin/grep -Fq '触发 Cloudflare challenge' "$PROJECT_ROOT/Scripts/cloudroute-check.sh"
/usr/bin/grep -Fq 'TUN DNS 返回 Fake-IP' "$PROJECT_ROOT/Scripts/cloudroute-check.sh"
/usr/bin/grep -Fq '第三方 IP 情报仅供参考' "$PROJECT_ROOT/Scripts/cloudroute-ip-risk.jxa"
/usr/bin/grep -Fq '额外分流链路 ($SECONDARY_LABEL)' "$PROJECT_ROOT/Scripts/cloudroute-check.sh"
/usr/bin/grep -Fq 'https://browserleaks.com/ip' "$PROJECT_ROOT/Scripts/cloudroute-private-browser.sh"
/usr/bin/grep -Fq 'https://iphey.com/' "$PROJECT_ROOT/Scripts/cloudroute-private-browser.sh"
/usr/bin/grep -Fq 'https://scamalytics.com/ip/$EXIT_IP' "$PROJECT_ROOT/Scripts/cloudroute-private-browser.sh"

/usr/bin/grep -q '^prepend-rules:' "$PROJECT_ROOT/Rules/CloudRoute-Merge.yaml"
if /usr/bin/grep -qE '^[[:space:]]*(proxies|proxy-providers):' "$PROJECT_ROOT/Rules/CloudRoute-Merge.yaml"; then
  echo "Rule pack must not contain proxy nodes or subscriptions." >&2
  exit 1
fi

echo "CloudRoute IP risk and portable rule pack tests passed."
