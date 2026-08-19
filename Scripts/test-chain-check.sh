#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)

output=$(/usr/bin/osascript -l JavaScript \
  "$PROJECT_ROOT/Scripts/cloudlink-guard-chain-check.jxa" \
  "$PROJECT_ROOT/Tests/Fixtures/mihomo-proxies-chain.json" \
  "$PROJECT_ROOT/Tests/Fixtures/mihomo-rules-chain.json" \
  "$PROJECT_ROOT/Tests/Fixtures/mihomo-delay-chain.json" \
  "Google-Chain" \
  "PROXY" \
  "gemini.google.com,generativelanguage.googleapis.com,www.google.com" \
  "Google / Gemini")

/usr/bin/grep -q '链式策略: Google-Chain → Google-SOCKS-Exit' <<< "$output"
/usr/bin/grep -q '3 个目标域名均命中 Google-Chain' <<< "$output"
/usr/bin/grep -q 'Google / Gemini 中性 204 探测: 198 ms' <<< "$output"
/usr/bin/grep -q '可能绕过链式出口的手动选项: Default-Exit / DIRECT' <<< "$output"

custom_output=$(/usr/bin/osascript -l JavaScript \
  "$PROJECT_ROOT/Scripts/cloudlink-guard-chain-check.jxa" \
  "$PROJECT_ROOT/Tests/Fixtures/mihomo-proxies-chain.json" \
  "$PROJECT_ROOT/Tests/Fixtures/mihomo-rules-chain.json" \
  "$PROJECT_ROOT/Tests/Fixtures/mihomo-delay-chain.json" \
  "Google-Chain" \
  "PROXY" \
  "www.google.com" \
  "工作出口")
/usr/bin/grep -q '1 个目标域名均命中 Google-Chain' <<< "$custom_output"
/usr/bin/grep -q '工作出口 中性 204 探测: 198 ms' <<< "$custom_output"

echo "CloudCheck chain proxy tests passed."
