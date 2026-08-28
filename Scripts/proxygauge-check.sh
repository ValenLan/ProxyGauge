#!/bin/bash
# ProxyGauge 代理链路检测脚本
# 用法: bash ~/.local/bin/proxygauge-check
# 退出码: 0 = 链路检查通过; 1 = 有失败项

DEFAULT_CONFIG="$HOME/.config/proxygauge/config"

CONFIG_FILE="${PROXYGAUGE_CONFIG:-$DEFAULT_CONFIG}"
ENV_PROXYGAUGE_MIXED="${PROXYGAUGE_MIXED:-}"
ENV_SECONDARY_ENABLED="${PROXYGAUGE_SECONDARY_ENABLED:-}"
ENV_SECONDARY_LABEL="${PROXYGAUGE_SECONDARY_LABEL:-}"
ENV_SECONDARY_GROUP="${PROXYGAUGE_SECONDARY_GROUP:-}"
ENV_DEFAULT_GROUP="${PROXYGAUGE_DEFAULT_GROUP:-}"
ENV_SECONDARY_MIXED="${PROXYGAUGE_SECONDARY_MIXED:-}"
ENV_SECONDARY_DOMAINS="${PROXYGAUGE_SECONDARY_DOMAINS:-}"
[ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"
if [ -n "$ENV_PROXYGAUGE_MIXED" ]; then
  PROXYGAUGE_MIXED="$ENV_PROXYGAUGE_MIXED"
fi
if [ -n "$ENV_SECONDARY_ENABLED" ]; then PROXYGAUGE_SECONDARY_ENABLED="$ENV_SECONDARY_ENABLED"; fi
if [ -n "$ENV_SECONDARY_LABEL" ]; then PROXYGAUGE_SECONDARY_LABEL="$ENV_SECONDARY_LABEL"; fi
if [ -n "$ENV_SECONDARY_GROUP" ]; then PROXYGAUGE_SECONDARY_GROUP="$ENV_SECONDARY_GROUP"; fi
if [ -n "$ENV_DEFAULT_GROUP" ]; then PROXYGAUGE_DEFAULT_GROUP="$ENV_DEFAULT_GROUP"; fi
if [ -n "$ENV_SECONDARY_MIXED" ]; then PROXYGAUGE_SECONDARY_MIXED="$ENV_SECONDARY_MIXED"; fi
if [ -n "$ENV_SECONDARY_DOMAINS" ]; then PROXYGAUGE_SECONDARY_DOMAINS="$ENV_SECONDARY_DOMAINS"; fi

EXPECT_IP="${PROXYGAUGE_EXPECT_IP:-}"
MIXED="${PROXYGAUGE_MIXED:-127.0.0.1:7890}"
TIMEOUT="${PROXYGAUGE_TIMEOUT:-6}"
MIHOMO_SOCKET="${PROXYGAUGE_MIHOMO_SOCKET:-/private/tmp/verge/verge-mihomo.sock}"
SECONDARY_ENABLED="${PROXYGAUGE_SECONDARY_ENABLED:-auto}"
SECONDARY_LABEL="${PROXYGAUGE_SECONDARY_LABEL:-Google / Gemini / Claude}"
GOOGLE_GROUP="${PROXYGAUGE_SECONDARY_GROUP:-${PROXYGAUGE_GOOGLE_GROUP:-Google-Chain}}"
DEFAULT_GROUP="${PROXYGAUGE_DEFAULT_GROUP:-PROXY}"
GOOGLE_MIXED="${PROXYGAUGE_SECONDARY_MIXED:-${PROXYGAUGE_GOOGLE_MIXED:-127.0.0.1:7891}}"
EXPECT_GOOGLE_IP="${PROXYGAUGE_EXPECT_SECONDARY_IP:-${PROXYGAUGE_EXPECT_GOOGLE_IP:-}}"
SECONDARY_DOMAINS="${PROXYGAUGE_SECONDARY_DOMAINS:-gemini.google.com,generativelanguage.googleapis.com,www.google.com,claude.ai,api.anthropic.com,platform.claude.com,bridge.claudeusercontent.com}"
ACTIVE_AI_PROBES="${PROXYGAUGE_ACTIVE_AI_PROBES:-0}"
MIXED_HOST="${MIXED%:*}"
MIXED_PORT="${MIXED##*:}"
GOOGLE_MIXED_HOST="${GOOGLE_MIXED%:*}"
GOOGLE_MIXED_PORT="${GOOGLE_MIXED##*:}"
SCRIPT_DIR=$(/usr/bin/dirname "$0")
CHAIN_PARSER="${PROXYGAUGE_CHAIN_PARSER:-$SCRIPT_DIR/proxygauge-chain-check.jxa}"

SECONDARY_ACTIVE=""
case "$SECONDARY_ENABLED" in
  1|true|yes) SECONDARY_ACTIVE=1 ;;
  0|false|no) ;;
  *)
    if [ -n "${PROXYGAUGE_GOOGLE_GROUP:-}${PROXYGAUGE_GOOGLE_MIXED:-}" ]; then
      SECONDARY_ACTIVE=1
    fi
    ;;
