#!/usr/bin/env python3
"""Pure extracted-function regression tests; no live processes, services or network."""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile
import time
import shlex

ROOT = Path(__file__).resolve().parent
UUID_A = '11111111-1111-1111-1111-111111111111'
UUID_B = '22222222-2222-2222-2222-222222222222'
PROVIDER = 'com.liguangming.Shadowrocket'

def snapshot(state='connected', v4='utun7', v6='none', provider=PROVIDER, service=UUID_A):
    return 'status\tok\nservice\t' + '\t'.join([service, provider, state, v4, v6]) + '\n'

def definitions(path):
    source = path.read_text()
    parts = []
    for match in re.finditer(r'(?m)^[A-Za-z_][A-Za-z0-9_]*\(\) \{\n', source):
        end = source.index('\n}\n', match.start()) + 3
        parts.append(source[match.start():end])
    return '\n'.join(parts)

MOCK_NAMES = r"""
provider_pid_name() {
  case "$1" in
    51001|52001) /usr/bin/printf '%s\n' Shadowrocket ;;
    51002|52002) /usr/bin/printf '%s\n' MacPacketTunnel ;;
    *) return 1 ;;
  esac
}
"""
ROUTES_V4 = '\n'.join('inet ' + dest + ' utun7' for dest in ['1.1.1.1', '8.8.8.8', '9.9.9.9', '208.67.222.222'])
ROUTES_V6 = '\n'.join('inet6 ' + dest + ' unavailable' for dest in ['2606:4700:4700::1111', '2001:4860:4860::8888', '2620:fe::fe', '2620:119:35::35'])
BASE = {
    'PROXYGAUGE_PROVIDER_PIDS': '51001\n51002',
    'PROXYGAUGE_PROVIDER_PROCESS_RECORDS': '51001\tShadowrocket\tstart-a\n51002\tMacPacketTunnel\tstart-b',
    'PROXYGAUGE_CORE_PIDS': '',
    'PROXYGAUGE_DISCOVERY_LISTENER_RECORDS': '',
    'PROXYGAUGE_TRUSTED_CLIENT_TUNS': '',
    'PROXYGAUGE_TUN_ROUTE_TABLE': 'default 192.0.2.1 UGSc utun7',
    'PROXYGAUGE_ROUTE_LOOKUP_RESULTS': ROUTES_V4 + '\n' + ROUTES_V6,
    'PROXYGAUGE_NETWORK_SERVICES': snapshot(),
    'PROXYGAUGE_MIHOMO_TUN_ACTIVE': '0',
    'PROXYGAUGE_TUN_ACTIVE': '1'
}

def execute(source, command, overrides=None):
    env = dict(os.environ)
    env.update(BASE)
    if overrides:
        env.update(overrides)
    result = subprocess.run(['/bin/bash'], input=definitions(source) + '\n' + MOCK_NAMES + '\n' + command + '\n',
                            text=True, capture_output=True, env=env, timeout=10)
    if result.returncode != 0:
        raise RuntimeError(str(source) + ': ' + result.stderr)
    return result.stdout.strip()

failures = []
checks = 0

def require(name, condition, detail):
    global checks
    checks += 1
    if not condition:
        failures.append(name + ': ' + detail)

