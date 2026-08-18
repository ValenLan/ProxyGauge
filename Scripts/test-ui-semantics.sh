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
/usr/bin/grep -Fq 'MetricCard(metric: model.tun)' "$APP_SOURCE"
/usr/bin/grep -Fq 'static let width: CGFloat = 640' "$APP_SOURCE"
/usr/bin/grep -Fq 'static let contentHeight: CGFloat = 448' "$APP_SOURCE"
/usr/bin/grep -Fq '.frame(maxWidth: .infinity, minHeight: 72)' "$APP_SOURCE"

if /usr/bin/grep -q 'MetricCard(metric: .*accent:' "$APP_SOURCE"; then
  echo "Read-only status cards must not use per-card accent colors." >&2
  exit 1
fi

if /usr/bin/grep -Fq '.frame(width: 276)' "$APP_SOURCE"; then
  echo "The health action must stay on its own row in the 4:3 main window." >&2
  exit 1
fi

/usr/bin/grep -Fq 'x:Key="RulesBrush"' "$WINDOWS_RESOURCES"
/usr/bin/grep -Fq 'Foreground="{StaticResource RulesBrush}"' "$WINDOWS_MAIN"

echo "CloudRoute UI color semantics tests passed."