esac

pass=0
warn=0
fail=0
check() {
  if [ "$1" = "ok" ]; then
    echo "  ✅ $2"
    pass=$((pass+1))
  elif [ "$1" = "warn" ]; then
    echo "  ⚠️ $2"
    warn=$((warn+1))
  else
    echo "  ❌ $2"
    fail=$((fail+1))
  fi
}

has_tun_route() {
  if /sbin/ifconfig 2>/dev/null | /usr/bin/grep -qE 'inet 198\.18\.'; then
    return 0
  fi
  /usr/sbin/netstat -rn -f inet 2>/dev/null | /usr/bin/grep -qE '^198\.18\..*[[:space:]]utun[0-9]+'
}

check_site() {
  name="$1"
  url="$2"
  kind="$3"
  probe_proxy="$4"
  headers=$(/usr/bin/mktemp -t proxygauge-site-headers)
  body=$(/usr/bin/mktemp -t proxygauge-site-body)
  out=$(/usr/bin/curl -sS -D "$headers" -o "$body" -w '%{http_code} %{time_total}' \
    --retry 1 --retry-all-errors --retry-delay 1 \
    --proxy "http://$probe_proxy" --max-time "$TIMEOUT" "$url" 2>/dev/null)
  curl_status=$?
  code=${out%% *}
  t=${out##* }

  if [ "$curl_status" -ne 0 ] || [ -z "$code" ] || [ "$code" = "000" ]; then
    check no "$name 不可达 (TCP、DNS 或 TLS 连接失败)"
  elif /usr/bin/grep -qiE '^cf-mitigated:[[:space:]]*challenge' "$headers"; then
    check warn "$name 触发 Cloudflare challenge (HTTP $code, ${t}s)"
  elif [ "$kind" = "gemini" ] && [ "$code" = "403" ] \
    && /usr/bin/grep -qiE 'API_KEY_INVALID|API key not valid|API key.*missing' "$body"; then
    check ok "$name 公网入口可达 (HTTP 403；缺少 API Key 属于预期)"
  elif [ "$kind" = "api" ] && echo "$code" | /usr/bin/grep -qE '^(200|201|204|301|302|307|308|400|401|404)$'; then
    check ok "$name 公网入口可达 (HTTP $code, ${t}s；认证错误属于预期)"
  elif echo "$code" | /usr/bin/grep -qE '^(200|201|204|301|302|307|308)$'; then
    check ok "$name 可正常访问 (HTTP $code, ${t}s)"
  elif [ "$code" = "403" ]; then
    check warn "$name 网络可达但被拒绝 (HTTP 403, ${t}s；可能是地区或风控策略)"
  elif [ "$code" = "429" ]; then
    check warn "$name 触发频率限制 (HTTP 429, ${t}s)"
  elif echo "$code" | /usr/bin/grep -qE '^5[0-9][0-9]$'; then
    check warn "$name 返回服务端错误 (HTTP $code, ${t}s)"
  else
    check warn "$name 响应异常 (HTTP $code, ${t}s)"
  fi
  /bin/rm -f "$headers" "$body"
}

echo "检查时间: $(date '+%F %T')"
if [ -n "$SECONDARY_ACTIVE" ]; then
  echo "检测方案: 通用检测 + $SECONDARY_LABEL"
  echo "额外分流: 1"
else
  echo "检测方案: 通用检测"
  echo "额外分流: 0"
fi

echo "===== 1. 代理核心进程 ====="
CORE_PIDS=$(/usr/bin/pgrep -x verge-mihomo 2>/dev/null)
CORE_COUNT=$(printf '%s\n' "$CORE_PIDS" | /usr/bin/awk 'NF {count++} END {print count+0}')
if [ "$CORE_COUNT" -eq 1 ]; then
  CORE_PID=$(printf '%s\n' "$CORE_PIDS" | /usr/bin/head -1)
  check ok "verge-mihomo 核心运行中 (PID $CORE_PID)"
elif [ "$CORE_COUNT" -gt 1 ]; then
  echo "$CORE_PIDS" | while IFS= read -r pid; do
    [ -n "$pid" ] && /bin/ps -p "$pid" -o '  user=,pid=,command=' 2>/dev/null
  done
  check no "发现 $CORE_COUNT 个 verge-mihomo 核心 — 可能是双核心分裂"
else
  check no "未发现 verge-mihomo 核心 — helper 进程不会被误判为核心"
fi

echo "===== 2. mixed 端口监听 ($MIXED) ====="
if (exec 3<>/dev/tcp/"$MIXED_HOST"/"$MIXED_PORT") 2>/dev/null; then
  check ok "$MIXED 监听中 (HTTP/SOCKS5 混合端口可连接)"
else
  check no "$MIXED 未监听 — 核心未启动或端口已改"
fi

echo "===== 3. 代理入口 (系统代理 / TUN, 至少一个) ====="
MODE_OK=""
SYSTEM_ACTIVE=""
TUN_ACTIVE=""
if /usr/sbin/scutil --proxy 2>/dev/null | /usr/bin/grep -qE '(HTTP|SOCKS)Enable : 1'; then
  echo "  ℹ️ 系统代理: 已启用"
  MODE_OK=1
  SYSTEM_ACTIVE=1
else
  echo "  ℹ️ 系统代理: 未启用"
fi
if has_tun_route; then
  echo "  ℹ️ TUN: 已接管 (Fake-IP 网段 198.18.0.0/16 生效)"
  MODE_OK=1
  TUN_ACTIVE=1
else
  echo "  ℹ️ TUN: 未检测到 Fake-IP 路由接管"
fi
if [ -n "$SYSTEM_ACTIVE" ] && [ -n "$TUN_ACTIVE" ]; then
  check warn "系统代理与 TUN 同时开启 — 通常只需保留一个流量入口"
elif [ -n "$MODE_OK" ]; then
  check ok "代理入口已生效"
else
  check no "系统代理与 TUN 都未开启 — 普通流量不会进入代理"
fi

if [ -n "$TUN_ACTIVE" ]; then
  DNS_IP=$(/usr/bin/dscacheutil -q host -a name www.cloudflare.com 2>/dev/null \
    | /usr/bin/awk '/ip_address:/ {print $2; exit}')
  if echo "$DNS_IP" | /usr/bin/grep -qE '^198\.18\.'; then
    check ok "TUN DNS 返回 Fake-IP ($DNS_IP)，域名分流可用"
  elif [ -z "$DNS_IP" ]; then
    check no "TUN 已接管但系统 DNS 无法解析域名 — 请检查 dns-hijack 与 dns 配置"
  else
    check warn "TUN 已接管但 DNS 返回真实地址 ($DNS_IP)，DOMAIN 规则可能无法按预期命中"
  fi
fi

echo "===== 4. 出口 IP (走代理) ====="
EXT=""
EXIT_VALUES=""
EXIT_RESPONSES=0
while IFS='|' read -r service api; do
  value=$(/usr/bin/curl -s --retry 1 --retry-all-errors --retry-delay 1 \
    --proxy "http://$MIXED" --max-time "$TIMEOUT" "$api" 2>/dev/null \
    | /usr/bin/tr -d '[:space:]')
  if echo "$value" | /usr/bin/grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
    [ -z "$EXT" ] && EXT="$value"
    EXIT_VALUES="${EXIT_VALUES}${value}"$'\n'
    EXIT_RESPONSES=$((EXIT_RESPONSES+1))
    echo "  ℹ️ $service: $value"
  else
    echo "  ℹ️ $service: 未响应"
  fi
done <<'EOF'
ipify|https://api.ipify.org
ifconfig.me|https://ifconfig.me/ip
ip.sb|https://ip.sb/ip
EOF

if [ -n "$EXT" ]; then
  UNIQUE_EXITS=$(printf '%s' "$EXIT_VALUES" | /usr/bin/awk 'NF' | /usr/bin/sort -u | /usr/bin/wc -l | /usr/bin/tr -d ' ')
  if [ "$UNIQUE_EXITS" -gt 1 ]; then
    check warn "出口查询结果不一致 — 可能发生节点轮换、分流或透明代理干扰"
  elif [ "$EXIT_RESPONSES" -lt 2 ]; then
    check warn "只收到 1 个出口查询源响应，暂时无法交叉验证"
  else
    check ok "$EXIT_RESPONSES 个查询源确认出口一致 ($EXT)"
  fi

  if [ -z "$EXPECT_IP" ]; then
    echo "  ℹ️ 未配置期望出口 IP；如使用固定节点，建议在设置中保存基线"
  elif [ "$EXT" = "$EXPECT_IP" ]; then
    check ok "出口符合配置 ($EXPECT_IP)"
  else
    check no "出口非预期 ($EXT != $EXPECT_IP)，请检查节点配置"
  fi
else
  check no "无法经代理获取出口 IP (多个查询源均失败)"
fi

run_secondary_checks() {
echo "===== 5. 额外分流链路 ($SECONDARY_LABEL) ====="
GOOGLE_EXT=""
CHAIN_CONFIGURED=""
if [ -S "$MIHOMO_SOCKET" ] && [ -r "$CHAIN_PARSER" ]; then
  PROXIES_JSON=$(/usr/bin/mktemp -t proxygauge-proxies)
  RULES_JSON=$(/usr/bin/mktemp -t proxygauge-rules)
  DELAY_JSON=$(/usr/bin/mktemp -t proxygauge-chain-delay)
  : > "$PROXIES_JSON"
  : > "$RULES_JSON"
  : > "$DELAY_JSON"

  /usr/bin/curl -sS --unix-socket "$MIHOMO_SOCKET" \
    http://localhost/proxies -o "$PROXIES_JSON" 2>/dev/null || true
  /usr/bin/curl -sS --unix-socket "$MIHOMO_SOCKET" \
    http://localhost/rules -o "$RULES_JSON" 2>/dev/null || true
  /usr/bin/curl -sS --unix-socket "$MIHOMO_SOCKET" --get \
    --data-urlencode 'url=https://cp.cloudflare.com/generate_204' \
    --data-urlencode "timeout=$((TIMEOUT * 1000))" \
    "http://localhost/proxies/$GOOGLE_GROUP/delay" \
    -o "$DELAY_JSON" 2>/dev/null || true

  CHAIN_OUTPUT=$(/usr/bin/osascript -l JavaScript "$CHAIN_PARSER" \
    "$PROXIES_JSON" "$RULES_JSON" "$DELAY_JSON" \
    "$GOOGLE_GROUP" "$DEFAULT_GROUP" "$SECONDARY_DOMAINS" "$SECONDARY_LABEL" 2>/dev/null || true)
  /bin/rm -f "$PROXIES_JSON" "$RULES_JSON" "$DELAY_JSON"

  if [ -n "$CHAIN_OUTPUT" ]; then
    /usr/bin/printf '%s\n' "$CHAIN_OUTPUT"
    if ! /usr/bin/grep -Fq "未检测到 $GOOGLE_GROUP" <<< "$CHAIN_OUTPUT"; then
      CHAIN_CONFIGURED=1
    fi
    CHAIN_PASSES=$(printf '%s\n' "$CHAIN_OUTPUT" | /usr/bin/grep -c '^  ✅')
    CHAIN_WARNINGS=$(printf '%s\n' "$CHAIN_OUTPUT" | /usr/bin/grep -c '^  ⚠️')
    CHAIN_FAILURES=$(printf '%s\n' "$CHAIN_OUTPUT" | /usr/bin/grep -c '^  ❌')
    pass=$((pass + CHAIN_PASSES))
    warn=$((warn + CHAIN_WARNINGS))
    fail=$((fail + CHAIN_FAILURES))
  else
    echo "  ℹ️ 无法读取 Mihomo 额外分流状态"
  fi
else
  echo "  ℹ️ 未检测到 Mihomo 控制 socket；跳过可选策略组与规则检查"
fi

if [ "$GOOGLE_MIXED" = "$MIXED" ]; then
  check no "$SECONDARY_LABEL 入口与默认 mixed 端口相同，无法区分两个出口"
elif (exec 3<>/dev/tcp/"$GOOGLE_MIXED_HOST"/"$GOOGLE_MIXED_PORT") 2>/dev/null; then
  CHAIN_CONFIGURED=1
  GOOGLE_EXT=""
  GOOGLE_EXIT_VALUES=""
  GOOGLE_EXIT_RESPONSES=0
  while IFS='|' read -r service api; do
    value=$(/usr/bin/curl -s --retry 1 --retry-all-errors --retry-delay 1 \
      --proxy "http://$GOOGLE_MIXED" --max-time "$TIMEOUT" "$api" 2>/dev/null \
      | /usr/bin/tr -d '[:space:]')
    if echo "$value" | /usr/bin/grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
      [ -z "$GOOGLE_EXT" ] && GOOGLE_EXT="$value"
      GOOGLE_EXIT_VALUES="${GOOGLE_EXIT_VALUES}${value}"$'\n'
      GOOGLE_EXIT_RESPONSES=$((GOOGLE_EXIT_RESPONSES+1))
      echo "  ℹ️ $service（$SECONDARY_LABEL）: $value"
    else
      echo "  ℹ️ $service（$SECONDARY_LABEL）: 未响应"
    fi
  done <<'EOF'
ipify|https://api.ipify.org
ifconfig.me|https://ifconfig.me/ip
ip.sb|https://ip.sb/ip
EOF

  if [ -n "$GOOGLE_EXT" ]; then
    GOOGLE_UNIQUE_EXITS=$(printf '%s' "$GOOGLE_EXIT_VALUES" | /usr/bin/awk 'NF' | /usr/bin/sort -u | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    if [ "$GOOGLE_UNIQUE_EXITS" -gt 1 ]; then
      check warn "$SECONDARY_LABEL 出口查询结果不一致"
    elif [ "$GOOGLE_EXIT_RESPONSES" -lt 2 ]; then
      check warn "$SECONDARY_LABEL 出口只收到 1 个查询源响应"
    else
      check ok "$GOOGLE_EXIT_RESPONSES 个查询源确认 $SECONDARY_LABEL 出口一致 ($GOOGLE_EXT)"
    fi

    if [ -n "$EXPECT_GOOGLE_IP" ] && [ "$GOOGLE_EXT" != "$EXPECT_GOOGLE_IP" ]; then
      check no "$SECONDARY_LABEL 出口非预期 ($GOOGLE_EXT != $EXPECT_GOOGLE_IP)"
    elif [ -n "$EXPECT_GOOGLE_IP" ]; then
      check ok "$SECONDARY_LABEL 出口符合配置 ($EXPECT_GOOGLE_IP)"
    fi

    if [ -n "$EXT" ] && [ "$GOOGLE_EXT" = "$EXT" ]; then
      check warn "$SECONDARY_LABEL 出口与默认出口相同 ($GOOGLE_EXT) — 请确认策略选择"
    elif [ -n "$EXT" ]; then
      check ok "出口已分离：默认 $EXT / $SECONDARY_LABEL $GOOGLE_EXT"
    fi

  else
    check no "无法通过 $GOOGLE_MIXED 获取 $SECONDARY_LABEL 出口 IP"
  fi
else
  if [ -n "$CHAIN_CONFIGURED" ]; then
    check warn "$SECONDARY_LABEL 入口 $GOOGLE_MIXED 未监听；只能验证规则，不能确认实际出口 IP"
  else
    echo "  ℹ️ 未检测到 $SECONDARY_LABEL 策略组或本地入口"
  fi
fi

echo "===== 6. 分流确认 (不访问账号站点) ====="
if [ -n "$GOOGLE_EXT" ]; then
  check ok "$SECONDARY_LABEL 已绑定独立出口 ($GOOGLE_EXT)"
elif [ -n "$CHAIN_CONFIGURED" ]; then
  check warn "已检测到 $SECONDARY_LABEL 分流配置，但尚未确认独立出口 IP"
else
  echo "  ℹ️ 尚未确认 $SECONDARY_LABEL 的独立出口"
fi
echo "  ℹ️ 默认不请求 Claude、ChatGPT、Gemini 网页或 API，避免链路检测制造机器人式访问记录"

if [ "$ACTIVE_AI_PROBES" = "1" ]; then
  echo "  ⚠️ 已手动启用主动 AI API 探测；请求会到达对应平台"
  check_site "OpenAI API" "https://api.openai.com/v1/models" "api" "$MIXED"
  check_site "Anthropic API" "https://api.anthropic.com/v1/models" "api" "$MIXED"
  GEMINI_PROBE_PROXY="$MIXED"
  if [ -n "$SECONDARY_ACTIVE" ]; then
    GEMINI_PROBE_PROXY="$GOOGLE_MIXED"
  fi
  check_site "Gemini API" "https://generativelanguage.googleapis.com/v1beta/models" "gemini" "$GEMINI_PROBE_PROXY"
fi

echo "===== 7. 出口结论 (不新增外部请求) ====="
if [ -n "$EXT" ]; then
  check ok "默认出口已由多个 IP 查询源确认 ($EXT)"
fi
if [ -n "$GOOGLE_EXT" ]; then
  check ok "$SECONDARY_LABEL 出口已由专用链路确认 ($GOOGLE_EXT)"
fi
if [ -n "$EXT" ] && [ -n "$GOOGLE_EXT" ] && [ "$EXT" != "$GOOGLE_EXT" ]; then
  check ok "默认出口与 $SECONDARY_LABEL 出口相互独立"
elif [ -n "$EXT" ] && [ -n "$GOOGLE_EXT" ]; then
  check warn "两个检测入口当前返回同一出口 IP"
fi
}

if [ -n "$SECONDARY_ACTIVE" ]; then
  run_secondary_checks
elif [ "$ACTIVE_AI_PROBES" = "1" ]; then
  echo "===== 5. 主动平台探测 (手动启用) ====="
  echo "  ⚠️ 已手动启用主动 AI API 探测；请求会经默认入口到达对应平台"
  check_site "OpenAI API" "https://api.openai.com/v1/models" "api" "$MIXED"
  check_site "Anthropic API" "https://api.anthropic.com/v1/models" "api" "$MIXED"
  check_site "Gemini API" "https://generativelanguage.googleapis.com/v1beta/models" "gemini" "$MIXED"
fi

echo
echo "===== 结果: $pass 通过 / $warn 提示 / $fail 失败 ====="
if [ "$fail" -eq 0 ]; then
  echo "🎉 代理链路检查通过"
  exit 0
else
  echo "⚠️ 有 $fail 项未通过，请检查本地代理与当前检测方案"
  exit 1
fi