if '--fingerprint-only' not in sys.argv:
    cases = [
        ('connected-v4', {}, 'client'),
        ('foreign-utun-with-resident-mpt', {'PROXYGAUGE_NETWORK_SERVICES': snapshot(v4='utun4')}, 'other'),
        ('missing-service', {'PROXYGAUGE_NETWORK_SERVICES': 'status\tok\n'}, 'other'),
        ('unavailable-snapshot', {'PROXYGAUGE_NETWORK_SERVICES': 'status\tunavailable\n'}, 'other'),
        ('connected-foreign-service-interface-conflict', {'PROXYGAUGE_NETWORK_SERVICES': snapshot() + snapshot(provider='com.example.ForeignVPN', service=UUID_B).split('\n', 1)[1]}, 'other'),
        ('connected-foreign-cross-family-interface-conflict', {'PROXYGAUGE_NETWORK_SERVICES': snapshot() + snapshot(v4='none', v6='utun7', provider='com.example.ForeignVPN', service=UUID_B).split('\n', 1)[1]}, 'other'),
        ('unknown-provider-interface-conflict', {'PROXYGAUGE_NETWORK_SERVICES': snapshot() + snapshot(provider='unknown', service=UUID_B).split('\n', 1)[1]}, 'other'),
        ('foreign-service-other-interface', {'PROXYGAUGE_NETWORK_SERVICES': snapshot() + snapshot(v4='utun8', provider='com.example.ForeignVPN', service=UUID_B).split('\n', 1)[1]}, 'client'),
        ('foreign-provider', {'PROXYGAUGE_NETWORK_SERVICES': snapshot(provider='com.example.ForeignVPN')}, 'other'),
        ('missing-interface', {'PROXYGAUGE_NETWORK_SERVICES': snapshot(v4='none')}, 'other'),
        ('physical-interface', {'PROXYGAUGE_NETWORK_SERVICES': snapshot(v4='en0')}, 'other'),
        ('conflicting-family-interfaces', {'PROXYGAUGE_NETWORK_SERVICES': snapshot(v6='utun8')}, 'other'),
        ('multiple-shadowrocket-services', {'PROXYGAUGE_NETWORK_SERVICES': snapshot() + snapshot(service=UUID_B).split('\n', 1)[1]}, 'other'),
        ('duplicate-service-id', {'PROXYGAUGE_NETWORK_SERVICES': snapshot() + snapshot().split('\n', 1)[1]}, 'other'),
        ('malformed-row', {'PROXYGAUGE_NETWORK_SERVICES': 'status\tok\nservice\t' + UUID_A + '\t' + PROVIDER + '\tconnected\tutun7\n'}, 'other'),
        ('trusted-candidate-cannot-claim-foreign-interface', {'PROXYGAUGE_NETWORK_SERVICES': snapshot(v4='utun4'), 'PROXYGAUGE_TRUSTED_CLIENT_TUNS': 'utun7'}, 'other'),
        ('forced-client-cannot-bypass-binding', {'PROXYGAUGE_NETWORK_SERVICES': 'status\tunavailable\n', 'PROXYGAUGE_TUN_KIND': 'client'}, 'other'),
    ]
    for state in ['disconnected', 'connecting', 'disconnecting', 'invalid', 'unknown']:
        cases.append((state + '-service', {'PROXYGAUGE_NETWORK_SERVICES': snapshot(state=state)}, 'other'))
    ipv6_routes = ROUTES_V4.replace('utun7', 'unavailable') + '\n' + ROUTES_V6.replace('unavailable', 'utun7')
    cases.append(('connected-v6', {'PROXYGAUGE_NETWORK_SERVICES': snapshot(v4='none', v6='utun7'), 'PROXYGAUGE_ROUTE_LOOKUP_RESULTS': ipv6_routes}, 'client'))
    cases.append(('connected-dual', {'PROXYGAUGE_NETWORK_SERVICES': snapshot(v6='utun7'), 'PROXYGAUGE_ROUTE_LOOKUP_RESULTS': ROUTES_V4 + '\n' + ROUTES_V6.replace('unavailable', 'utun7')}, 'client'))
    for name, overrides, expected in cases:
        values = []
        for filename in ['proxygauge-backend.sh', 'proxygauge-check.sh']:
            command = 'classify_tunnel_route' if name.startswith('forced-client') else 'classify_client_tunnel_route'
            value = execute(ROOT / filename, command, overrides)
            values.append(value)
            require(name + '/' + filename, value == expected, 'expected=' + expected + ' actual=' + value)
        require(name + '/parity', values[0] == values[1], str(values))

