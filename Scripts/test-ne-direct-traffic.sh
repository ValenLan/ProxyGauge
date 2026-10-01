#!/bin/bash
set -euo pipefail

# test-ne-direct-traffic.sh — Shadowrocket MacPacketTunnel 直连现实回归。
# 事故背景：NE 会为 DIRECT 规则流量向任意目的 IP 发起物理连接，旧的端点钉扎
# 模型把出口钉死在 VPS 上，开启 Kill Switch 即断网。监控/锁定状态机是必须钉住的
# 不变量：
#   ① 监控态渲染产物逐行扫描不含任何 block/drop 规则；
#   ② 监控态下任意新目的 IP 的出站不被 anchor 限制（从渲染产物语义证明）；
#   ③ 锁定态 block-all 存在且 lo0/LAN/root 豁免在其之前；
#   ④ 只读实机段：MacPacketTunnel 存活时用 lsof+route 断言其持有至少一条
#      非 VPS 的公网直连；进程不存在或条件不满足时打印 SKIP，不得 fail。

SCRIPT_DIR=$(/usr/bin/dirname "$0")
HELPER="$SCRIPT_DIR/proxygauge-killswitch"
TEMPLATE="$SCRIPT_DIR/../PF/proxygauge.conf.template"
TEST_ROOT=$(/usr/bin/mktemp -d /tmp/proxygauge-killswitch-test.XXXXXX)
trap '/bin/rm -rf "$TEST_ROOT"' EXIT
PERSIST_HELPER="$TEST_ROOT/Library/PrivilegedHelperTools/com.valenlan.proxygauge.killswitch"
RUNTIME_STATE="$TEST_ROOT/var/run/proxygauge-killswitch.state"
ANCHOR_CONF="$TEST_ROOT/etc/pf.anchors/proxygauge"

checks=0
pass() { checks=$((checks + 1)); }

