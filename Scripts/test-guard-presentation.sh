#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
TEMP_ROOT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/proxygauge-guard-presentation.XXXXXX")
cleanup() { /bin/rm -rf "$TEMP_ROOT"; }
trap cleanup EXIT

# Compile the real policy/ProxyModel adapter and the real Dashboard Binding.
# Only the model's action sinks and palette are in-memory stubs. No app, probe,
# backend, preferences, admin helper, network or protection operation is started.
python3 - "$PROJECT_ROOT" "$TEMP_ROOT" <<'PY'
from pathlib import Path
import re
import sys

root, temporary = map(Path, sys.argv[1:])
app = (root / 'Sources/ProxyGaugeApp.swift').read_text()
dashboard = (root / 'Sources/DashboardView.swift').read_text()

def block(source, signature):
    start = source.index(signature)
    cursor = source.index('{', start) + 1
    depth = 1
    while depth:
        if source[cursor] == '{': depth += 1
        elif source[cursor] == '}': depth -= 1
        cursor += 1
    return source[start:cursor]

health = block(app, 'enum HealthLevel:')
metric = block(app, 'struct MetricState:')
binding = block(dashboard, 'private var guardToggleBinding:')
binding = binding.replace('private var', 'var', 1)
card = block(dashboard, 'private var protectionCard:')
visibility = re.search(r'if ([^\n]+) \{\s*Toggle\("", isOn: guardToggleBinding\)', card)
if not visibility or card.count('Toggle(') != 1:
    raise SystemExit('The actual Guard card must render its sole Toggle only under its state policy.')
if not re.search(r'else \{\s*Image\(systemName: model\.guardPresentation\.statusSymbol\)', card):
    raise SystemExit('Unknown/recovering/fault Guard states must have a neutral status indicator, not a false OFF switch.')
for wiring in [
    'Text(model.guardPresentation.title)',
    '.foregroundStyle(model.guardPresentation.level.color)',
    '.disabled(model.isBusy)',
    '.help(model.guardPresentation.help)',
]:
    if wiring not in card:
        raise SystemExit('The actual Guard card is missing policy wiring: ' + wiring)
if 'model.killSwitch.level == .ok' in card or 'model.killSwitch.level == .ok' in binding:
    raise SystemExit('Health level must not be used as the Guard enabled flag.')

shim = '''import Foundation
import SwiftUI

enum CloudPalette {
 static let statusGreen = Color.green
 static let statusOrange = Color.orange
 static let statusRed = Color.red
 static let statusGray = Color.gray
}
__HEALTH__
__METRIC__
@MainActor final class ProxyModel {
 var killSwitch: MetricState
 var isBusy = false
 var enableCalls = 0
 var showDisableConfirmation = false
 init(value: String, level: HealthLevel) {
  killSwitch = MetricState(title: "Kill Switch", symbol: "shield", value: value, level: level)
 }
 func enableKillSwitch() { enableCalls += 1 }
}
@MainActor struct GuardDashboardBindingProbe {
 let model: ProxyModel
 var showsToggle: Bool { __VISIBILITY__ }
 __BINDING__
}
'''
shim = shim.replace('__HEALTH__', health).replace('__METRIC__', metric)
shim = shim.replace('__VISIBILITY__', visibility.group(1)).replace('__BINDING__', binding)
(temporary / 'actual-dashboard-binding.swift').write_text(shim)
PY

/usr/bin/xcrun swiftc \
  -target arm64-apple-macosx26.0 \
  -parse-as-library \
  -module-cache-path "$TEMP_ROOT/module-cache" \
  "$PROJECT_ROOT/Sources/GuardPresentation.swift" \
  "$TEMP_ROOT/actual-dashboard-binding.swift" \
  "$PROJECT_ROOT/Tests/GuardPresentationCheck.swift" \
  -o "$TEMP_ROOT/guard-presentation-check"
"$TEMP_ROOT/guard-presentation-check"
