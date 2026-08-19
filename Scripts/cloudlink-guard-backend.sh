#!/bin/bash

RESOURCE_DIR=$(/usr/bin/dirname "$0")

import_cloudroute_compat() {
  local suffix current legacy
  for suffix in "$@"; do
    current="CLOUDLINK_GUARD_$suffix"
    legacy="CLOUDROUTE_$suffix"
    if ! declare -p "$current" >/dev/null 2>&1 \
      && declare -p "$legacy" >/dev/null 2>&1; then
      printf -v "$current" '%s' "${!legacy}"
      export "$current"
    fi
  done
}

import_cloudroute_compat \
  ADMIN_SCRIPT OSASCRIPT KILLSWITCH ADMIN_RESULT KILL_TOKEN CONFIG MIXED \
  SECONDARY_ENABLED SECONDARY_LABEL SECONDARY_GROUP DEFAULT_GROUP \
  SECONDARY_MIXED SECONDARY_DOMAINS TUN_ACTIVE SYSTEM_PROXY_ACTIVE \
  DISCOVERY_PORT_ACTIVE DISCOVERY_SYSTEM_PROXY DISCOVERY_SOCKET \
  DISCOVERY_SOCKET_JSON DISCOVERY_CLIENT DISCOVERY_CONFIG

CHECK="$RESOURCE_DIR/cloudlink-guard-check.sh"
[ -x "$CHECK" ] || CHECK="$HOME/.local/bin/cloudlink-guard-check"
ADMIN_SCRIPT="${CLOUDLINK_GUARD_ADMIN_SCRIPT:-${PUFFROUTE_ADMIN_SCRIPT:-$RESOURCE_DIR/cloudlink-guard-admin.applescript}}"
[ -r "$ADMIN_SCRIPT" ] || ADMIN_SCRIPT="$HOME/.local/share/cloudlink-guard/cloudlink-guard-admin.applescript"
OSASCRIPT="${CLOUDLINK_GUARD_OSASCRIPT:-${PUFFROUTE_OSASCRIPT:-/usr/bin/osascript}}"
KILL_HELPER="${CLOUDLINK_GUARD_KILLSWITCH:-${PUFFROUTE_KILLSWITCH:-$RESOURCE_DIR/cloudlink-guard-killswitch}}"
[ -x "$KILL_HELPER" ] || KILL_HELPER="$HOME/.local/bin/cloudlink-guard-killswitch"
CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
ADMIN_RESULT="${CLOUDLINK_GUARD_ADMIN_RESULT:-${PUFFROUTE_ADMIN_RESULT:-$CACHE_HOME/cloudlink-guard/admin-result}}"
KILL_TOKEN="${CLOUDLINK_GUARD_KILL_TOKEN:-${PUFFROUTE_KILL_TOKEN:-/var/run/cloudlink-guard-killswitch.pf-token}}"
if [ -z "${CLOUDLINK_GUARD_KILL_TOKEN:-}" ] && [ -z "${PUFFROUTE_KILL_TOKEN:-}" ] \
  && [ ! -e "$KILL_TOKEN" ]; then
  if [ -e /var/run/cloudroute-killswitch.pf-token ]; then
    KILL_TOKEN=/var/run/cloudroute-killswitch.pf-token
  elif [ -e /var/run/puffroute-killswitch.pf-token ]; then
    KILL_TOKEN=/var/run/puffroute-killswitch.pf-token
  fi
fi
DEFAULT_CONFIG="$HOME/.config/cloudlink-guard/config"
CLOUDROUTE_CONFIG_PATH="$HOME/.config/cloudroute/config"
PUFFROUTE_CONFIG_PATH="$HOME/.config/puffroute/config"
CONFIG_FILE="${CLOUDLINK_GUARD_CONFIG:-${PUFFROUTE_CONFIG:-$DEFAULT_CONFIG}}"
ENV_CLOUDLINK_GUARD_MIXED="${CLOUDLINK_GUARD_MIXED:-${PUFFROUTE_MIXED:-}}"
ENV_SECONDARY_ENABLED="${CLOUDLINK_GUARD_SECONDARY_ENABLED:-}"
ENV_SECONDARY_LABEL="${CLOUDLINK_GUARD_SECONDARY_LABEL:-}"
ENV_SECONDARY_GROUP="${CLOUDLINK_GUARD_SECONDARY_GROUP:-}"
ENV_DEFAULT_GROUP="${CLOUDLINK_GUARD_DEFAULT_GROUP:-}"
ENV_SECONDARY_MIXED="${CLOUDLINK_GUARD_SECONDARY_MIXED:-}"
ENV_SECONDARY_DOMAINS="${CLOUDLINK_GUARD_SECONDARY_DOMAINS:-}"
if [ -z "${CLOUDLINK_GUARD_CONFIG:-}" ] && [ -z "${PUFFROUTE_CONFIG:-}" ] \
  && [ ! -r "$CONFIG_FILE" ]; then
  if [ -r "$CLOUDROUTE_CONFIG_PATH" ]; then
    CONFIG_FILE="$CLOUDROUTE_CONFIG_PATH"
  elif [ -r "$PUFFROUTE_CONFIG_PATH" ]; then
    CONFIG_FILE="$PUFFROUTE_CONFIG_PATH"
  fi
