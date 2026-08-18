#!/bin/bash

CHECK="$HOME/.local/bin/puffroute-check"
ADMIN_HELPER_DIR="$HOME/.local/share/puffroute"
ADMIN_RESULT="${PUFFROUTE_ADMIN_RESULT:-/var/run/puffroute/admin-result}"
KILL_TOKEN="${PUFFROUTE_KILL_TOKEN:-/var/run/puffroute-killswitch.pf-token}"
CONFIG_FILE="${PUFFROUTE_CONFIG:-$HOME/.config/puffroute/config}"
[ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"
MIXED="${PUFFROUTE_MIXED:-127.0.0.1:7890}"
MIXED_HOST="${MIXED%:*}"
MIXED_PORT="${MIXED##*:}"

has_tun_route() {
  if /sbin/ifconfig 2>/dev/null | /usr/bin/grep -qE 'inet 198\.18\.'; then
    return 0
  fi
  /usr/sbin/netstat -rn -f inet 2>/dev/null | /usr/bin/grep -qE '^198\.18\..*[[:space:]]utun[0-9]+'
}

kill_switch_snapshot() {
  local action_status

  if [ -r "$ADMIN_RESULT" ]; then
    action_status=$(/usr/bin/sed -n 's/^__STATUS__=//p' "$ADMIN_RESULT" | /usr/bin/tail -1)
    if [ "$action_status" = "0" ]; then
      if /usr/bin/grep -qE 'Kill Switch([:：][[:space:]]*|[[:space:]]+)(Enabled|已开启)([[:space:]]|$)' "$ADMIN_RESULT"; then
        /usr/bin/printf '已开启\tok\n'
        return
      fi
      if /usr/bin/grep -qE 'Kill Switch([:：][[:space:]]*|[[:space:]]+)(Disabled|已关闭)([[:space:]]|$)' "$ADMIN_RESULT"; then
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
  local overall headline detail entry_ok

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
  if /usr/sbin/scutil --proxy 2>/dev/null | /usr/bin/grep -qE '(HTTP|SOCKS)Enable : 1'; then
    system_value="已启用"
    system_level="ok"
    entry_ok=1
  else
    system_value="未启用"
    system_level="idle"
  fi

  if has_tun_route; then
    tun_value="已接管"
    tun_level="ok"
    entry_ok=1
  else
    tun_value="未接管"
    tun_level="idle"
  fi

  IFS=$'\t' read -r kill_value kill_level < <(kill_switch_snapshot)

  if [ "$core_count" = "1" ] && [ "$port_level" = "ok" ] && [ -n "$entry_ok" ]; then
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
  /usr/bin/printf 'system\t%s\t%s\n' "$system_value" "$system_level"
  /usr/bin/printf 'tun\t%s\t%s\n' "$tun_value" "$tun_level"
  /usr/bin/printf 'kill\t%s\t%s\n' "$kill_value" "$kill_level"
}

run_admin() {
  local action_name admin_helper before_run after_run action_status
  action_name="$1"
  case "$action_name" in
    on) admin_helper="$ADMIN_HELPER_DIR/PuffRoute Admin On.app" ;;
    off) admin_helper="$ADMIN_HELPER_DIR/PuffRoute Admin Off.app" ;;
    status) admin_helper="$ADMIN_HELPER_DIR/PuffRoute Admin Status.app" ;;
    *) echo "非法的管理员操作: $action_name"; return 2 ;;
  esac

  if [ ! -e "$admin_helper" ]; then
    echo "缺少管理员 helper: $admin_helper"
    return 1
  fi

  before_run=""
  [ -r "$ADMIN_RESULT" ] && before_run=$(/usr/bin/sed -n 's/^__RUN__=//p' "$ADMIN_RESULT" | /usr/bin/tail -1)
  if ! /usr/bin/open -W -n "$admin_helper" >/dev/null 2>&1; then
    echo "管理员 helper 启动失败"
    return 1
  fi
  if [ ! -r "$ADMIN_RESULT" ]; then
    echo "未收到管理员操作结果（可能已取消授权）"
    return 1
  fi

  after_run=$(/usr/bin/sed -n 's/^__RUN__=//p' "$ADMIN_RESULT" | /usr/bin/tail -1)
  if [ -z "$after_run" ] || [ "$after_run" = "$before_run" ]; then
    echo "管理员操作未执行（可能已取消授权）"
    return 1
  fi

  action_status=$(/usr/bin/sed -n 's/^__STATUS__=//p' "$ADMIN_RESULT" | /usr/bin/tail -1)
  /usr/bin/sed '/^__\(RUN\|STATUS\)__=/d' "$ADMIN_RESULT"
  [ "$action_status" = "0" ]
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