backend = ROOT / 'proxygauge-backend.sh'
first = execute(backend, 'local_fingerprint')
second = execute(backend, 'local_fingerprint', {'PROXYGAUGE_PROVIDER_PIDS': '52001\n52002', 'PROXYGAUGE_PROVIDER_PROCESS_RECORDS': '52001\tShadowrocket\tstart-c\n52002\tMacPacketTunnel\tstart-d'})
require('provider-restart-fingerprint', first != second, 'provider PID restart is invisible')
reused = execute(backend, 'local_fingerprint', {'PROXYGAUGE_PROVIDER_PROCESS_RECORDS': '51001\tShadowrocket\tstart-c\n51002\tMacPacketTunnel\tstart-d'})
require('provider-pid-reuse-fingerprint', first != reused, 'same PIDs with new starts are invisible')
service_changed = execute(backend, 'local_fingerprint', {'PROXYGAUGE_NETWORK_SERVICES': snapshot(service=UUID_B)})
require('service-identity-fingerprint', first != service_changed, 'service UUID change is invisible')
service_lost = execute(backend, 'local_fingerprint', {'PROXYGAUGE_NETWORK_SERVICES': snapshot(state='disconnected', v4='none')})
require('service-disconnect-fingerprint', first != service_lost, 'service disconnect is invisible')
interface_changed = execute(backend, 'local_fingerprint', {'PROXYGAUGE_NETWORK_SERVICES': snapshot(v4='utun4')})
require('service-interface-fingerprint', first != interface_changed, 'service interface change is invisible')