fail() {
  /usr/bin/printf '%s\n' "FAIL: $1" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# 最小 PF quick-rule 求值器：只支持模板能渲染出的规则形状，按 quick 语义
# 取第一条匹配规则决定 verdict；无匹配时按 PF 默认策略放行。
# 用法: awk -v iface=X -v uid=N -v dest=IP -v dir=out -f pf-eval.awk anchor
# 输出: pass 或 block
# ---------------------------------------------------------------------------
PF_EVAL="$TEST_ROOT/pf-eval.awk"
/bin/cat > "$PF_EVAL" <<'EVALUATOR'
function ip4int(s, p) { split(s, p, "."); return p[1]*16777216 + p[2]*65536 + p[3]*256 + p[4] }
function cidr4_match(net, pfx, ip, d) {
  if (ip !~ /^[0-9.]+$/ || net !~ /^[0-9.]+$/) return 0
  if (pfx+0 == 0) return 1
  d = 2^(32-pfx)
  return int(ip4int(net)/d) == int(ip4int(ip)/d)
}
function in_table(tname, ip, i, w) {
  for (i = 1; i <= tn[tname]; i++) {
    split(tables[tname,i], w, "/")
    if (w[2] == "") w[2] = 32
    if (cidr4_match(w[1], w[2]+0, ip)) return 1
  }
  return 0
}
function in_macro(mname, name, i) {
  for (i = 1; i <= mn[mname]; i++) if (macros[mname,i] == name) return 1
  return 0
}
/^[[:space:]]*table[[:space:]]+</ {
  line = $0
  match(line, /<[^>]+>/)
  tname = substr(line, RSTART+1, RLENGTH-2)
  sub(/.*\{/, "", line); sub(/\}.*/, "", line)
  gsub(/,/, " ", line)
  n = split(line, items, /[[:space:]]+/)
  for (i = 1; i <= n; i++) if (items[i] != "") { tn[tname]++; tables[tname,tn[tname]] = items[i] }
  next
}
/^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ {
  line = $0
  split(line, kv, "=")
  mname = kv[1]; gsub(/[[:space:]]/, "", mname)
  rest = kv[2]; gsub(/["{}]/, "", rest)
  n = split(rest, items, /[[:space:]]+/)
  for (i = 1; i <= n; i++) if (items[i] != "") { mn[mname]++; macros[mname,mn[mname]] = items[i] }
  next
}
/^[[:space:]]*(pass|block)([[:space:]]|$)/ {
  action = $1
  i = 2
  if (action == "block" && $i !~ /^(in|out|quick|on|all|from|inet)/) i++
  rdir = ""; rquick = 0; ron = ""; rfrom = ""; rto = ""; ruser = ""
  while (i <= NF) {
    tok = $i
    if (tok == "in" || tok == "out") rdir = tok
    else if (tok == "quick") rquick = 1
    else if (tok == "on") { i++; ron = $i }
    else if (tok == "from") { i++; rfrom = $i }
    else if (tok == "to") { i++; rto = $i }
    else if (tok == "user") { i++; if ($i == "=") i++; ruser = $i }
    else if (tok == "keep" || tok == "modulate" || tok == "synproxy") break
    i++
  }
  matched = 1
  if (rdir != "" && rdir != dir) matched = 0
  if (matched && ron != "") {
    if (ron ~ /^\$/) { if (!in_macro(substr(ron, 2), iface)) matched = 0 }
    else if (ron != iface) matched = 0
  }
  if (matched && rfrom != "" && rfrom != "any") matched = 0
  if (matched && rto != "" && rto != "any") {
    if (rto ~ /^</) { tname = rto; gsub(/[<>]/, "", tname); if (!in_table(tname, dest)) matched = 0 }
    else if (rto != dest) matched = 0
  }
  if (matched && ruser != "" && ruser+0 != uid+0) matched = 0
  if (matched && rquick) { print action; exit }
}
END { if (!matched) print "pass" }
EVALUATOR

pf_verdict() {
  /usr/bin/awk -v iface="$2" -v uid="$3" -v dest="$4" -v dir="$5" -f "$PF_EVAL" "$1"
}

expect_verdict() {
  local anchor="$1" iface="$2" uid="$3" dest="$4" dir="$5" want="$6" why="$7"
  local got
  got=$(pf_verdict "$anchor" "$iface" "$uid" "$dest" "$dir")
  [ "$got" = "$want" ] || fail "$why (iface=$iface uid=$uid dest=$dest: 期望 $want，实际 $got)"
  pass
}

# ---------------------------------------------------------------------------
# Hermetic harness（与 test-killswitch.sh 同构）：mock pfctl 只写 TEST_ROOT。
# Fake PID 段 53000-53999。
# ---------------------------------------------------------------------------
/bin/mkdir -p "$TEST_ROOT/etc/pf.anchors" "$TEST_ROOT/bin" "$TEST_ROOT/var/run"
/usr/bin/printf '%s\n' \
  'set skip on lo0' \
  'scrub-anchor "com.apple/*" all fragment reassemble' \
  'pass out quick all' \
  'anchor "com.apple/*"' > "$TEST_ROOT/etc/pf.conf"
/usr/bin/printf '%s\n' \
  '#!/bin/bash' \
  'state_dir="$PROXYGAUGE_KILLSWITCH_TEST_ROOT/var/run/pfctl-state"' \
  '/bin/mkdir -p "$state_dir"' \
  '/usr/bin/printf "%s\\n" "$*" >> "$PROXYGAUGE_KILLSWITCH_TEST_ROOT/var/run/pfctl.log"' \
  'if [ "$1" = "-s" ] && [ "${2:-}" = "info" ]; then echo "Status: Enabled"; exit 0; fi' \
  'if [ "$1" = "-E" ]; then echo "Token : 12345"; exit 0; fi' \
  'if [ "$1" = "-sr" ]; then' \
  '  source="$state_dir/main.conf"' \
  '  [ -r "$source" ] || source="$PROXYGAUGE_KILLSWITCH_TEST_ROOT/etc/pf.conf"' \
  '  /usr/bin/awk '\''/^[[:space:]]*(scrub-anchor|anchor|block|pass|match|antispoof)([[:space:]]|$)/ { sub(/^[[:space:]]*/, ""); print }'\'' "$source"' \
  '  exit 0' \
  'fi' \
  'if [ "$1" = "-a" ] && [ "${2:-}" = "proxygauge" ] && [ "${3:-}" = "-sr" ]; then' \
  '  [ ! -r "$state_dir/anchor.conf" ] || /bin/cat "$state_dir/anchor.conf"' \
  '  exit 0' \
  'fi' \
  'if [ "$1" = "-a" ] && [ "${2:-}" = "proxygauge" ] && [ "${3:-}" = "-f" ]; then' \
  '  /bin/cp "$4" "$state_dir/anchor.conf"; exit 0' \
  'fi' \
  'if [ "$1" = "-a" ] && [ "${2:-}" = "proxygauge" ] && [ "${3:-}" = "-F" ]; then' \
  '  : > "$state_dir/anchor.conf"; exit 0' \
  'fi' \
  'if [ "$1" = "-f" ]; then /bin/cp "$2" "$state_dir/main.conf"; exit 0; fi' \
  'exit 0' > "$TEST_ROOT/bin/pfctl"
/bin/chmod 755 "$TEST_ROOT/bin/pfctl"

run_helper() {
  PROXYGAUGE_KILLSWITCH_TEST_ROOT="$TEST_ROOT" \
  PROXYGAUGE_KILLSWITCH_TEST_PFCTL="$TEST_ROOT/bin/pfctl" \
  PROXYGAUGE_KILLSWITCH_TEST_INTERFACES="${PROXYGAUGE_KILLSWITCH_TEST_INTERFACES:-en0 en1}" \
  PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES="${PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES-utun0}" \
  PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_PID="${PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_PID-53001}" \
  PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_DEVICE="${PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_DEVICE-${PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES:-utun0}}" \
  PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="${PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS-verge-mihomo:53001:0}" \
  PROXYGAUGE_KILLSWITCH_TEST_PS_OUTPUT="${PROXYGAUGE_KILLSWITCH_TEST_PS_OUTPUT-}" \
  /bin/bash "$HELPER" "$@"
}

run_persisted_helper() {
  PROXYGAUGE_KILLSWITCH_TEST_ROOT="$TEST_ROOT" \
  PROXYGAUGE_KILLSWITCH_TEST_PFCTL="$TEST_ROOT/bin/pfctl" \
  PROXYGAUGE_KILLSWITCH_TEST_INTERFACES="${PROXYGAUGE_KILLSWITCH_TEST_INTERFACES:-en0 en1}" \
  PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES="${PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES-utun0}" \
  PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_PID="${PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_PID-53001}" \
  PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_DEVICE="${PROXYGAUGE_KILLSWITCH_TEST_ACTIVE_DEVICE-${PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES:-utun0}}" \
  PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="${PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS-verge-mihomo:53001:0}" \
  PROXYGAUGE_KILLSWITCH_TEST_PS_OUTPUT="${PROXYGAUGE_KILLSWITCH_TEST_PS_OUTPUT-}" \
  /bin/bash "$PERSIST_HELPER" "$@"
}

# Shadowrocket.app 与 MacPacketTunnel 是同一 NE 提供者的两个进程。
ne_records='Shadowrocket:53100:501:/Applications/Shadowrocket.app/Contents/MacOS/Shadowrocket:ne
MacPacketTunnel:53101:501:/Applications/Shadowrocket.app/Contents/PlugIns/MacPacketTunnel.appex/Contents/MacOS/MacPacketTunnel:ne'

# 任意新目的 IP：固定公网样本 + 运行时从 /dev/urandom 抽样的公网 IPv4。
random_public_ipv4() {
  local attempt a b c d
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    read -r a b c d <<EOF
$(/usr/bin/od -An -tu1 -N4 /dev/urandom)
EOF
    case "$a" in ''|*[!0-9]*) continue ;; esac
    [ "$a" -eq 0 ] || [ "$a" -eq 10 ] || [ "$a" -eq 127 ] || [ "$a" -ge 224 ] && continue
    { [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ]; } && continue
    { [ "$a" -eq 169 ] && [ "$b" -eq 254 ]; } && continue
    { [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ]; } && continue
    { [ "$a" -eq 192 ] && [ "$b" -eq 168 ]; } && continue
    { [ "$a" -eq 192 ] && [ "$b" -eq 0 ]; } && continue
    { [ "$a" -eq 198 ] && { [ "$b" -eq 18 ] || [ "$b" -eq 19 ] || [ "$b" -eq 51 ]; }; } && continue
    { [ "$a" -eq 203 ] && [ "$b" -eq 0 ]; } && continue
    /usr/bin/printf '%s.%s.%s.%s\n' "$a" "$b" "$c" "$d"
    return 0
  done
  /usr/bin/printf '%s\n' '203.0.113.231'
}

rand_ip_a=$(random_public_ipv4)
rand_ip_b=$(random_public_ipv4)
new_dest_ips="1.1.1.1 8.8.8.8 198.51.100.77 203.0.113.231 $rand_ip_a $rand_ip_b"

# ---------------------------------------------------------------------------
# 初始安装（root 核心），再切换到 NE 监控态。
# ---------------------------------------------------------------------------
run_helper on >/dev/null
ne_on_output=$(PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$ne_records" run_helper on)
/usr/bin/printf '%s\n' "$ne_on_output" | /usr/bin/grep -Fq 'Kill Switch 已开启'
pass
[ "$(/usr/bin/sed -n '2p' "${RUNTIME_STATE%.state}.selection")" = '/Applications/Shadowrocket.app/Contents/MacOS/Shadowrocket' ]
pass

# ---------------------------------------------------------------------------
# 不变量①：监控态渲染产物（磁盘与运行时加载两份）逐行扫描无任何 block/drop。
# ---------------------------------------------------------------------------
monitoring_anchor="$TEST_ROOT/monitoring.anchor"
/bin/cp "$ANCHOR_CONF" "$monitoring_anchor"
runtime_monitoring_anchor="$TEST_ROOT/runtime-monitoring.anchor"
PROXYGAUGE_KILLSWITCH_TEST_ROOT="$TEST_ROOT" "$TEST_ROOT/bin/pfctl" -a proxygauge -sr > "$runtime_monitoring_anchor"

for artifact in "$monitoring_anchor" "$runtime_monitoring_anchor"; do
  if /usr/bin/awk '/^[[:space:]]*(block|drop)([[:space:]]|$)/ { found = 1 } END { exit !found }' "$artifact"; then
    fail "监控态渲染产物不得包含任何 block/drop 规则: $artifact"
  fi
  pass
  [ "$(/usr/bin/awk '/^[[:space:]]*pass([[:space:]]|$)/ { n++ } END { print n+0 }' "$artifact")" -eq 4 ]
  pass
done
[ ! -e "$TEST_ROOT/var/db/proxygauge/ne-endpoints" ]
pass

# ---------------------------------------------------------------------------
# 不变量②：语义证明监控态下任意新目的 IP 的出站不被 anchor 限制。
# 非 root 用户经渲染时不存在的全新物理接口 en9 访问新公网 IP 必须 pass；
# 同批报文稍后对锁定态产物求值必须 block（对照组，证明求值器可区分）。
# ---------------------------------------------------------------------------
for dest in $new_dest_ips; do
  expect_verdict "$monitoring_anchor" en9 501 "$dest" out pass \
    '监控态 anchor 不得限制任意新目的 IP 的出站'
  expect_verdict "$runtime_monitoring_anchor" en9 501 "$dest" out pass \
    '监控态运行时 anchor 不得限制任意新目的 IP 的出站'
done
expect_verdict "$monitoring_anchor" utun0 501 1.1.1.1 out pass \
  '监控态可信 utun 出站必须放行'
expect_verdict "$monitoring_anchor" lo0 501 127.0.0.1 out pass \
  '监控态 lo0 必须放行'

# ---------------------------------------------------------------------------
# 不变量③：锁定态 block-all 存在，且 lo0/LAN/root 豁免在其之前。
# NE 丢失公网路由 utun 后，armed restore 自动进入锁定态。
# ---------------------------------------------------------------------------
: > "$TEST_ROOT/var/run/pfctl.log"
PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$ne_records" \
  PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES='' \
  run_persisted_helper restore >/dev/null
lockdown_anchor="$TEST_ROOT/lockdown.anchor"
/bin/cp "$ANCHOR_CONF" "$lockdown_anchor"

[ "$(/usr/bin/awk '/^[[:space:]]*block([[:space:]]|$)/ { n++ } END { print n+0 }' "$lockdown_anchor")" -eq 1 ]
pass
/usr/bin/grep -Fq 'block return out quick all' "$lockdown_anchor"
pass
/usr/bin/grep -Fq 'trusted_tunnels = "{ lo0 }"' "$lockdown_anchor"
pass

block_line=$(/usr/bin/awk '/^[[:space:]]*block return out quick all([[:space:]]|$)/ { print NR; exit }' "$lockdown_anchor")
lo0_line=$(/usr/bin/awk '/^[[:space:]]*pass quick on lo0 all([[:space:]]|$)/ { print NR; exit }' "$lockdown_anchor")
lan_line=$(/usr/bin/awk '/^[[:space:]]*pass out quick from any to <proxygauge_lan>/ { print NR; exit }' "$lockdown_anchor")
root_line=$(/usr/bin/awk '/^[[:space:]]*pass out quick all user = 0([[:space:]]|$)/ { print NR; exit }' "$lockdown_anchor")
[ -n "$block_line" ] && [ -n "$lo0_line" ] && [ -n "$lan_line" ] && [ -n "$root_line" ]
pass
[ "$lo0_line" -lt "$block_line" ] || fail 'lo0 豁免必须位于 block-all 之前'
pass
[ "$lan_line" -lt "$block_line" ] || fail 'LAN 豁免必须位于 block-all 之前'
pass
[ "$root_line" -lt "$block_line" ] || fail 'root 豁免必须位于 block-all 之前'
pass

# 语义对照：锁定态新目的 IP 被 block；lo0/LAN/root 豁免仍然生效。
for dest in $new_dest_ips; do
  expect_verdict "$lockdown_anchor" en9 501 "$dest" out block \
    '锁定态必须阻断任意新目的 IP 的出站（对照组，证明求值器可区分）'
done
expect_verdict "$lockdown_anchor" en9 0 1.1.1.1 out pass \
  '锁定态 root 豁免必须生效'
expect_verdict "$lockdown_anchor" en9 501 192.168.1.20 out pass \
  '锁定态 LAN 豁免必须生效'
expect_verdict "$lockdown_anchor" lo0 501 127.0.0.1 out pass \
  '锁定态 lo0 豁免必须生效'
expect_verdict "$lockdown_anchor" utun0 501 1.1.1.1 out block \
  '锁定态无公网路由 utun，utun 出站也必须被 block-all 拦截'

# 进入锁定态的瞬间必须清理监控态积累的物理公网状态，且只清理一次。
/usr/bin/grep -Fq -- '-k 0.0.0.0/0 -k ' "$TEST_ROOT/var/run/pfctl.log"
pass
/usr/bin/grep -Fq -- '-k ::/0 -k ' "$TEST_ROOT/var/run/pfctl.log"
pass
! /usr/bin/grep -Fq -- '-F states' "$TEST_ROOT/var/run/pfctl.log"
pass

# ---------------------------------------------------------------------------
# 状态机回翻：隧道以新设备名恢复后回到监控态，block 再次消失（真实翻转）。
# ---------------------------------------------------------------------------
PROXYGAUGE_KILLSWITCH_TEST_CORE_RECORDS="$ne_records" \
  PROXYGAUGE_KILLSWITCH_TEST_TUN_INTERFACES='utun3' \
  run_persisted_helper restore >/dev/null
/usr/bin/grep -Fq 'trusted_tunnels = "{ lo0 utun3 }"' "$ANCHOR_CONF"
pass
if /usr/bin/awk '/^[[:space:]]*(block|drop)([[:space:]]|$)/ { found = 1 } END { exit !found }' "$ANCHOR_CONF"; then
  fail '隧道恢复后必须回到监控态（渲染产物无任何 block/drop 规则）'
fi
pass
for dest in $new_dest_ips; do
  expect_verdict "$ANCHOR_CONF" en9 501 "$dest" out pass \
    '回翻监控态后任意新目的 IP 出站必须再次放行'
done

# ---------------------------------------------------------------------------
# 辅助静态门禁：端点钉扎模型不得以任何形式回归。
# ---------------------------------------------------------------------------
/usr/bin/grep -Fq '__TUN_INTERFACES__|__BLOCK_ALL_RULE__|__NE_ENDPOINT_RULES__' "$HELPER"
pass
if /usr/bin/grep -qE '__NE_ENDPOINT_RULES__|ne_endpoints|NE_ENDPOINTS' "$TEMPLATE"; then
  fail 'PF 模板不得重新引入 NE 端点钉扎占位符或表'
fi
pass
if /usr/bin/grep -qE '>[[:space:]]*"?\$NE_ENDPOINTS_FILE' "$HELPER"; then
  fail 'helper 只允许删除 NE 端点文件，不得再写入钉扎内容'
fi
pass

# ---------------------------------------------------------------------------
# 不变量④：只读实机段。MacPacketTunnel 存活时，它必须持有至少一条非 VPS 的
# 公网直连（DIRECT 规则流量由 NE 物理直出）。判定：lsof 取公网 TCP 远端，
# route -n get 解析到物理口的远端记为 VPS（主机路由钉扎），解析到 utun* 的
# 记为直连候选。若一个 VPS 都识别不到（本机 Shadowrocket 不钉主机路由），
# 唯一候选可能就是 VPS 本身，故此时要求至少两个不同远端才足以证明存在非
# VPS 直连。进程不存在或条件不满足时打印 SKIP，不得 fail。全程只读。
# ---------------------------------------------------------------------------
if ! /usr/bin/pgrep -x MacPacketTunnel >/dev/null 2>&1; then
  echo 'SKIP: MacPacketTunnel 未运行，实机 NE 直连不变量未验证'
else
  ne_pids=$(/usr/bin/pgrep -x MacPacketTunnel | /usr/bin/paste -sd, -)
  ne_remotes=$(/usr/sbin/lsof -nP -a -p "$ne_pids" -iTCP 2>/dev/null | /usr/bin/awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /->/) {
          split($i, parts, "->")
          remote = parts[2]
          sub(/:[0-9]+$/, "", remote)
          gsub(/[\[\]]/, "", remote)
          if (remote != "" && remote != "*") print remote
        }
      }
    }' | /usr/bin/sort -u)
  direct_count=0
  vps_count=0
  public_count=0
  while IFS= read -r remote; do
    [ -n "$remote" ] || continue
    case "$remote" in
      *:*)
        case "$remote" in
          ::1|fe80:*|fe80::*|fc*|fd*|ff*) continue ;;
        esac
        family=-inet6
        ;;
      *)
        IFS=. read -r ra rb rc rd <<EOF
