#!/bin/bash
set -euo pipefail

PROJECT_ROOT=$(/usr/bin/cd "$([ -n "${BASH_SOURCE[0]:-}" ] && /usr/bin/dirname "${BASH_SOURCE[0]}" || /usr/bin/dirname "$0")/.." && /bin/pwd)

for xaml in \
  Windows/App.xaml \
  Windows/MainWindow.xaml \
  Windows/SettingsWindow.xaml \
  Windows/HealthReportWindow.xaml \
  Windows/DetectionPlanWindow.xaml \
  Windows/AdvancedDetectionWindow.xaml; do
  /usr/bin/xmllint --noout "$PROJECT_ROOT/$xaml"
done

/usr/bin/grep -Fq 'SecondaryEnabled' "$PROJECT_ROOT/Windows/Models/AppConfig.cs"
/usr/bin/grep -Fq 'Mihomo 本地控制接口' "$PROJECT_ROOT/Windows/Services/ConnectionDiscoveryService.cs"
/usr/bin/grep -Fq 'Windows 系统代理' "$PROJECT_ROOT/Windows/Services/ConnectionDiscoveryService.cs"
/usr/bin/grep -Fq 'LocalEndpointPolicy.IsLoopbackHost' "$PROJECT_ROOT/Windows/SettingsWindow.xaml.cs"
/usr/bin/grep -Fq 'LocalEndpointPolicy.NormalizeLoopbackHost' "$PROJECT_ROOT/Windows/Services/ConfigService.cs"
/usr/bin/grep -Fq 'LocalEndpointPolicy.IsLoopbackHost' "$PROJECT_ROOT/Windows/Services/HealthCheckService.cs"
/usr/bin/grep -Fq 'Mihomo 控制接口' "$PROJECT_ROOT/Windows/Services/MihomoPlanInspectionService.cs"
/usr/bin/grep -Fq '默认入口与额外入口返回不同公网出口' "$PROJECT_ROOT/Windows/Services/HealthCheckService.cs"
/usr/bin/grep -Fq -- '--user-data-dir=' "$PROJECT_ROOT/Windows/Services/PrivateBrowserService.cs"
/usr/bin/grep -Fq -- '--proxy-server=' "$PROJECT_ROOT/Windows/Services/PrivateBrowserService.cs"
/usr/bin/grep -Fq 'proxygauge-browser.' "$PROJECT_ROOT/Windows/Services/PrivateBrowserService.cs"
/usr/bin/grep -Fq 'PlanButton_Click' "$PROJECT_ROOT/Windows/MainWindow.xaml"
/usr/bin/grep -Fq 'AdvancedButton_Click' "$PROJECT_ROOT/Windows/MainWindow.xaml"
/usr/bin/grep -Fq 'Windows.Tests/ProxyGauge.Windows.Tests.csproj' "$PROJECT_ROOT/.github/workflows/build.yml"
/usr/bin/grep -Fq 'Remote hostnames must be rejected.' "$PROJECT_ROOT/Windows.Tests/Program.cs"

if /usr/bin/grep -Eq 'GetRawText\(' "$PROJECT_ROOT/Windows/Services/MihomoPlanInspectionService.cs"; then
  echo 'Windows plan inspection must not render raw Mihomo controller data.' >&2
  exit 1
fi

echo 'ProxyGauge Windows parity static checks passed.'
