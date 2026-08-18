#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)

output=$(/usr/bin/osascript -l JavaScript \
  "$PROJECT_ROOT/Scripts/cloudroute-chain-check.jxa" \
  "$PROJECT_ROOT/Tests/Fixtures/mihomo-proxies-chain.json" \
  "$PROJECT_ROOT/Tests/Fixtures/mihomo-rules-chain.json" \
  "$PROJECT_ROOT/Tests/Fixtures/mihomo-delay-chain.json" \
  "Google-Chain" \
  "PROXY")

/usr/bin/grep -q '链式策略: Google-Chain → Google-SOCKS-Exit' <<< "$output"
/usr/bin/grep -q 'Gemini 网页、Gemini API 与 Google 均命中 Google-Chain' <<< "$output"
/usr/bin/grep -q '链式中性 204 探测: 198 ms' <<< "$output"
/usr/bin/grep -q '可能绕过链式出口的手动选项: Default-Exit / DIRECT' <<< "$output"

echo "CloudRoute chain proxy tests passed."