# Native pgrep branches are exercised against an isolated process table. The
# extracted production function bodies remain unchanged apart from the reader.
if '--fingerprint-only' not in sys.argv:
    native_cases = [
        ('sr-ne', '51001\tShadowrocket\tstart-a\n51002\tMacPacketTunnel\tstart-b', '|51001,51002|Shadowrocket|MacPacketTunnel'),
        ('sr-only', '51001\tShadowrocket\tstart-a', '|51001|Shadowrocket|'),
        ('ne-only', '51002\tMacPacketTunnel\tstart-b', '|51002|Shadowrocket|MacPacketTunnel'),
        ('unknown', '51004\tpgunknownx\tstart-a', '|||'),
        ('sr-and-mihomo', '51001\tShadowrocket\tstart-a\n51002\tMacPacketTunnel\tstart-b\n51003\tmihomo\tstart-c', '51003|51001,51002,51003||'),
        ('verge', '51003\tverge-mihomo\tstart-a', '51003|51003|Clash Verge Rev|verge-mihomo'),
        ('meta', '51003\tclash-meta\tstart-a', '51003|51003|Clash / Mihomo|clash-meta'),
    ]
    fixture_reader = r"""
fixture_pgrep() {
  /usr/bin/printf '%s\n' "$PROXYGAUGE_PROVIDER_PROCESS_RECORDS" |
    /usr/bin/awk -F '\t' -v name="$2" '$2 == name {print $1; found=1} END {exit found ? 0 : 1}'
}
"""
    source = definitions(backend).replace('/usr/bin/pgrep', 'fixture_pgrep')
    for name, records, expected in native_cases:
        env = dict(os.environ)
        for key in list(env):
            if key.startswith('PROXYGAUGE_'):
                env.pop(key)
        env['PROXYGAUGE_PROVIDER_PROCESS_RECORDS'] = records
        script = source + '\n' + fixture_reader + r"""
/usr/bin/printf '%s|%s|%s|%s\n' "$(core_pids | sort -n | paste -sd, -)" \
  "$(proxy_provider_pids | sort -n | paste -sd, -)" "$(detected_running_client)" "$(detected_running_core)"
"""
        result = subprocess.run(['/bin/bash'], input=script, text=True, capture_output=True, env=env, timeout=10)
        require('native-process-table/' + name, result.returncode == 0 and result.stdout.strip() == expected, result.stdout.strip() + result.stderr)

    # Exercise the actual top-level backend wiring with no service injection.
    # The adjacent executable is a unique temporary fixture, never the SDK binary.
    with tempfile.TemporaryDirectory(prefix='proxygauge-services-reader-') as temporary:
        directory = Path(temporary)
        copied = directory / 'proxygauge-backend.sh'
        copied.write_text(backend.read_text())
        helper = directory / 'proxygauge-network-services'
        helper_cases = [
            ('missing', None, 'status\tunavailable\n', None),
            ('connected', '#!/bin/bash\n/usr/bin/printf %s ' + shlex.quote(snapshot()) + '\n', snapshot(), None),
            ('failed', '#!/bin/bash\nexit 7\n', 'status\tunavailable\n', None),
            ('malformed', '#!/bin/bash\n/usr/bin/printf invalid\n', 'status\tunavailable\n', None),
            ('timeout', '#!/bin/bash\nexec /bin/sleep 6\n', 'status\tunavailable\n', 4.75),
            ('timeout-ignores-term', '#!/usr/bin/perl\n$SIG{TERM}="IGNORE"; sleep 6;\n', 'status\tunavailable\n', 4.75),
        ]
        for name, program, expected_snapshot, elapsed_limit in helper_cases:
            if program is None:
                if helper.exists(): helper.unlink()
            else:
                helper.write_text(program)
                helper.chmod(0o700)
            env = dict(os.environ)
            env.update(BASE)
            env.pop('PROXYGAUGE_NETWORK_SERVICES', None)
            env.update({'PROXYGAUGE_CONFIG': '/dev/null', 'PROXYGAUGE_SYSTEM_PROXY_STATE': '', 'PROXYGAUGE_PF_CONF': str(directory / 'missing-pf'), 'PROXYGAUGE_KILL_STATE': str(directory / 'missing-state')})
            started = time.monotonic()
            result = subprocess.run(['/bin/bash', str(copied), 'fingerprint'], text=True, capture_output=True, env=env, timeout=10)
            elapsed = time.monotonic() - started
            expected = execute(backend, 'local_fingerprint', {'PROXYGAUGE_NETWORK_SERVICES': expected_snapshot})
            require('native-helper/' + name, result.returncode == 0 and result.stdout.strip() == expected, result.stdout.strip() + result.stderr)
            if elapsed_limit:
                require('native-helper-bound/' + name, elapsed < elapsed_limit, 'elapsed=' + str(round(elapsed, 3)))

    # Source only the real check startup through its SDK snapshot, so no
    # health probes run. A caller-owned RESOURCE_DIR must not redirect it.
    with tempfile.TemporaryDirectory(prefix='proxygauge-check-service-reader-') as temporary:
        directory = Path(temporary)
        source = (ROOT / 'proxygauge-check.sh').read_text()
        end = source.index('NETWORK_SERVICES_SNAPSHOT=$(raw_network_services_state)') + len('NETWORK_SERVICES_SNAPSHOT=$(raw_network_services_state)')
        copied = directory / 'proxygauge-check.sh'
        copied.write_text(source[:end] + '\nnetwork_services_snapshot\n')
        helper = directory / 'proxygauge-network-services'
        helper.write_text('#!/bin/bash\n/usr/bin/printf %s ' + shlex.quote(snapshot()) + '\n')
        helper.chmod(0o700)
        for inherited in [False, True]:
            env = dict(os.environ); env.update(BASE)
            env.pop('PROXYGAUGE_NETWORK_SERVICES', None)
            env.update({'PROXYGAUGE_CONFIG': '/dev/null', 'PROXYGAUGE_SYSTEM_PROXY_STATE': ''})
            env.pop('RESOURCE_DIR', None)
            if inherited: env['RESOURCE_DIR'] = str(directory / 'unrelated')
            result = subprocess.run(['/bin/bash', str(copied)], text=True, capture_output=True, env=env, timeout=10)
            expected = execute(ROOT / 'proxygauge-check.sh', 'network_services_snapshot')
            require('native-check-helper/inherited-resource-' + str(inherited), result.returncode == 0 and result.stdout.strip() == expected, result.stdout + result.stderr)

    # An unavailable service binding must not erase independently verified
    # ownership of the current system-proxy endpoint, or claim its foreign TUN.
    with tempfile.TemporaryDirectory(prefix='proxygauge-endpoint-identity-') as temporary:
        directory = Path(temporary)
        env = dict(os.environ); env.update(BASE)
        env.update({
            'PROXYGAUGE_CONFIG': '/dev/null',
            'PROXYGAUGE_NETWORK_SERVICES': 'status\tunavailable\n',
            'PROXYGAUGE_DISCOVERY_CLIENT': 'Shadowrocket',
            'PROXYGAUGE_DISCOVERY_SYSTEM_PROXY': '127.0.0.1:1082',
            'PROXYGAUGE_SYSTEM_PROXY_STATE': '<dictionary> {\n  HTTPEnable : 1\n  HTTPProxy : 127.0.0.1\n  HTTPPort : 1082\n  HTTPSEnable : 1\n  HTTPSProxy : 127.0.0.1\n  HTTPSPort : 1082\n}',
            'PROXYGAUGE_SYSTEM_PROXY_ACTIVE': '1',
            'PROXYGAUGE_SYSTEM_PROXY_DYNAMIC': '0',
            'PROXYGAUGE_DISCOVERY_PORT_ACTIVE': '1',
            'PROXYGAUGE_DISCOVERY_CONFIG': str(directory / 'missing.yaml'),
            'PROXYGAUGE_DISCOVERY_SOCKET': str(directory / 'missing.sock'),
            'PROXYGAUGE_MIHOMO_SOCKET': str(directory / 'missing.sock'),
            'PROXYGAUGE_PF_CONF': str(directory / 'missing-pf'),
            'PROXYGAUGE_KILL_STATE': str(directory / 'missing-state'),
        })
        for name, records, client, core in [
            ('owned-system-foreign-tun', 'p51002\nn127.0.0.1:1082', 'Shadowrocket', 'MacPacketTunnel'),
            ('unowned-system-foreign-tun', 'p51999\nn127.0.0.1:1082', '未识别', ''),
        ]:
            env['PROXYGAUGE_DISCOVERY_LISTENER_RECORDS'] = records
            result = subprocess.run(['/bin/bash', str(backend), 'discover'], text=True, capture_output=True, env=env, timeout=10)
            fields = dict(line.split('\t', 1) for line in result.stdout.splitlines() if '\t' in line)
            require('endpoint-independent/' + name, result.returncode == 0 and fields.get('client') == client and fields.get('core') == core and fields.get('mode') == '系统代理 + 其他 VPN / TUN', result.stdout + result.stderr)

    # Read-only Guard snapshot: metadata is fixture-injected only in this
    # extracted test body, so production still requires uid 0 on the anchor.
    with tempfile.TemporaryDirectory(prefix='proxygauge-monitor-snapshot-') as temporary:
        directory = Path(temporary)
        anchor = directory / 'anchor'
        pf = directory / 'pf.conf'; pf.write_text('anchor "proxygauge"\n')
        state = directory / 'state'; state.write_text('enabled\n'); state.chmod(0o600)
        token = directory / 'token'; token.write_text('fixture')
        template = (ROOT.parent / 'PF/proxygauge.conf.template').read_text()
        monitoring = template.replace('__TUN_INTERFACES__', 'lo0 utun7').replace('__BLOCK_ALL_RULE__\n', '')
        metadata_stub = r"""
fixture_stat() {
  if [ "$3" = "$PF_ANCHOR" ]; then
    case "$2" in
      %u) echo "${TEST_ANCHOR_OWNER:-0}" ;;
      %Lp) echo "${TEST_ANCHOR_MODE:-644}" ;;
      %z) /usr/bin/stat -f %z "$3" ;;
      *) return 1 ;;
    esac
  elif [ "$3" = "$KILL_STATE" ] && [ "$2" = "%u" ] && [ -n "${TEST_STATE_OWNER:-}" ]; then
    echo "$TEST_STATE_OWNER"
  else
    /usr/bin/stat "$@"
  fi
}
"""
        monitor_cases = [
            ('trusted-ne-monitor', monitoring, {}, 'enabled', True, '监测中\tok'),
            ('missing-ne-marker', monitoring.replace('# For a selected user-space network extension the catch-all is a placeholder:\n', ''), {}, 'enabled', True, '已开启\tok'),
            ('empty-anchor', '', {}, 'enabled', True, '已开启\tok'),
            ('arbitrary-anchor', 'pass out quick all\n', {}, 'enabled', True, '已开启\tok'),
            ('catchall-present', monitoring + 'block return out quick all\n', {}, 'enabled', True, '已开启\tok'),
            ('other-block-present', monitoring + 'block out on en0 all\n', {}, 'enabled', True, '已开启\tok'),
            ('unrendered-template', template, {}, 'enabled', True, '已开启\tok'),
            ('wrong-pass-rules', monitoring.replace('pass out quick all user = 0 keep state (if-bound)', 'pass out quick all'), {}, 'enabled', True, '已开启\tok'),
            ('untrusted-owner', monitoring, {'TEST_ANCHOR_OWNER': '501'}, 'enabled', True, '已开启\tok'),
            ('writable-anchor', monitoring, {'TEST_ANCHOR_MODE': '666'}, 'enabled', True, '已开启\tok'),
            ('disabled-monitor-file', monitoring, {}, 'disabled', False, '已关闭\twarning'),
            ('disabled-with-token-conflict', monitoring, {}, 'disabled', True, '待确认\tidle'),
            ('invalid-state', monitoring, {}, 'invalid', False, '待确认\tidle'),
            ('missing-state', monitoring, {'TEST_STATE_MISSING': '1'}, 'enabled', False, '待确认\tidle'),
            ('state-symlink', monitoring, {'TEST_STATE_SYMLINK': '1'}, 'enabled', False, '待确认\tidle'),
            ('untrusted-state-mode', monitoring, {'TEST_STATE_MODE': '666'}, 'enabled', False, '待确认\tidle'),
            ('untrusted-state-owner', monitoring, {'TEST_STATE_OWNER': '999'}, 'enabled', False, '待确认\tidle'),
            ('enabled-pf-missing', monitoring, {'TEST_PF_MISSING': '1'}, 'enabled', True, '需要修复\terror'),
            ('unconfigured-no-state', monitoring, {'TEST_PF_MISSING': '1', 'TEST_STATE_MISSING': '1'}, 'enabled', False, '未配置\tidle'),
            ('fault-monitor-file', monitoring, {}, 'fault', True, '需要修复\terror'),
            ('token-missing', monitoring, {}, 'enabled', False, '恢复中\twarning'),
            ('anchor-symlink', monitoring, {}, 'enabled', True, '已开启\tok'),
        ]
        source = definitions(backend).replace('/usr/bin/stat', 'fixture_stat')
        for name, content, overrides, state_value, token_present, expected in monitor_cases:
            if anchor.exists() or anchor.is_symlink(): anchor.unlink()
            anchor.write_text(content)
            if name == 'anchor-symlink':
                real = directory / 'real-anchor'; real.write_text(content)
                anchor.unlink(); anchor.symlink_to(real)
            if state.exists() or state.is_symlink(): state.unlink()
            state.write_text(state_value + '\n')
            state.chmod(int(overrides.get('TEST_STATE_MODE', '600'), 8))
            if overrides.get('TEST_STATE_MISSING'): state.unlink()
            if overrides.get('TEST_STATE_SYMLINK'):
                real_state = directory / 'real-state'; real_state.write_text(state_value + '\n')
                state.unlink(); state.symlink_to(real_state)
            if pf.exists(): pf.unlink()
            if not overrides.get('TEST_PF_MISSING'): pf.write_text('anchor "proxygauge"\n')
            if token_present: token.write_text('fixture')
            elif token.exists(): token.unlink()
            env = dict(os.environ)
            env.update({'TEST_ANCHOR_OWNER': '0', 'TEST_ANCHOR_MODE': '644'})
            env.update(overrides)
            script = source + '\n' + metadata_stub + '\n' + '\n'.join(key + '=' + shlex.quote(str(value)) for key, value in {
                'PF_CONF': pf, 'PF_ANCHOR': anchor, 'KILL_STATE': state, 'DEFAULT_KILL_STATE': '/var/run/proxygauge-killswitch.state', 'KILL_TOKEN': token,
            }.items()) + '\nkill_switch_snapshot\n'
            result = subprocess.run(['/bin/bash'], input=script, text=True, capture_output=True, env=env, timeout=10)
            require('monitor-snapshot/' + name, result.returncode == 0 and result.stdout.strip() == expected, result.stdout.strip() + result.stderr)
if failures:
    print('\n'.join('FAIL ' + item for item in failures))
    print(str(len(failures)) + ' failures across ' + str(checks) + ' checks')
    sys.exit(1)
print('Network-service attribution and lifecycle fingerprint: ' + str(checks) + ' checks passed.')
