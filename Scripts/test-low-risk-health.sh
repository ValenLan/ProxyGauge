#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
CHECK="$PROJECT_ROOT/Scripts/proxygauge-check.sh"
APP_SOURCE="$PROJECT_ROOT/Sources/ProxyGaugeApp.swift"
WINDOWS_MODEL="$PROJECT_ROOT/Windows/Models/HealthReport.cs"
WINDOWS_SERVICE="$PROJECT_ROOT/Windows/Services/HealthCheckService.cs"
WINDOWS_MAIN="$PROJECT_ROOT/Windows/MainWindow.xaml"

/usr/bin/grep -Fq 'ACTIVE_AI_PROBES="${PROXYGAUGE_ACTIVE_AI_PROBES:-0}"' "$CHECK"
/usr/bin/grep -Fq 'GEMINI_PROBE_PROXY="$MIXED"' "$CHECK"
/usr/bin/grep -Fq 'GEMINI_PROBE_PROXY="$GOOGLE_MIXED"' "$CHECK"
/usr/bin/grep -q 'url=https://cp.cloudflare.com/generate_204' "$CHECK"
/usr/bin/grep -q 'dscacheutil -q host -a name www.cloudflare.com' "$CHECK"
/usr/bin/grep -Fq 'SECONDARY_ENABLED="${PROXYGAUGE_SECONDARY_ENABLED:-auto}"' "$CHECK"
/usr/bin/grep -Fq 'run_secondary_checks() {' "$CHECK"
/usr/bin/grep -Fq '===== 5. 主动平台探测 (手动启用) =====' "$CHECK"
/usr/bin/grep -Fq '===== 6. 分流确认 (不访问账号站点) =====' "$CHECK"
/usr/bin/grep -Fq '===== 7. 出口结论 (不新增外部请求) =====' "$CHECK"
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

if /usr/bin/grep -Eqi 'ipapi\.is|proxycheck\.io|peeringdb' "$CHECK" "$WINDOWS_SERVICE"; then
  echo "Routine link checks must not submit exit IPs to reputation services." >&2
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
/usr/bin/grep -Fq 'Label("\(report.planName) · IP 纯净度复核不计分"' "$APP_SOURCE"
/usr/bin/grep -Fq '.progressViewStyle(.linear)' "$APP_SOURCE"

/usr/bin/grep -Fq 'new HealthCheckSection("本地代理", localItems, 45, IsCritical: true)' "$WINDOWS_SERVICE"
/usr/bin/grep -Fq 'new HealthCheckSection("代理出口", [exitResult.Item], 45, IsCritical: true)' "$WINDOWS_SERVICE"
/usr/bin/grep -Fq 'new HealthCheckSection($"{config.SecondaryLabel} · 策略与规则", planItems, 20, IsCritical: true)' "$WINDOWS_SERVICE"
/usr/bin/grep -Fq 'CreateBoundarySection(10)' "$WINDOWS_SERVICE"
/usr/bin/grep -Fq 'new("检测边界（默认低风险模式）"' "$WINDOWS_SERVICE"
/usr/bin/grep -Fq 'snapshot.SystemProxyEnabled && snapshot.TunDetected' "$WINDOWS_SERVICE"
/usr/bin/grep -Fq 'value = Math.Min(value, 49)' "$WINDOWS_MODEL"
if /usr/bin/grep -Fq 'Click="HealthButton_Click"' "$WINDOWS_MAIN"; then
  echo "The redesigned dashboard must not expose the removed routine link-check action." >&2
  exit 1
fi

generic_output=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_MIXED=127.0.0.1:9 \
  PROXYGAUGE_SECONDARY_ENABLED=0 \
  PROXYGAUGE_ACTIVE_AI_PROBES=0 \
  PROXYGAUGE_TIMEOUT=1 \
  /bin/bash "$CHECK" 2>&1 || true)
/usr/bin/grep -Fq '检测方案: 通用检测' <<< "$generic_output"
[ "$(/usr/bin/grep -c '^===== [1-7]\.' <<< "$generic_output")" = "4" ]
if /usr/bin/grep -Fq '===== 5.' <<< "$generic_output"; then
  echo "The generic plan must not render optional placeholder sections." >&2
  exit 1
fi

extended_output=$(PROXYGAUGE_CONFIG=/dev/null \
  PROXYGAUGE_MIXED=127.0.0.1:9 \
  PROXYGAUGE_SECONDARY_ENABLED=1 \
  PROXYGAUGE_SECONDARY_MIXED=127.0.0.1:10 \
  PROXYGAUGE_MIHOMO_SOCKET=/private/tmp/proxygauge-missing-test.sock \
  PROXYGAUGE_ACTIVE_AI_PROBES=0 \
  PROXYGAUGE_TIMEOUT=1 \
  /bin/bash "$CHECK" 2>&1 || true)
/usr/bin/grep -Fq '检测方案: 通用检测 + Google / Gemini / Claude' <<< "$extended_output"
[ "$(/usr/bin/grep -c '^===== [1-7]\.' <<< "$extended_output")" = "7" ]

echo "ProxyGauge low-risk health tests passed."
