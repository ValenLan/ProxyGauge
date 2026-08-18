#!/bin/bash

RESOURCE_DIR=$(/usr/bin/dirname "$0")
CHECK="$RESOURCE_DIR/cloudroute-check.sh"
[ -x "$CHECK" ] || CHECK="$HOME/.local/bin/cloudroute-check"
ADMIN_SCRIPT="${CLOUDROUTE_ADMIN_SCRIPT:-${PUFFROUTE_ADMIN_SCRIPT:-$RESOURCE_DIR/cloudroute-admin.applescript}}"
[ -r "$ADMIN_SCRIPT" ] || ADMIN_SCRIPT="$HOME/.local/share/cloudroute/cloudroute-admin.applescript"
OSASCRIPT="${CLOUDROUTE_OSASCRIPT:-${PUFFROUTE_OSASCRIPT:-/usr/bin/osascript}}"
KILL_HELPER="${CLOUDROUTE_KILLSWITCH:-${PUFFROUTE_KILLSWITCH:-$RESOURCE_DIR/cloudroute-killswitch}}"
[ -x "$KILL_HELPER" ] || KILL_HELPER="$HOME/.local/bin/cloudroute-killswitch"
CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
ADMIN_RESULT="${CLOUDROUTE_ADMIN_RESULT:-${PUFFROUTE_ADMIN_RESULT:-$CACHE_HOME/cloudroute/admin-result}}"
KILL_TOKEN="${CLOUDROUTE_KILL_TOKEN:-${PUFFROUTE_KILL_TOKEN:-/var/run/cloudroute-killswitch.pf-token}}"
if [ -z "${CLOUDROUTE_KILL_TOKEN:-}" ] && [ -z "${PUFFROUTE_KILL_TOKEN:-}" ] \
  && [ ! -e "$KILL_TOKEN" ] && [ -e /var/run/puffroute-killswitch.pf-token ]; then
  KILL_TOKEN=/var/run/puffroute-killswitch.pf-token
fi
DEFAULT_CONFIG="$HOME/.config/cloudroute/config"
LEGACY_CONFIG="$HOME/.config/puffroute/config"
CONFIG_FILE="${CLOUDROUTE_CONFIG:-${PUFFROUTE_CONFIG:-$DEFAULT_CONFIG}}"
if [ -z "${CLOUDROUTE_CONFIG:-}" ] && [ -z "${PUFFROUTE_CONFIG:-}" ] \
  && [ ! -r "$CONFIG_FILE" ] && [ -r "$LEGACY_CONFIG" ]; then
  CONFIG_FILE="$LEGACY_CONFIG"
fi
[ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"
MIXED="${CLOUDROUTE_MIXED:-${PUFFROUTE_MIXED:-127.0.0.1:7890}}"
MIXED_HOST="${MIXED%:*}"
MIXED_PORT="${MIXED##*:}"

has_tun_route() {
  case "${CLOUDROUTE_TUN_ACTIVE:-}" in
    1|true|yes) return 0 ;;
    0|false|no) return 1 ;;
  esac
  if /sbin/ifconfig 2>/dev/null | /usr/bin/grep -qE 'inet 198\.18\.'; then
    return 0
  fi
  /usr/sbin/netstat -rn -f inet 2>/dev/null | /usr/bin/grep -qE '^198\.18\..*[[:space:]]utun[0-9]+'
}

system_proxy_active() {
  case "${CLOUDROUTE_SYSTEM_PROXY_ACTIVE:-}" in
    1|true|yes) return 0 ;;
    0|false|no) return 1 ;;
  esac
  /usr/sbin/scutil --proxy 2>/dev/null | /usr/bin/grep -qE '(HTTP|SOCKS)Enable : 1'
}

kill_switch_snapshot() {
  local action_status result_file legacy_result

  result_file="$ADMIN_RESULT"
  if [ ! -r "$result_file" ] && [ -z "${CLOUDROUTE_ADMIN_RESULT:-}" ] \
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
    detail="检测到多个代理核心，请运行健康检查"
  else
    overall="error"
    headline="代理未完整生效"
    detail="请运行健康检查定位问题"
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
  probe)
    probe
    ;;
  health)
    if [ ! -x "$CHECK" ]; then
      echo "缺少健康检查脚本: $CHECK"
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
    echo "用法: $0 {probe|health|kill-status|kill-on|kill-off}"
    exit 2
    ;;
esac
