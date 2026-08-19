#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
APP_SOURCE="$PROJECT_ROOT/Sources/CloudRouteApp.swift"
WINDOWS_RESOURCES="$PROJECT_ROOT/Windows/App.xaml"
WINDOWS_MAIN="$PROJECT_ROOT/Windows/MainWindow.xaml"

/usr/bin/grep -Fq 'case .ok: return CloudPalette.statusGreen' "$APP_SOURCE"
/usr/bin/grep -Fq 'case .idle: return CloudPalette.statusGray' "$APP_SOURCE"
/usr/bin/grep -Fq 'MetricCard(metric: model.core)' "$APP_SOURCE"
/usr/bin/grep -Fq 'MetricCard(metric: model.port)' "$APP_SOURCE"
/usr/bin/grep -Fq 'MetricCard(metric: model.entry)' "$APP_SOURCE"
/usr/bin/grep -Fq 'parsed["entry"] ?? parsed["tun"]' "$APP_SOURCE"
/usr/bin/grep -Fq 'metric.title = fields[2]' "$APP_SOURCE"
/usr/bin/grep -Fq 'metric.symbol = fields[3]' "$APP_SOURCE"
/usr/bin/grep -Fq 'static let minimumWidth: CGFloat = 640' "$APP_SOURCE"
/usr/bin/grep -Fq 'static let minimumContentHeight: CGFloat = 448' "$APP_SOURCE"
/usr/bin/grep -Fq 'static let defaultWidth: CGFloat = 680' "$APP_SOURCE"
/usr/bin/grep -Fq 'static let defaultHeight: CGFloat = 500' "$APP_SOURCE"
/usr/bin/grep -Fq 'Window("CloudRoute", id: "main")' "$APP_SOURCE"
/usr/bin/grep -Fq '.windowResizability(.contentMinSize)' "$APP_SOURCE"
/usr/bin/grep -Fq '.frame(maxWidth: .infinity, minHeight: 72)' "$APP_SOURCE"
/usr/bin/grep -Fq 'static let actionTitle = Font.system(size: 14, weight: .semibold)' "$APP_SOURCE"
/usr/bin/grep -Fq 'static let actionDetail = Font.system(size: 10.5)' "$APP_SOURCE"
/usr/bin/grep -Fq '.tint(CloudPalette.statusGreen)' "$APP_SOURCE"
/usr/bin/grep -Fq 'private struct DashboardActionCard: View' "$APP_SOURCE"
/usr/bin/grep -Fq 'actionLabel: "检测"' "$APP_SOURCE"
/usr/bin/grep -Fq 'actionLabel: "打开"' "$APP_SOURCE"
/usr/bin/grep -Fq 'actionLabel: "管理"' "$APP_SOURCE"
/usr/bin/grep -Fq 'actionSymbol: "arrow.up.right"' "$APP_SOURCE"
/usr/bin/grep -Fq 'actionSymbol: "play.fill"' "$APP_SOURCE"
/usr/bin/grep -Fq 'return ["基础链路", "出口一致", "IP 风险"]' "$APP_SOURCE"
/usr/bin/grep -Fq 'return ["基础链路", "IP 风险", "\(plan.secondaryLabel) 分流"]' "$APP_SOURCE"
/usr/bin/grep -Fq 'scopeLabels.joined(separator: "  ·  ")' "$APP_SOURCE"
/usr/bin/grep -Fq 'detail: isRunning ? "正在按方案检测…" : "按当前方案检查连接"' "$APP_SOURCE"
/usr/bin/grep -Fq '.fill(tint.opacity(isHovering ? 0.24 : 0.14))' "$APP_SOURCE"
/usr/bin/grep -Fq 'private struct DiagnosticActionButtonStyle: ButtonStyle' "$APP_SOURCE"
/usr/bin/grep -Fq '.buttonStyle(DiagnosticActionButtonStyle())' "$APP_SOURCE"
/usr/bin/grep -Fq '.allowsHitTesting(!isDisabled)' "$APP_SOURCE"
/usr/bin/grep -Fq 'showsProgress: true' "$APP_SOURCE"
/usr/bin/grep -Fq 'Text(discovery.found ? "已找到本地代理" : "连接本地代理")' "$APP_SOURCE"
/usr/bin/grep -Fq 'confirm("127.0.0.1:\(port)")' "$APP_SOURCE"
/usr/bin/grep -Fq '仅读取本地端口与运行模式，不读取订阅和节点' "$APP_SOURCE"
/usr/bin/grep -Fq 'Button(action: model.openConnectionSetup)' "$APP_SOURCE"
/usr/bin/grep -Fq '.interactiveDismissDisabled()' "$APP_SOURCE"
/usr/bin/grep -Fq 'private struct HealthPlanSetupView: View' "$APP_SOURCE"
/usr/bin/grep -Fq 'Text("链路检测方案")' "$APP_SOURCE"
/usr/bin/grep -Fq 'Toggle(isOn: $draft.secondaryEnabled)' "$APP_SOURCE"
/usr/bin/grep -Fq '@Published var showHealthPlanSetup = false' "$APP_SOURCE"
/usr/bin/grep -Fq '.foregroundStyle(CloudPalette.networkBlue)' "$APP_SOURCE"

if /usr/bin/grep -q 'MetricCard(metric: .*accent:' "$APP_SOURCE"; then
  echo "Read-only status cards must not use per-card accent colors." >&2
  exit 1
fi

if /usr/bin/grep -Fq 'guardTeal' "$APP_SOURCE"; then
  echo "Kill Switch must use the shared protection green." >&2
  exit 1
fi

if /usr/bin/grep -Fq '.frame(width: 276)' "$APP_SOURCE"; then
  echo "The health action must stay on its own row in the 4:3 main window." >&2
  exit 1
fi

if /usr/bin/grep -Fq 'ActionTriggerLabel' "$APP_SOURCE"; then
  echo "Diagnostic actions must not regress to standalone pill buttons." >&2
  exit 1
fi

if /usr/bin/grep -Fq '.windowResizability(.contentSize)' "$APP_SOURCE"; then
  echo "The main macOS window must remain user-resizable." >&2
  exit 1
fi

/usr/bin/grep -Fq 'x:Key="RulesBrush"' "$WINDOWS_RESOURCES"
/usr/bin/grep -Fq 'Foreground="{StaticResource RulesBrush}"' "$WINDOWS_MAIN"

echo "CloudRoute UI color semantics tests passed."
