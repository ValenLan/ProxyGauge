#!/bin/bash
# PuffRoute 代理健康检查脚本
# 用法: bash ~/.local/bin/puffroute-check
# 退出码: 0 = 链路检查通过; 1 = 有失败项

CONFIG_FILE="${PUFFROUTE_CONFIG:-$HOME/.config/puffroute/config}"
[ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"

EXPECT_IP="${PUFFROUTE_EXPECT_IP:-}"
MIXED="${PUFFROUTE_MIXED:-127.0.0.1:7890}"
TIMEOUT="${PUFFROUTE_TIMEOUT:-6}"
MIXED_HOST="${MIXED%:*}"
MIXED_PORT="${MIXED##*:}"

pass=0
fail=0
check() {
  if [ "$1" = "ok" ]; then
    echo "  ✅ $2"
    pass=$((pass+1))
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

echo "检查时间: $(date '+%F %T')"

echo "===== 1. 代理核心进程 ====="
CORE_PIDS=$(/usr/bin/pgrep -x verge-mihomo 2>/dev/null)
CORE_COUNT=$(printf '%s\n' "$CORE_PIDS" | /usr/bin/awk 'NF {count++} END {print count+0}')
if [ "$CORE_COUNT" -eq 1 ]; then
  CORE_PID=$(printf '%s\n' "$CORE_PIDS" | /usr/bin/head -1)
  CORE_DESC=$(/bin/ps -p "$CORE_PID" -o user=,pid=,command= 2>/dev/null)
  check ok "verge-mihomo 核心运行中 ($CORE_DESC)"
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
if /usr/sbin/scutil --proxy 2>/dev/null | /usr/bin/grep -qE '(HTTP|SOCKS)Enable : 1'; then
  echo "  ℹ️ 系统代理: 已启用"
  MODE_OK=1
else
  echo "  ℹ️ 系统代理: 未启用"
fi
if has_tun_route; then
  echo "  ℹ️ TUN: 已接管 (Fake-IP 网段 198.18.0.0/16 生效)"
  MODE_OK=1
else
  echo "  ℹ️ TUN: 未检测到 Fake-IP 路由接管"
fi
if [ -n "$MODE_OK" ]; then
  check ok "代理入口已生效"
else
  check no "系统代理与 TUN 都未开启 — 普通流量不会进入代理"
fi

echo "===== 4. 出口 IP (走代理) ====="
EXT=""
for api in https://api.ipify.org https://ifconfig.me/ip https://ip.sb/ip; do
  EXT=$(/usr/bin/curl -s --retry 1 --retry-all-errors --retry-delay 1 --proxy "http://$MIXED" --max-time "$TIMEOUT" "$api" 2>/dev/null | /usr/bin/tr -d '[:space:]')
  if echo "$EXT" | /usr/bin/grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
    break
  fi
  EXT=""
done
if [ -n "$EXT" ]; then
  echo "  实测出口 IP: $EXT"
  if [ -z "$EXPECT_IP" ]; then
    check ok "代理出口可用 ($EXT；未配置期望出口 IP)"
  elif [ "$EXT" = "$EXPECT_IP" ]; then
    check ok "出口符合配置 ($EXPECT_IP)"
  else
    check no "出口非预期 ($EXT != $EXPECT_IP)，请检查节点配置"
  fi
else
  check no "无法经代理获取出口 IP (多个查询源均失败)"
fi

echo "===== 5. AI 站点网络可达性 (走代理) ====="
for h in api.openai.com api.anthropic.com claude.ai chatgpt.com generativelanguage.googleapis.com; do
  out=$(/usr/bin/curl -s -o /dev/null -w '%{http_code} %{time_total}' --retry 1 --retry-all-errors --retry-delay 1 --proxy "http://$MIXED" --max-time "$TIMEOUT" "https://$h" 2>/dev/null)
  code=${out%% *}
  t=${out##* }
  if [ -n "$code" ] && [ "$code" != "000" ]; then
    if [ "$code" = "403" ]; then
      check ok "$h 网络可达 (HTTP 403, ${t}s；可能是站点挑战页)"
    else
      check ok "$h 网络可达 (HTTP $code, ${t}s)"
    fi
  else
    check no "$h 不可达 (TCP/DNS/TLS 连接失败)"
  fi
done

echo "===== 6. 外网连通性 (204 探测) ====="
code=$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' --retry 1 --retry-all-errors --retry-delay 1 --proxy "http://$MIXED" --max-time "$TIMEOUT" https://www.google.com/generate_204 2>/dev/null)
if [ "$code" = "204" ]; then
  check ok "Google generate_204 正常 (代理出网通畅)"
else
  check no "generate_204 异常 (HTTP $code)"
fi

echo
echo "===== 结果: $pass 通过 / $fail 失败 ====="
if [ "$fail" -eq 0 ]; then
  echo "🎉 代理链路检查通过"
  exit 0
else
  echo "⚠️ 有 $fail 项未通过，请检查 Clash 配置与 VPS 状态"
  exit 1
fi