$remote
EOF
        case "$ra" in ''|*[!0-9]*) continue ;; esac
        [ "$ra" -eq 0 ] || [ "$ra" -eq 10 ] || [ "$ra" -eq 127 ] || [ "$ra" -ge 224 ] && continue
        { [ "$ra" -eq 100 ] && [ "$rb" -ge 64 ] && [ "$rb" -le 127 ]; } && continue
        { [ "$ra" -eq 169 ] && [ "$rb" -eq 254 ]; } && continue
        { [ "$ra" -eq 172 ] && [ "$rb" -ge 16 ] && [ "$rb" -le 31 ]; } && continue
        { [ "$ra" -eq 192 ] && [ "$rb" -eq 168 ]; } && continue
        { [ "$ra" -eq 192 ] && [ "$rb" -eq 0 ]; } && continue
        { [ "$ra" -eq 198 ] && { [ "$rb" -eq 18 ] || [ "$rb" -eq 19 ]; }; } && continue
        family=-inet
        ;;
    esac
    public_count=$((public_count + 1))
    route_iface=$(/sbin/route -n get "$family" "$remote" 2>/dev/null \
      | /usr/bin/awk '/interface:/ { print $2; exit }')
    case "$route_iface" in
      utun*) direct_count=$((direct_count + 1)) ;;
      '') ;;
      *) vps_count=$((vps_count + 1)) ;;
    esac
  done <<EOF
$ne_remotes
EOF
  if [ "$public_count" -eq 0 ]; then
    echo 'SKIP: MacPacketTunnel 存活但无可观测公网 TCP 连接，实机 NE 直连不变量未验证'
  elif [ "$direct_count" -eq 0 ]; then
    echo "SKIP: MacPacketTunnel 公网连接全部经物理口主机路由（VPS=${vps_count}），当前无可观测 DIRECT 直连"
  elif [ "$vps_count" -eq 0 ] && [ "$direct_count" -eq 1 ]; then
    echo 'SKIP: MacPacketTunnel 仅有 1 个经 utun 的公网远端且 VPS 无法识别，无法区分 VPS 与 DIRECT 直连'
  else
    /usr/bin/printf '%s\n' "REAL-MACHINE: MacPacketTunnel 持有 ${direct_count} 个经 utun 的公网直连远端（VPS=${vps_count} 个经物理口钉扎），DIRECT 直出不变量成立"
    pass
  fi
fi

echo "ProxyGauge NE direct-traffic monitor/lockdown invariants passed ($checks assertions)."
