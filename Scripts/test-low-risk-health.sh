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
/usr/bin/grep -q 'Gemini API.*"\$GOOGLE_MIXED"' "$CHECK"
/usr/bin/grep -q 'url=https://cp.cloudflare.com/generate_204' "$CHECK"
/usr/bin/grep -q 'dscacheutil -q host -a name www.cloudflare.com' "$CHECK"
/usr/bin/grep -Fq '未启用 Google / Gemini 链式策略组；跳过可选链式出口探针' "$CHECK"
/usr/bin/grep -Fq '未启用独立 Google / Gemini 链式出口；跳过可选出口确认' "$CHECK"
/usr/bin/grep -Fq '===== 7. AI 路由确认 (默认低风险模式) =====' "$CHECK"
/usr/bin/grep -Fq '===== 8. 双出口结论 (不新增外部请求) =====' "$CHECK"

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

score_weight=$(/usr/bin/awk '
  /private static let sectionWeights:/ {in_weights=1; next}
  in_weights && /^    ]/ {print sum; exit}
  in_weights && /"[1-8]":/ {gsub(/,/, "", $2); sum += $2}
' "$APP_SOURCE")
[ "$score_weight" = "100" ]
/usr/bin/grep -Fq 'value = min(value, 49)' "$APP_SOURCE"
/usr/bin/grep -Fq 'Label("关键链路加权；高级检测不计分"' "$APP_SOURCE"
/usr/bin/grep -Fq '.progressViewStyle(.linear)' "$APP_SOURCE"

/usr/bin/grep -Fq 'new HealthCheckSection("本地代理", localItems, 45, IsCritical: true)' "$WINDOWS_SERVICE"
/usr/bin/grep -Fq 'new HealthCheckSection("代理出口", [exitResult.Item], 30, IsCritical: true)' "$WINDOWS_SERVICE"
/usr/bin/grep -Fq 'new HealthCheckSection("IP 风险画像", riskItems, 15)' "$WINDOWS_SERVICE"
/usr/bin/grep -Fq 'new HealthCheckSection("AI 路由确认（默认低风险模式）"' "$WINDOWS_SERVICE"
/usr/bin/grep -Fq '                ], 10)' "$WINDOWS_SERVICE"
/usr/bin/grep -Fq 'value = Math.Min(value, 49)' "$WINDOWS_MODEL"
/usr/bin/grep -Fq 'Binding="{Binding IsHealthCheckRunning}"' "$WINDOWS_MAIN"

echo "CloudRoute low-risk health tests passed."