fi
[ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"
import_cloudroute_compat \
  MIXED SECONDARY_ENABLED SECONDARY_LABEL SECONDARY_GROUP DEFAULT_GROUP \
  SECONDARY_MIXED SECONDARY_DOMAINS
if [ -n "$ENV_CLOUDLINK_GUARD_MIXED" ]; then
  CLOUDLINK_GUARD_MIXED="$ENV_CLOUDLINK_GUARD_MIXED"
fi
if [ -n "$ENV_SECONDARY_ENABLED" ]; then CLOUDLINK_GUARD_SECONDARY_ENABLED="$ENV_SECONDARY_ENABLED"; fi
if [ -n "$ENV_SECONDARY_LABEL" ]; then CLOUDLINK_GUARD_SECONDARY_LABEL="$ENV_SECONDARY_LABEL"; fi
if [ -n "$ENV_SECONDARY_GROUP" ]; then CLOUDLINK_GUARD_SECONDARY_GROUP="$ENV_SECONDARY_GROUP"; fi
if [ -n "$ENV_DEFAULT_GROUP" ]; then CLOUDLINK_GUARD_DEFAULT_GROUP="$ENV_DEFAULT_GROUP"; fi
if [ -n "$ENV_SECONDARY_MIXED" ]; then CLOUDLINK_GUARD_SECONDARY_MIXED="$ENV_SECONDARY_MIXED"; fi
if [ -n "$ENV_SECONDARY_DOMAINS" ]; then CLOUDLINK_GUARD_SECONDARY_DOMAINS="$ENV_SECONDARY_DOMAINS"; fi
CONFIGURED_MIXED="${CLOUDLINK_GUARD_MIXED:-${PUFFROUTE_MIXED:-}}"
MIXED="${CLOUDLINK_GUARD_MIXED:-${PUFFROUTE_MIXED:-127.0.0.1:7890}}"
MIXED_HOST="${MIXED%:*}"
MIXED_PORT="${MIXED##*:}"
export CLOUDLINK_GUARD_MIXED="$MIXED"
export CLOUDLINK_GUARD_SECONDARY_ENABLED CLOUDLINK_GUARD_SECONDARY_LABEL CLOUDLINK_GUARD_SECONDARY_GROUP
export CLOUDLINK_GUARD_DEFAULT_GROUP CLOUDLINK_GUARD_SECONDARY_MIXED CLOUDLINK_GUARD_SECONDARY_DOMAINS

has_tun_route() {
  case "${CLOUDLINK_GUARD_TUN_ACTIVE:-}" in
    1|true|yes) return 0 ;;
    0|false|no) return 1 ;;
  esac
  if /sbin/ifconfig 2>/dev/null | /usr/bin/grep -qE 'inet 198\.18\.'; then
    return 0
  fi
  /usr/sbin/netstat -rn -f inet 2>/dev/null | /usr/bin/grep -qE '^198\.18\..*[[:space:]]utun[0-9]+'
}

system_proxy_active() {
  case "${CLOUDLINK_GUARD_SYSTEM_PROXY_ACTIVE:-}" in
    1|true|yes) return 0 ;;
    0|false|no) return 1 ;;
  esac
  /usr/sbin/scutil --proxy 2>/dev/null | /usr/bin/grep -qE '(HTTP|SOCKS)Enable : 1'
}

discovery_port_open() {
  local host port
  host="$1"
  port="$2"
  case "${CLOUDLINK_GUARD_DISCOVERY_PORT_ACTIVE:-}" in
    1|true|yes) return 0 ;;
    0|false|no) return 1 ;;
  esac
  (exec 3<>/dev/tcp/"$host"/"$port") 2>/dev/null
}

valid_local_endpoint() {
  local endpoint host port
  endpoint="$1"
  host="${endpoint%:*}"
  port="${endpoint##*:}"
  case "$host" in
    127.0.0.1|localhost) ;;
    *) return 1 ;;
  esac
  case "$port" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$port" -gt 0 ] && [ "$port" -lt 65536 ]
}

