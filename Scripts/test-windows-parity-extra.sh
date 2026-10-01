#!/bin/bash
set -euo pipefail

PROJECT_ROOT=$(cd "$([ -n "${BASH_SOURCE[0]:-}" ] && /usr/bin/dirname "${BASH_SOURCE[0]}" || /usr/bin/dirname "$0")/.." && /bin/pwd)

PROBE_SERVICE="$PROJECT_ROOT/Windows/Services/ProxyProbeService.cs"
DISCOVERY_SERVICE="$PROJECT_ROOT/Windows/Services/ConnectionDiscoveryService.cs"
MAIN_VIEW_MODEL="$PROJECT_ROOT/Windows/ViewModels/MainViewModel.cs"
GUARD_CPP="$PROJECT_ROOT/Windows.Guard/Guard.cpp"

# The generic-core list must live inside the CoreProcessNames array itself so a
# stray mention elsewhere in the file cannot mask a removed entry.
core_names_block=$(/usr/bin/awk '/CoreProcessNames =/,/\];/' "$PROBE_SERVICE")
if [ -z "$core_names_block" ]; then
  echo 'ProxyProbeService.cs must declare the CoreProcessNames array.' >&2
  exit 1
fi
for coreName in '"xray"' '"v2ray"' '"sing-box"' '"singbox"' '"Shadowsocksr"'; do
  if ! /usr/bin/printf '%s\n' "$core_names_block" | /usr/bin/grep -Fq "$coreName"; then
    echo "CoreProcessNames must keep the generic proxy core $coreName." >&2
    exit 1
  fi
done
if /usr/bin/grep -Fq '"v2rayN"' <<< "$core_names_block"; then
  echo 'v2rayN GUI must not count as a second traffic engine alongside Xray/V2Ray.' >&2
  exit 1
fi
/usr/bin/grep -Fq 'Contains("v2rayn", StringComparison.OrdinalIgnoreCase)' "$PROBE_SERVICE"

for coreName in '"verge-mihomo"' '"mihomo"' '"clash-meta"'; do
  if ! /usr/bin/printf '%s\n' "$core_names_block" | /usr/bin/grep -Fq "$coreName"; then
    echo "CoreProcessNames must retain the Mihomo-family core $coreName alongside the generic cores." >&2
    exit 1
  fi
done

/usr/bin/grep -Fq '未发现代理客户端或核心' "$PROBE_SERVICE"
/usr/bin/grep -Fq '未发现代理客户端或核心' "$DISCOVERY_SERVICE"

# No Windows or Guard code may fall back to a hardcoded Clash / Mihomo label
# merely because some core process count is positive.
if /usr/bin/grep -rEn \
  'coreCount[[:space:]]*>[[:space:]]*[0-9]+[[:space:]]*\?[[:space:]]*"|CountProxyCores\(\)[[:space:]]*>[[:space:]]*[0-9]+[[:space:]]*\?|\?[[:space:]]*"Clash / Mihomo"|\?[[:space:]]*"Mihomo / Clash"|\?[[:space:]]*"Mihomo"[[:space:]]*:' \
  "$PROJECT_ROOT/Windows" "$PROJECT_ROOT/Windows.Guard"; then
  echo 'An unidentified running core must never be labeled Clash / Mihomo from a core-count fallback.' >&2
  exit 1
fi

# The common mixed-port fallback list must keep serving the mainstream clients.
common_ports_line=$(/usr/bin/grep -E 'CommonMixedPorts = \[' "$DISCOVERY_SERVICE")
for port in 1082 1080 10808; do
  if ! /usr/bin/printf '%s\n' "$common_ports_line" | /usr/bin/grep -Eq "(^|[^0-9])${port}([^0-9]|$)"; then
    echo "CommonMixedPorts must keep the fallback port $port." >&2
    exit 1
  fi
done

/usr/bin/grep -Fq 'L"wireguard"' "$GUARD_CPP"
/usr/bin/grep -Fq 'name.find(L"wireguard") != std::wstring::npos' "$GUARD_CPP"
if [ "$(/usr/bin/grep -Fc 'L"wireguard"' "$GUARD_CPP")" -lt 2 ]; then
  echo 'Guard.cpp must recognize WireGuard both as a core process name and as a tunnel adapter keyword.' >&2
  exit 1
fi

# The connection detail must be composed from the detected client, never a constant.
/usr/bin/grep -Fq 'BuildConnectionClientDetail(' "$MAIN_VIEW_MODEL"
/usr/bin/grep -Fq 'return $"{client} · {core}";' "$MAIN_VIEW_MODEL"
connection_detail_block=$(/usr/bin/awk '/public string ConnectionDetail =>/,/^$/ { print }' "$MAIN_VIEW_MODEL")
/usr/bin/grep -Fq '_detectedCoreName,' <<< "$connection_detail_block"
/usr/bin/grep -Fq '_detectedClientName,' <<< "$connection_detail_block"
if /usr/bin/grep -Fq '_activeGuardApplication' <<< "$connection_detail_block"; then
  echo 'The current proxy subtitle must not be sourced from a saved guard application.' >&2
  exit 1
fi
/usr/bin/grep -Fq '_detectedCoreName = snapshot.DetectedCoreName;' "$MAIN_VIEW_MODEL"
/usr/bin/grep -Fq '_detectedCoreName = null;' "$MAIN_VIEW_MODEL"
/usr/bin/grep -Fq 'DetectedCoreName = detectedCoreName,' "$PROBE_SERVICE"
identity_resolver_block=$(/usr/bin/awk '/internal static string\? ResolveDetectedClientName\(/,/internal static string\? DetectCoreName\(/ { print }' "$PROBE_SERVICE")
/usr/bin/grep -Fq 'systemProxy.ExplicitHost!, systemProxy.ExplicitPort!.Value' <<< "$identity_resolver_block"
if /usr/bin/grep -Fq 'DetectRunningProxyClientName' <<< "$identity_resolver_block"; then
  echo 'A resident GUI must not supply attribution for an unrelated current OS route.' >&2
  exit 1
fi
if /usr/bin/grep -Fq 'Mihomo ·' "$MAIN_VIEW_MODEL"; then
  echo 'ConnectionDetail must not hardcode a Mihomo client label.' >&2
  exit 1
fi

echo 'ProxyGauge Windows parity extra static checks passed.'
