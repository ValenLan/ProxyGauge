#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
CHECK="$PROJECT_ROOT/Scripts/cloudroute-check.sh"
APP_SOURCE="$PROJECT_ROOT/Sources/CloudRouteApp.swift"
WINDOWS_MODEL="$PROJECT_ROOT/Windows/Models/HealthReport.cs"
WINDOWS_SERVICE="$PROJECT_ROOT/Windows/Services/HealthCheckService.cs"
WINDOWS_MAIN="$PROJECT_ROOT/Windows/MainWindow.xaml"

/usr/bin/grep -Fq 'ACTIVE_AI_PROBES="${CLOUDROUTE_ACTIVE_AI_PROBES:-${PUFFROUTE_ACTIVE_AI_PROBES:-0}}"' "$CHECK"
/usr/bin/grep -Fq 'GEMINI_PROBE_PROXY="$MIXED"' "$CHECK"
/usr/bin/grep -Fq 'GEMINI_PROBE_PROXY="$GOOGLE_MIXED"' "$CHECK"
/usr/bin/grep -q 'url=https://cp.cloudflare.com/generate_204' "$CHECK"
/usr/bin/grep -q 'dscacheutil -q host -a name www.cloudflare.com' "$CHECK"
/usr/bin/grep -Fq 'SECONDARY_ENABLED="${CLOUDROUTE_SECONDARY_ENABLED:-auto}"' "$CHECK"
/usr/bin/grep -Fq 'run_secondary_checks() {' "$CHECK"
/usr/bin/grep -Fq '===== 6. 主动平台探测 (手动启用) =====' "$CHECK"
/usr/bin/grep -Fq '===== 7. 分流确认 (默认低风险模式) =====' "$CHECK"
/usr/bin/grep -Fq '===== 8. 出口结论 (不新增外部请求) =====' "$CHECK"
/usr/bin/grep -Fq '系统代理与 TUN 同时开启 — 通常只需保留一个流量入口' "$CHECK"

if /usr/bin/grep -q '社区深度复核\|Claude 登录会话验证\|ChatGPT 登录会话验证' "$CHECK"; then
  echo "Manual browser and account checks must stay outside the routine health report." >&2
  exit 1
fi

if /usr/bin/grep -q 'check_site "\(ChatGPT\|Claude\) ' "$CHECK"; then
  echo "Account-facing web probes must not run from the health check." >&2
  exit 1
fi

if /usr/bin/grep -q 'www.google.com/generate_204' "$CHECK"; then
  echo "AI-safe mode must not use a Google connectivity endpoint." >&2
  exit 1
fi

if /usr/bin/grep -Fq 'check no "尚未确认 Gemini 的独立出口 IP"' "$CHECK"; then
  echo "Optional chain diagnostics must not fail an otherwise healthy default route." >&2
  exit 1
fi

score_weights=$(/usr/bin/awk '
  /private static let standardWeights:/ {mode="standard"; next}
  /private static let extendedWeights:/ {mode="extended"; next}
  mode != "" && /^    ]/ {print mode "=" sum; mode=""; sum=0; next}
  mode != "" && /"[1-8]":/ {gsub(/,/, "", $2); sum += $2}
' "$APP_SOURCE")
/usr/bin/grep -Fq 'standard=100' <<< "$score_weights"
/usr/bin/grep -Fq 'extended=100' <<< "$score_weights"
/usr/bin/grep -Fq 'value = min(value, 49)' "$APP_SOURCE"
/usr/bin/grep -Fq 'sectionWeights[$0.number] != nil && $0.hasFailure' "$APP_SOURCE"
/usr/bin/grep -Fq 'Label("\(report.planName) · 高级检测不计分"' "$APP_SOURCE"
/usr/bin/grep -Fq '.progressViewStyle(.linear)' "$APP_SOURCE"

/usr/bin/grep -Fq 'new HealthCheckSection("本地代理", localItems, 45, IsCritical: true)' "$WINDOWS_SERVICE"
/usr/bin/grep -Fq 'new HealthCheckSection("代理出口", [exitResult.Item], 30, IsCritical: true)' "$WINDOWS_SERVICE"
/usr/bin/grep -Fq 'new HealthCheckSection("IP 风险画像", riskItems, 15)' "$WINDOWS_SERVICE"
/usr/bin/grep -Fq 'new HealthCheckSection("检测边界（默认低风险模式）"' "$WINDOWS_SERVICE"
/usr/bin/grep -Fq 'snapshot.SystemProxyEnabled && snapshot.TunDetected' "$WINDOWS_SERVICE"
/usr/bin/grep -Fq '                ], 10)' "$WINDOWS_SERVICE"
/usr/bin/grep -Fq 'value = Math.Min(value, 49)' "$WINDOWS_MODEL"
/usr/bin/grep -Fq 'Binding="{Binding IsHealthCheckRunning}"' "$WINDOWS_MAIN"

generic_output=$(CLOUDROUTE_CONFIG=/dev/null \
  CLOUDROUTE_MIXED=127.0.0.1:9 \
  CLOUDROUTE_SECONDARY_ENABLED=0 \
  CLOUDROUTE_ACTIVE_AI_PROBES=0 \
  CLOUDROUTE_TIMEOUT=1 \
  /bin/bash "$CHECK" 2>&1 || true)
/usr/bin/grep -Fq '检测方案: 通用检测' <<< "$generic_output"
[ "$(/usr/bin/grep -c '^===== [1-8]\.' <<< "$generic_output")" = "5" ]
if /usr/bin/grep -Fq '===== 6.' <<< "$generic_output"; then
  echo "The generic plan must not render optional placeholder sections." >&2
  exit 1
fi

extended_output=$(CLOUDROUTE_CONFIG=/dev/null \
  CLOUDROUTE_MIXED=127.0.0.1:9 \
  CLOUDROUTE_SECONDARY_ENABLED=1 \
  CLOUDROUTE_SECONDARY_MIXED=127.0.0.1:10 \
  CLOUDROUTE_MIHOMO_SOCKET=/private/tmp/cloudroute-missing-test.sock \
  CLOUDROUTE_ACTIVE_AI_PROBES=0 \
  CLOUDROUTE_TIMEOUT=1 \
  /bin/bash "$CHECK" 2>&1 || true)
/usr/bin/grep -Fq '检测方案: 通用检测 + Google / Gemini' <<< "$extended_output"
[ "$(/usr/bin/grep -c '^===== [1-8]\.' <<< "$extended_output")" = "8" ]

echo "CloudRoute low-risk health tests passed."