system_proxy_endpoint() {
  if [ -n "${CLOUDLINK_GUARD_DISCOVERY_SYSTEM_PROXY:-}" ]; then
    /usr/bin/printf '%s\n' "$CLOUDLINK_GUARD_DISCOVERY_SYSTEM_PROXY"
    return
  fi

  /usr/sbin/scutil --proxy 2>/dev/null | /usr/bin/awk '
    /HTTPEnable : 1/ { enabled = 1 }
    /HTTPProxy :/ { host = $3 }
    /HTTPPort :/ { port = $3 }
    END {
      if (enabled && host != "" && port ~ /^[0-9]+$/) {
        print host ":" port
      }
    }
  '
}

yaml_mixed_port() {
  local config_path
  config_path="$1"
  [ -r "$config_path" ] || return 1
  /usr/bin/awk -F ':' '
    /^[[:space:]]*mixed-port[[:space:]]*:/ {
      value = $2
      gsub(/[[:space:]"]/, "", value)
      if (value ~ /^[0-9]+$/ && value + 0 > 0 && value + 0 < 65536) {
        print value
        exit
      }
    }
  ' "$config_path"
}

runtime_mixed_port() {
  local socket_path json port
  socket_path="${CLOUDLINK_GUARD_DISCOVERY_SOCKET:-/private/tmp/verge/verge-mihomo.sock}"

  if [ -n "${CLOUDLINK_GUARD_DISCOVERY_SOCKET_JSON:-}" ]; then
    [ -r "$CLOUDLINK_GUARD_DISCOVERY_SOCKET_JSON" ] || return 1
    json=$(/bin/cat "$CLOUDLINK_GUARD_DISCOVERY_SOCKET_JSON")
  else
    [ -S "$socket_path" ] || return 1
    json=$(/usr/bin/curl -fsS --max-time 2 --unix-socket "$socket_path" \
      http://localhost/configs 2>/dev/null) || return 1
  fi

  port=$(/usr/bin/printf '%s' "$json" \
    | /usr/bin/plutil -extract 'mixed-port' raw -o - -- - 2>/dev/null) || return 1
  case "$port" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$port" -gt 0 ] && [ "$port" -lt 65536 ] || return 1
  /usr/bin/printf '%s\n' "$port"
}

discover() {
  local client endpoint source active mode config_path port candidate
  local system_active tun_active

  client="未识别"
  endpoint=""
  source=""
  active="idle"
  system_active=""
  tun_active=""

  if [ -n "${CLOUDLINK_GUARD_DISCOVERY_CLIENT:-}" ]; then
    client="$CLOUDLINK_GUARD_DISCOVERY_CLIENT"
  elif /usr/bin/pgrep -x verge-mihomo >/dev/null 2>&1; then
    client="Clash Verge Rev"
  elif /usr/bin/pgrep -x mihomo >/dev/null 2>&1; then
    client="Mihomo"
  elif /usr/bin/pgrep -x clash-meta >/dev/null 2>&1; then
    client="Clash Meta"
  fi

  if system_proxy_active; then system_active=1; fi
  if has_tun_route; then tun_active=1; fi
  if [ -n "$system_active" ] && [ -n "$tun_active" ]; then
    mode="双重入口"
  elif [ -n "$tun_active" ]; then
    mode="TUN"
  elif [ -n "$system_active" ]; then
    mode="系统代理"
  else
    mode="未开启"
  fi

  if [ -z "$endpoint" ] && [ -n "$system_active" ]; then
    candidate=$(system_proxy_endpoint)
    if [ -n "$candidate" ] && valid_local_endpoint "$candidate"; then
      endpoint="$candidate"
      source="macOS 系统代理"
    fi
  fi

  if [ -z "$endpoint" ]; then
    port=$(runtime_mixed_port 2>/dev/null || true)
    if [ -n "$port" ]; then
      endpoint="127.0.0.1:$port"
      source="Mihomo 运行状态"
      [ "$client" = "未识别" ] && client="Mihomo"
    fi
  fi

  config_path="${CLOUDLINK_GUARD_DISCOVERY_CONFIG:-$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml}"
  if [ -z "$endpoint" ]; then
    port=$(yaml_mixed_port "$config_path" 2>/dev/null || true)
    if [ -n "$port" ]; then
      endpoint="127.0.0.1:$port"
      source="Clash Verge 本地设置"
      [ "$client" = "未识别" ] && client="Clash Verge Rev"
    fi
  fi

  if [ -z "$endpoint" ] && [ -n "$CONFIGURED_MIXED" ] \
    && valid_local_endpoint "$CONFIGURED_MIXED"; then
    endpoint="$CONFIGURED_MIXED"
    source="CloudLink Guard 设置"
  fi

  if [ -z "$endpoint" ]; then
    for port in 7890 7897; do
      if discovery_port_open 127.0.0.1 "$port"; then
        endpoint="127.0.0.1:$port"
        source="本地监听端口"
        break
      fi
    done
  fi

  if [ -n "$endpoint" ]; then
    candidate="${endpoint%:*}"
    port="${endpoint##*:}"
    if discovery_port_open "$candidate" "$port"; then
      active="ok"
    fi
    /usr/bin/printf 'found\t1\n'
  else
    endpoint="127.0.0.1:7890"
    source="手动设置"
    /usr/bin/printf 'found\t0\n'
  fi

  /usr/bin/printf 'client\t%s\n' "$client"
  /usr/bin/printf 'endpoint\t%s\n' "$endpoint"
  /usr/bin/printf 'mode\t%s\n' "$mode"
  /usr/bin/printf 'source\t%s\n' "$source"
  /usr/bin/printf 'active\t%s\n' "$active"
  /usr/bin/printf 'privacy\t仅读取本地端口与运行模式，不读取订阅和节点\n'
}

kill_switch_snapshot() {
  local action_status result_file legacy_result

  result_file="$ADMIN_RESULT"
  if [ ! -r "$result_file" ] && [ -z "${CLOUDLINK_GUARD_ADMIN_RESULT:-}" ] \
    && [ -z "${PUFFROUTE_ADMIN_RESULT:-}" ]; then
    for legacy_result in /var/run/cloudroute/admin-result /var/run/puffroute/admin-result; do
      if [ -r "$legacy_result" ]; then
        result_file="$legacy_result"
        break
      fi
    done
  fi

  if [ -r "$result_file" ]; then
    action_status=$(/usr/bin/sed -n 's/^__STATUS__=//p' "$result_file" | /usr/bin/tail -1)
    if [ "$action_status" = "0" ]; then
      if /usr/bin/grep -qE 'Kill Switch([:：][[:space:]]*|[[:space:]]+)(Enabled|已开启)([[:space:]]|$)' "$result_file"; then
        /usr/bin/printf '已开启\tok\n'
        return
      fi
      if /usr/bin/grep -qE 'Kill Switch([:：][[:space:]]*|[[:space:]]+)(Disabled|已关闭)([[:space:]]|$)' "$result_file"; then
        /usr/bin/printf '已关闭\twarning\n'
        return
      fi
    fi
  fi

  if [ -e "$KILL_TOKEN" ]; then
    /usr/bin/printf '待确认\tidle\n'
  else
    /usr/bin/printf '未确认\tidle\n'
  fi
}

probe() {
  local core_count core_value core_level port_value port_level
  local system_value system_level tun_value tun_level kill_value kill_level
  local entry_value entry_level entry_title entry_symbol
  local overall headline detail entry_ok system_active tun_active

  core_count=$(/usr/bin/pgrep -x verge-mihomo 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')
  case "$core_count" in
    0)
      core_value="未运行"
      core_level="error"
      ;;
    1)
      core_value="运行中"
      core_level="ok"
      ;;
    *)
      core_value="${core_count} 个核心"
      core_level="warning"
      ;;
  esac

  if (exec 3<>/dev/tcp/"$MIXED_HOST"/"$MIXED_PORT") 2>/dev/null; then
    port_value="${MIXED_PORT} 监听中"
    port_level="ok"
  else
    port_value="${MIXED_PORT} 未监听"
    port_level="error"
  fi

  entry_ok=""
  system_active=""
  tun_active=""
  if system_proxy_active; then
    system_value="已启用"
    system_level="ok"
    system_active=1
  else
    system_value="未启用"
    system_level="idle"
  fi

  if has_tun_route; then
    tun_value="已接管"
    tun_level="ok"
    tun_active=1
  else
    tun_value="未接管"
    tun_level="idle"
  fi

  if [ -n "$system_active" ] && [ -n "$tun_active" ]; then
    entry_title="双重入口"
    entry_value="同时开启"
    entry_level="warning"
    entry_symbol="exclamationmark.triangle.fill"
    entry_ok=1
  elif [ -n "$tun_active" ]; then
    entry_title="TUN 路由"
    entry_value="已接管"
    entry_level="ok"
    entry_symbol="arrow.triangle.2.circlepath"
    entry_ok=1
  elif [ -n "$system_active" ]; then
    entry_title="系统代理"
    entry_value="已启用"
    entry_level="ok"
    entry_symbol="network"
    entry_ok=1
  else
    entry_title="流量入口"
    entry_value="未启用"
    entry_level="idle"
    entry_symbol="arrow.triangle.branch"
  fi

  IFS=$'\t' read -r kill_value kill_level < <(kill_switch_snapshot)

  if [ "$core_count" = "1" ] && [ "$port_level" = "ok" ] \
    && [ -n "$system_active" ] && [ -n "$tun_active" ]; then
    overall="warning"
    headline="入口同时开启"
    detail="系统代理与 TUN 均已启用"
  elif [ "$core_count" = "1" ] && [ "$port_level" = "ok" ] && [ -n "$entry_ok" ]; then
    overall="ok"
    headline="代理已接管"
    detail="流量入口当前工作正常"
  elif [ "$core_count" -gt 1 ] 2>/dev/null; then
    overall="warning"
    headline="状态异常"
    detail="检测到多个代理核心，请运行链路检测"
  else
    overall="error"
    headline="代理未完整生效"
    detail="请运行链路检测定位问题"
  fi

  /usr/bin/printf 'overall\t%s\n' "$overall"
  /usr/bin/printf 'headline\t%s\n' "$headline"
  /usr/bin/printf 'detail\t%s\n' "$detail"
  /usr/bin/printf 'core\t%s\t%s\n' "$core_value" "$core_level"
  /usr/bin/printf 'port\t%s\t%s\n' "$port_value" "$port_level"
  /usr/bin/printf 'entry\t%s\t%s\t%s\t%s\n' \
    "$entry_value" "$entry_level" "$entry_title" "$entry_symbol"
  /usr/bin/printf 'system\t%s\t%s\n' "$system_value" "$system_level"
  /usr/bin/printf 'tun\t%s\t%s\n' "$tun_value" "$tun_level"
  /usr/bin/printf 'kill\t%s\t%s\n' "$kill_value" "$kill_level"
}

run_admin() {
  local action_name admin_output action_status result_dir result_tmp
  action_name="$1"
  case "$action_name" in
    on|off|status) ;;
    *) echo "非法的管理员操作: $action_name"; return 2 ;;
  esac

  if [ ! -r "$ADMIN_SCRIPT" ]; then
    echo "缺少管理员脚本: $ADMIN_SCRIPT"
    return 1
  fi
  if [ ! -x "$KILL_HELPER" ]; then
    echo "缺少 Kill Switch helper: $KILL_HELPER"
    return 1
  fi
  if [ ! -x "$OSASCRIPT" ]; then
    echo "无法执行管理员脚本: $OSASCRIPT"
    return 1
  fi

  admin_output=$("$OSASCRIPT" "$ADMIN_SCRIPT" "$KILL_HELPER" "$action_name" 2>&1)
  action_status=$?
  if [ "$action_status" -ne 0 ]; then
    if /usr/bin/printf '%s\n' "$admin_output" | /usr/bin/grep -qE '(^|[^0-9])-128([^0-9]|$)|User canceled|用户已取消'; then
      echo "已取消管理员授权，未修改 Kill Switch"
    else
      echo "管理员操作失败"
      [ -n "$admin_output" ] && /usr/bin/printf '%s\n' "$admin_output"
    fi
    return 1
  fi
  if [ -z "$admin_output" ]; then
    echo "管理员操作没有返回状态"
    return 1
  fi

  result_dir=$(/usr/bin/dirname "$ADMIN_RESULT")
  if ! /bin/mkdir -p "$result_dir"; then
    echo "无法创建状态缓存目录: $result_dir"
    return 1
  fi
  result_tmp="$result_dir/.admin-result.$$.tmp"
  if ! {
    /usr/bin/printf '%s\n' "$admin_output"
    /usr/bin/printf '__STATUS__=0\n'
  } > "$result_tmp"; then
    echo "无法写入 Kill Switch 状态缓存"
    return 1
  fi
  /bin/chmod 600 "$result_tmp"
  /bin/mv -f "$result_tmp" "$ADMIN_RESULT"
  /usr/bin/printf '%s\n' "$admin_output"
}

case "${1:-}" in
  discover)
    discover
    ;;
  probe)
    probe
    ;;
  health)
    if [ ! -x "$CHECK" ]; then
      echo "缺少链路检测脚本: $CHECK"
      exit 1
    fi
    exec /bin/bash "$CHECK"
    ;;
  kill-status)
    run_admin status
    ;;
  kill-on)
    run_admin on
    ;;
  kill-off)
    run_admin off
    ;;
  *)
    echo "用法: $0 {discover|probe|health|kill-status|kill-on|kill-off}"
    exit 2
    ;;
esac
