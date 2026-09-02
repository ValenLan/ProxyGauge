#!/bin/bash

RESOURCE_DIR=$(/usr/bin/dirname "$0")

CHECK="$RESOURCE_DIR/proxygauge-check.sh"
[ -x "$CHECK" ] || CHECK="$HOME/.local/bin/proxygauge-check"
KILL_TOKEN="${PROXYGAUGE_KILL_TOKEN:-/var/run/proxygauge-killswitch.pf-token}"
DEFAULT_KILL_STATE=/var/run/proxygauge-killswitch.state
KILL_STATE="${PROXYGAUGE_KILL_STATE:-$DEFAULT_KILL_STATE}"
PF_CONF="${PROXYGAUGE_PF_CONF:-/etc/pf.conf}"
DEFAULT_CONFIG="$HOME/.config/proxygauge/config"
CONFIG_FILE="${PROXYGAUGE_CONFIG:-$DEFAULT_CONFIG}"
ENV_PROXYGAUGE_MIXED="${PROXYGAUGE_MIXED:-}"
ENV_SECONDARY_ENABLED="${PROXYGAUGE_SECONDARY_ENABLED:-}"
ENV_SECONDARY_LABEL="${PROXYGAUGE_SECONDARY_LABEL:-}"
ENV_SECONDARY_GROUP="${PROXYGAUGE_SECONDARY_GROUP:-}"
ENV_DEFAULT_GROUP="${PROXYGAUGE_DEFAULT_GROUP:-}"
ENV_SECONDARY_MIXED="${PROXYGAUGE_SECONDARY_MIXED:-}"
ENV_SECONDARY_DOMAINS="${PROXYGAUGE_SECONDARY_DOMAINS:-}"
ENV_TIMEOUT="${PROXYGAUGE_TIMEOUT:-}"
ENV_EXPECT_IP="${PROXYGAUGE_EXPECT_IP:-}"
ENV_MIHOMO_SOCKET="${PROXYGAUGE_MIHOMO_SOCKET:-}"
ENV_EXPECT_SECONDARY_IP="${PROXYGAUGE_EXPECT_SECONDARY_IP:-}"
ENV_ACTIVE_AI_PROBES="${PROXYGAUGE_ACTIVE_AI_PROBES:-}"

load_safe_config() {
  local config_path owner mode size line key value
  config_path="$1"
  [ -f "$config_path" ] && [ ! -L "$config_path" ] || return 0
  owner=$(/usr/bin/stat -f '%u' "$config_path" 2>/dev/null || true)
  mode=$(/usr/bin/stat -f '%Lp' "$config_path" 2>/dev/null || true)
  size=$(/usr/bin/stat -f '%z' "$config_path" 2>/dev/null || true)
  [ "$owner" = "$(/usr/bin/id -u)" ] || return 0
  [ -n "$mode" ] && [ $((8#$mode & 022)) -eq 0 ] || return 0
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  [ "$size" -le 65536 ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|[[:space:]]*'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key=$(/usr/bin/printf '%s' "${line%%=*}" \
      | /usr/bin/sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    value=$(/usr/bin/printf '%s' "${line#*=}" \
      | /usr/bin/sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    case "$key" in
      PROXYGAUGE_MIXED|PROXYGAUGE_SECONDARY_ENABLED|PROXYGAUGE_SECONDARY_LABEL|\
      PROXYGAUGE_SECONDARY_GROUP|PROXYGAUGE_DEFAULT_GROUP|\
      PROXYGAUGE_SECONDARY_MIXED|PROXYGAUGE_SECONDARY_DOMAINS|\
      PROXYGAUGE_TIMEOUT|PROXYGAUGE_EXPECT_IP|PROXYGAUGE_MIHOMO_SOCKET|\
      PROXYGAUGE_EXPECT_SECONDARY_IP|PROXYGAUGE_ACTIVE_AI_PROBES) ;;
      *) continue ;;
    esac
    case "$value" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
      *\"*|*\'*) continue ;;
    esac
    [ "${#value}" -le 4096 ] || continue
    case "$value" in *$'\n'*|*$'\r'*) continue ;; esac
    printf -v "$key" '%s' "$value"
  done < "$config_path"
}

load_safe_config "$CONFIG_FILE"
if [ -n "$ENV_PROXYGAUGE_MIXED" ]; then
  PROXYGAUGE_MIXED="$ENV_PROXYGAUGE_MIXED"
fi
if [ -n "$ENV_SECONDARY_ENABLED" ]; then PROXYGAUGE_SECONDARY_ENABLED="$ENV_SECONDARY_ENABLED"; fi
if [ -n "$ENV_SECONDARY_LABEL" ]; then PROXYGAUGE_SECONDARY_LABEL="$ENV_SECONDARY_LABEL"; fi
if [ -n "$ENV_SECONDARY_GROUP" ]; then PROXYGAUGE_SECONDARY_GROUP="$ENV_SECONDARY_GROUP"; fi
if [ -n "$ENV_DEFAULT_GROUP" ]; then PROXYGAUGE_DEFAULT_GROUP="$ENV_DEFAULT_GROUP"; fi
if [ -n "$ENV_SECONDARY_MIXED" ]; then PROXYGAUGE_SECONDARY_MIXED="$ENV_SECONDARY_MIXED"; fi
if [ -n "$ENV_SECONDARY_DOMAINS" ]; then PROXYGAUGE_SECONDARY_DOMAINS="$ENV_SECONDARY_DOMAINS"; fi
if [ -n "$ENV_TIMEOUT" ]; then PROXYGAUGE_TIMEOUT="$ENV_TIMEOUT"; fi
if [ -n "$ENV_EXPECT_IP" ]; then PROXYGAUGE_EXPECT_IP="$ENV_EXPECT_IP"; fi
if [ -n "$ENV_MIHOMO_SOCKET" ]; then PROXYGAUGE_MIHOMO_SOCKET="$ENV_MIHOMO_SOCKET"; fi
if [ -n "$ENV_EXPECT_SECONDARY_IP" ]; then PROXYGAUGE_EXPECT_SECONDARY_IP="$ENV_EXPECT_SECONDARY_IP"; fi
if [ -n "$ENV_ACTIVE_AI_PROBES" ]; then PROXYGAUGE_ACTIVE_AI_PROBES="$ENV_ACTIVE_AI_PROBES"; fi

normalize_local_endpoint() {
  /usr/bin/perl -MSocket=AF_INET6,inet_pton -e '
    use strict;
    use warnings;
    my $value = shift // exit 1;
    exit 1 if $value eq q{} || $value =~ /[\s\x00]/;
    $value =~ /\A(.+):([0-9]+)\z/ or exit 1;
    my ($host, $port_text) = ($1, $2);
    if ($host =~ /^\[(.*)\]$/) { $host = $1; }
    my $port = 0 + $port_text;
    exit 1 if $port < 1 || $port > 65535;
    if (lc($host) eq q{localhost}) {
      print qq{127.0.0.1:$port};
      exit 0;
    }
    if ($host =~ /\A([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)\z/) {
      my @octet = ($1, $2, $3, $4);
      for my $octet (@octet) {
        exit 1 if (length($octet) > 1 && substr($octet, 0, 1) eq q{0}) || $octet > 255;
      }
      exit 1 unless $octet[0] == 127;
      print join(q{.}, @octet) . qq{:$port};
      exit 0;
    }
    exit 1 if $host =~ /%/;
    my $packed = inet_pton(AF_INET6, $host);
    exit 1 unless defined($packed) && $packed eq (("\x00" x 15) . "\x01");
    print qq{[::1]:$port};
  ' -- "$1"
}

CONFIGURED_MIXED="${PROXYGAUGE_MIXED:-}"
MIXED_CONFIG_INVALID=""
if [ -n "$CONFIGURED_MIXED" ]; then
  MIXED=$(normalize_local_endpoint "$CONFIGURED_MIXED" 2>/dev/null || true)
  if [ -z "$MIXED" ]; then
    MIXED="127.0.0.1:7890"
    MIXED_CONFIG_INVALID=1
  fi
else
  MIXED="127.0.0.1:7890"
fi
MIXED_HOST="${MIXED%:*}"
MIXED_PORT="${MIXED##*:}"
MIXED_HOST="${MIXED_HOST#[}"
MIXED_HOST="${MIXED_HOST%]}"
export PROXYGAUGE_MIXED="$MIXED"
export PROXYGAUGE_SECONDARY_ENABLED PROXYGAUGE_SECONDARY_LABEL PROXYGAUGE_SECONDARY_GROUP
export PROXYGAUGE_DEFAULT_GROUP PROXYGAUGE_SECONDARY_MIXED PROXYGAUGE_SECONDARY_DOMAINS
export PROXYGAUGE_TIMEOUT PROXYGAUGE_EXPECT_IP PROXYGAUGE_MIHOMO_SOCKET
export PROXYGAUGE_EXPECT_SECONDARY_IP PROXYGAUGE_ACTIVE_AI_PROBES

raw_system_proxy_state() {
  if [ -n "${PROXYGAUGE_SYSTEM_PROXY_STATE+x}" ]; then
    /usr/bin/printf '%s\n' "$PROXYGAUGE_SYSTEM_PROXY_STATE"
  else
    /usr/sbin/scutil --proxy 2>/dev/null
  fi
}

top_level_system_proxy_state() {
  /usr/bin/perl -e '
    use strict;
    use warnings;
    my $depth = 0;
    my $skip_depth;
    while (<STDIN>) {
      my $line = $_;
      my $opens = () = $line =~ /\{/g;
      my $closes = () = $line =~ /\}/g;
      my $delta = $opens - $closes;
      if (!defined($skip_depth) && $depth == 1 &&
          $line =~ /^\s*__(?:SCOPED|MATCHES)__\s*:/) {
        if ($delta > 0) {
          $skip_depth = $depth;
          $depth += $delta;
        }
        next;
      }
      if (defined($skip_depth)) {
        $depth += $delta;
        undef($skip_depth) if $depth <= $skip_depth;
        next;
      }
      print $line;
      $depth += $delta;
    }
  '
}

RAW_SYSTEM_PROXY_SNAPSHOT=$(raw_system_proxy_state || true)
SYSTEM_PROXY_SNAPSHOT=$(/usr/bin/printf '%s\n' "$RAW_SYSTEM_PROXY_SNAPSHOT" \
  | top_level_system_proxy_state)

system_proxy_state() {
  /usr/bin/printf '%s\n' "$SYSTEM_PROXY_SNAPSHOT"
}

core_pids() {
  if [ -n "${PROXYGAUGE_CORE_PIDS+x}" ]; then
    /usr/bin/printf '%s\n' "$PROXYGAUGE_CORE_PIDS"
    return
  fi
  {
    /usr/bin/pgrep -x verge-mihomo 2>/dev/null || true
    /usr/bin/pgrep -x mihomo 2>/dev/null || true
    /usr/bin/pgrep -x clash-meta 2>/dev/null || true
  } | /usr/bin/awk 'NF && !seen[$0]++'
}

socket_owned_by_mihomo() {
  local socket_path records owner_pid core_pid
  socket_path="$1"
  case "${PROXYGAUGE_DISCOVERY_SOCKET_OWNER:-}" in
    mihomo) return 0 ;;
    other|unknown) return 1 ;;
  esac
  records=$(/usr/sbin/lsof -nP -a -U -Fpn -- "$socket_path" 2>/dev/null) || return 1
  while IFS= read -r owner_pid; do
    case "$owner_pid" in ''|*[!0-9]*) continue ;; esac
    while IFS= read -r core_pid; do
      case "$core_pid" in ''|*[!0-9]*) continue ;; esac
      [ "$owner_pid" = "$core_pid" ] && return 0
    done < <(core_pids)
  done < <(/usr/bin/printf '%s\n' "$records" \
    | /usr/bin/awk '/^p[0-9]+$/ { print substr($0, 2) }')
  return 1
}

if [ -n "${PROXYGAUGE_TUN_ROUTE_TABLE+x}" ]; then
  ROUTE_TABLE_INET_SNAPSHOT="$PROXYGAUGE_TUN_ROUTE_TABLE"
  ROUTE_TABLE_INET6_SNAPSHOT="$PROXYGAUGE_TUN_ROUTE_TABLE"
else
  ROUTE_TABLE_INET_SNAPSHOT=$(/usr/sbin/netstat -rn -f inet 2>/dev/null || true)
  ROUTE_TABLE_INET6_SNAPSHOT=$(/usr/sbin/netstat -rn -f inet6 2>/dev/null || true)
fi

tun_route_table() {
  if [ -n "${PROXYGAUGE_TUN_ROUTE_TABLE+x}" ]; then
    /usr/bin/printf '%s\n' "$PROXYGAUGE_TUN_ROUTE_TABLE"
  else
    /usr/bin/printf '%s\n%s\n' \
      "$ROUTE_TABLE_INET_SNAPSHOT" "$ROUTE_TABLE_INET6_SNAPSHOT"
  fi
}

route_family_table() {
  case "$1" in
    inet) /usr/bin/printf '%s\n' "$ROUTE_TABLE_INET_SNAPSHOT" ;;
    inet6) /usr/bin/printf '%s\n' "$ROUTE_TABLE_INET6_SNAPSHOT" ;;
  esac
}

route_family_has_default() {
  route_family_table "$1" | /usr/bin/awk '
    tolower($1) == "default" { found = 1; exit }
    END { exit found ? 0 : 1 }
  '
}

has_tun_route() {
  case "${PROXYGAUGE_TUN_ACTIVE:-}" in
    1|true|yes) return 0 ;;
    0|false|no) return 1 ;;
  esac
  tun_route_table | /usr/bin/awk '
    {
      interface = ""
      for (column = 1; column <= NF; column++) {
        if ($column ~ /^(utun|ppp|ipsec|tun|tap)[0-9]+$/) {
          interface = $column
          break
        }
      }
    }
    interface != "" {
      destination = tolower($1)
      if (destination == "default" ||
          (destination !~ /^fe80:/ && destination !~ /^ff/ &&
           destination !~ /^169\.254\./ && destination !~ /^22[4-9]\./ &&
           destination !~ /^23[0-9]\./ && destination !~ /^255\./)) {
        found = 1
        exit
      }
    }
    END { exit found ? 0 : 1 }
  '
}

fake_ip_route_interface() {
  tun_route_table | /usr/bin/awk '
    {
      interface = ""
      for (column = 1; column <= NF; column++) {
        if ($column ~ /^(utun|tun|tap)[0-9]+$/) { interface = $column; break }
      }
    }
    interface != "" && tolower($1) ~ /^198\.(18|19)(\.|\/|$)/ {
      if (device != "" && device != interface) multiple = 1
      device = interface
    }
    END {
      if (device != "" && !multiple) print device
      else exit 1
    }
  '
}

route_lookup_interface() {
  local family destination result
  family="$1"
  destination="$2"

  if [ -n "${PROXYGAUGE_ROUTE_LOOKUP_RESULTS+x}" ]; then
    result=$(/usr/bin/printf '%s\n' "$PROXYGAUGE_ROUTE_LOOKUP_RESULTS" \
      | /usr/bin/awk -v family="$family" -v destination="$destination" '
          $1 == family && $2 == destination { print $3; found = 1; exit }
          END { if (!found) exit 1 }
        ') || result="unknown"
    case "$result" in
      unavailable|unknown|[A-Za-z0-9]* ) /usr/bin/printf '%s\n' "$result" ;;
      *) /usr/bin/printf '%s\n' unknown ;;
    esac
    return
  fi

  if result=$(/sbin/route -n get "-$family" "$destination" 2>/dev/null \
    | /usr/bin/awk '/^[[:space:]]*interface:[[:space:]]*/ { print $2; exit }'); then
    if /usr/bin/grep -Eq '^[A-Za-z0-9._-]+$' <<< "$result"; then
      /usr/bin/printf '%s\n' "$result"
      return
    fi
  fi
  if route_family_has_default "$family"; then
    /usr/bin/printf '%s\n' unknown
  else
    /usr/bin/printf '%s\n' unavailable
  fi
}

representative_route_interface() {
  local family destination result interfaces resolved unavailable unknown unique_count
  family="$1"
  shift
  interfaces=""
  resolved=0
  unavailable=0
  unknown=0

  for destination in "$@"; do
    result=$(route_lookup_interface "$family" "$destination")
    case "$result" in
      unavailable) unavailable=$((unavailable + 1)) ;;
      unknown) unknown=$((unknown + 1)) ;;
      *)
        resolved=$((resolved + 1))
        interfaces="${interfaces}${interfaces:+$'\n'}${result}"
        ;;
    esac
  done

  if [ "$unknown" -gt 0 ] || { [ "$resolved" -gt 0 ] && [ "$unavailable" -gt 0 ]; }; then
    /usr/bin/printf '%s\n' unknown
    return
  fi
  if [ "$resolved" -eq 0 ]; then
    /usr/bin/printf '%s\n' unavailable
    return
  fi
  unique_count=$(/usr/bin/printf '%s\n' "$interfaces" \
    | /usr/bin/awk 'NF && !seen[$0]++ { count++ } END { print count+0 }')
  if [ "$unique_count" -ne 1 ]; then
    /usr/bin/printf '%s\n' split
  else
    /usr/bin/printf '%s\n' "$interfaces" | /usr/bin/awk 'NF { print; exit }'
  fi
}

mihomo_tun_device() {
  local json socket_path enabled device
  case "${PROXYGAUGE_MIHOMO_TUN_ACTIVE:-}" in
    1|true|yes) enabled=true ;;
    0|false|no) return 1 ;;
  esac

  if [ -n "${PROXYGAUGE_MIHOMO_TUN_DEVICE:-}" ]; then
    device="$PROXYGAUGE_MIHOMO_TUN_DEVICE"
  else
    if [ -n "${PROXYGAUGE_DISCOVERY_SOCKET_JSON:-}" ] \
      && [ -r "$PROXYGAUGE_DISCOVERY_SOCKET_JSON" ]; then
      json=$(/bin/cat "$PROXYGAUGE_DISCOVERY_SOCKET_JSON" 2>/dev/null) || return 1
    else
      socket_path="${PROXYGAUGE_DISCOVERY_SOCKET:-${PROXYGAUGE_MIHOMO_SOCKET:-/private/tmp/verge/verge-mihomo.sock}}"
      [ -S "$socket_path" ] || return 1
      socket_owned_by_mihomo "$socket_path" || return 1
      json=$(/usr/bin/curl --disable --proxy "" -fsS --connect-timeout 2 --max-time 2 \
        --max-filesize 65536 --unix-socket "$socket_path" \
        http://localhost/configs 2>/dev/null) || return 1
    fi
    if [ -z "${enabled:-}" ]; then
      enabled=$(/usr/bin/printf '%s' "$json" \
        | /usr/bin/plutil -extract 'tun.enable' raw -o - -- - 2>/dev/null) || return 1
    fi
    device=$(/usr/bin/printf '%s' "$json" \
      | /usr/bin/plutil -extract 'tun.device' raw -o - -- - 2>/dev/null) || device=""
  fi
  case "$enabled" in true|1) ;; *) return 1 ;; esac
  if /usr/bin/grep -Eq '^utun[0-9]+$' <<< "$device"; then
    /usr/bin/printf '%s\n' "$device"
  fi
  return 0
}

classify_tunnel_route() {
  local device fake_device candidate inet_route inet6_route available_count route_interface
  if ! has_tun_route; then
    /usr/bin/printf '%s\n' none
    return
  fi
  case "${PROXYGAUGE_TUN_KIND:-}" in
    mihomo|mihomo-unconfirmed|split|unknown|other|none)
      /usr/bin/printf '%s\n' "$PROXYGAUGE_TUN_KIND"
      return
      ;;
  esac
  if ! device=$(mihomo_tun_device 2>/dev/null); then
    /usr/bin/printf '%s\n' other
    return
  fi

  fake_device=$(fake_ip_route_interface 2>/dev/null || true)
  candidate="$device"
  [ -n "$candidate" ] || candidate="$fake_device"
  if [ -z "$candidate" ]; then
    /usr/bin/printf '%s\n' mihomo-unconfirmed
    return
  fi

  inet_route=$(representative_route_interface inet \
    1.1.1.1 8.8.8.8 9.9.9.9 208.67.222.222)
  inet6_route=$(representative_route_interface inet6 \
    2606:4700:4700::1111 2001:4860:4860::8888 2620:fe::fe 2620:119:35::35)

  case "$inet_route:$inet6_route" in
    *unknown* ) /usr/bin/printf '%s\n' unknown; return ;;
    *split* ) /usr/bin/printf '%s\n' split; return ;;
  esac

  available_count=0
  for route_interface in "$inet_route" "$inet6_route"; do
    [ "$route_interface" = unavailable ] && continue
    available_count=$((available_count + 1))
    if [ "$route_interface" != "$candidate" ]; then
      /usr/bin/printf '%s\n' split
      return
    fi
  done
  if [ "$available_count" -eq 0 ]; then
    /usr/bin/printf '%s\n' unknown
  else
    /usr/bin/printf '%s\n' mihomo
  fi
}

system_proxy_active() {
  case "${PROXYGAUGE_SYSTEM_PROXY_ACTIVE:-}" in
    1|true|yes) return 0 ;;
    0|false|no) return 1 ;;
  esac
  system_proxy_state \
    | /usr/bin/grep -qE '(HTTP|HTTPS|SOCKS)Enable : 1|ProxyAuto(Config|Discovery)Enable : 1'
}

system_proxy_dynamic() {
  case "${PROXYGAUGE_SYSTEM_PROXY_DYNAMIC:-}" in
    1|true|yes) return 0 ;;
    0|false|no) return 1 ;;
  esac
  if [ -n "${PROXYGAUGE_SYSTEM_PROXY_ACTIVE+x}" ]; then
    return 1
  fi
  system_proxy_state \
    | /usr/bin/grep -qE 'ProxyAuto(Config|Discovery)Enable : 1'
}

system_proxy_covers_https() {
  case "${PROXYGAUGE_SYSTEM_PROXY_HTTPS:-}" in
    1|true|yes) return 0 ;;
    0|false|no) return 1 ;;
  esac
  if [ -n "${PROXYGAUGE_SYSTEM_PROXY_ACTIVE+x}" ]; then
    return 0
  fi
  system_proxy_state \
    | /usr/bin/grep -qE '(HTTPS|SOCKS)Enable : 1'
}

system_proxy_bypasses_exit_lookup() {
  case "${PROXYGAUGE_SYSTEM_PROXY_BYPASS:-}" in
    1|true|yes) return 0 ;;
    0|false|no) return 1 ;;
  esac
  if [ -n "${PROXYGAUGE_SYSTEM_PROXY_ACTIVE+x}" ]; then
    return 1
  fi
  system_proxy_state | /usr/bin/perl -e '
    use strict;
    use warnings;
    sub wildcard_matches {
      my ($pattern, $host) = @_;
      return 1 if $pattern =~ /^\./ && substr($pattern, 1) eq $host;
      my $regex = quotemeta($pattern);
      $regex =~ s/\\\*/.*/g;
      return $host =~ /\A$regex\z/i;
    }
    my @target = qw(ipapi.co ipwho.is api.ipify.org ifconfig.me ip.sb);
    my $inside = 0;
    while (<STDIN>) {
      $inside = 1, next if /^\s*ExceptionsList\s*:/;
      $inside = 0, next if $inside && /^\s*}/;
      next unless $inside && /^\s*\d+\s*:\s*(.*?)\s*$/;
      my $pattern = lc $1;
      for my $host (@target) {
        exit 0 if wildcard_matches($pattern, $host);
      }
    }
    exit 1;
  '
}

discovery_port_open() {
  local host port
  host="$1"
  port="$2"
  host="${host#[}"
  host="${host%]}"
  case "${PROXYGAUGE_DISCOVERY_PORT_ACTIVE:-}" in
    1|true|yes) return 0 ;;
    0|false|no) return 1 ;;
  esac
  (exec 3<>/dev/tcp/"$host"/"$port") 2>/dev/null
}

matching_listener_pids() {
  local host port family selector records
  host="$1"
  port="$2"
  host="${host#[}"
  host="${host%]}"
  case "$host" in
    *:*) family=inet6; selector="-i6TCP:$port" ;;
    *) family=inet; selector="-i4TCP:$port" ;;
  esac
  if [ -n "${PROXYGAUGE_DISCOVERY_LISTENER_RECORDS+x}" ]; then
    records="$PROXYGAUGE_DISCOVERY_LISTENER_RECORDS"
  else
    records=$(/usr/sbin/lsof -nP -a "$selector" -sTCP:LISTEN -Fpn 2>/dev/null) \
      || return 1
  fi
  /usr/bin/printf '%s\n' "$records" \
    | /usr/bin/perl -e '
        use strict;
        use warnings;
        my ($target, $port, $family) = @ARGV;
        my $pid = q{};
        my %seen;
        while (<STDIN>) {
          chomp;
          if (/^p([0-9]+)$/) {
            $pid = $1;
            next;
          }
          next unless $pid ne q{} && /^n(.+)$/;
          my $name = $1;
          $name =~ s/\s+\(LISTEN\)\z//;
          my $address;
          if ($name =~ /^\[([^]]+)\]:\Q$port\E\z/) {
            $address = $1;
          } elsif ($name =~ /^(.*):\Q$port\E\z/) {
            $address = $1;
          } else {
            next;
          }
          my $matches = lc($address) eq lc($target);
          if ($family eq q{inet}) {
            $matches ||= $address eq q{*} || $address eq q{0.0.0.0};
          } else {
            $matches ||= $address eq q{*} || $address eq q{::};
          }
          print "$pid\n" if $matches && !$seen{$pid}++;
        }
      ' -- "$host" "$port" "$family" \
    | /usr/bin/awk 'NF && !seen[$0]++'
}

listener_owned_by_mihomo() {
  local host port owner_pids core_pid owner_pid
  host="$1"
  port="$2"

  case "${PROXYGAUGE_DISCOVERY_PORT_OWNER:-}" in
    mihomo) return 0 ;;
    other|unknown) return 1 ;;
  esac

  owner_pids=$(matching_listener_pids "$host" "$port") || return 1
  [ -n "$owner_pids" ] || return 1

  while IFS= read -r core_pid; do
    case "$core_pid" in ''|*[!0-9]*) continue ;; esac
    while IFS= read -r owner_pid; do
      [ "$core_pid" = "$owner_pid" ] && return 0
    done <<< "$owner_pids"
  done < <(core_pids)
  return 1
}

core_listener_records() {
  local core_pid
  if [ -n "${PROXYGAUGE_DISCOVERY_LISTENER_RECORDS+x}" ]; then
    /usr/bin/printf '%s\n' "$PROXYGAUGE_DISCOVERY_LISTENER_RECORDS"
    return
  fi
  while IFS= read -r core_pid; do
    case "$core_pid" in ''|*[!0-9]*) continue ;; esac
    /usr/sbin/lsof -nP -a -p "$core_pid" -iTCP -sTCP:LISTEN -Fpn 2>/dev/null || true
  done < <(core_pids)
}

valid_local_endpoint() {
  [ -n "$(normalize_local_endpoint "$1" 2>/dev/null || true)" ]
}

system_proxy_endpoint() {
  if [ -n "${PROXYGAUGE_DISCOVERY_SYSTEM_PROXY:-}" ]; then
    /usr/bin/printf '%s\n' "$PROXYGAUGE_DISCOVERY_SYSTEM_PROXY"
    return
  fi

  system_proxy_state | /usr/bin/awk '
    function endpoint(host, port) {
      return index(host, ":") ? "[" host "]:" port : host ":" port
    }
    /HTTPSEnable : 1/ { https_enabled = 1 }
    /HTTPSProxy :/ { https_host = $3 }
    /HTTPSPort :/ { https_port = $3 }
    /SOCKSEnable : 1/ { socks_enabled = 1 }
    /SOCKSProxy :/ { socks_host = $3 }
    /SOCKSPort :/ { socks_port = $3 }
    END {
      if (https_enabled && https_host != "" && https_port ~ /^[0-9]+$/) {
        print endpoint(https_host, https_port)
      } else if (socks_enabled && socks_host != "" && socks_port ~ /^[0-9]+$/) {
        print endpoint(socks_host, socks_port)
      }
    }
  '
}

system_proxy_matches_mixed() {
  local candidate
  case "${PROXYGAUGE_SYSTEM_PROXY_MATCHES:-}" in
    1|true|yes) return 0 ;;
    0|false|no) return 1 ;;
  esac
  if [ -n "${PROXYGAUGE_SYSTEM_PROXY_ACTIVE+x}" ]; then
    return 0
  fi
  candidate=$(normalize_local_endpoint "$(system_proxy_endpoint)" 2>/dev/null || true)
  [ -n "$candidate" ] || return 1
  [ "$candidate" = "$MIXED" ]
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
  socket_path="${PROXYGAUGE_DISCOVERY_SOCKET:-${PROXYGAUGE_MIHOMO_SOCKET:-/private/tmp/verge/verge-mihomo.sock}}"

  if [ -n "${PROXYGAUGE_DISCOVERY_SOCKET_JSON:-}" ]; then
    [ -r "$PROXYGAUGE_DISCOVERY_SOCKET_JSON" ] || return 1
    json=$(/bin/cat "$PROXYGAUGE_DISCOVERY_SOCKET_JSON")
  else
    [ -S "$socket_path" ] || return 1
    socket_owned_by_mihomo "$socket_path" || return 1
    json=$(/usr/bin/curl --disable -fsS --max-filesize 65536 --max-time 2 --unix-socket "$socket_path" \
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
  local system_active tun_active mihomo_tun_unconfirmed split_tun_active
  local unknown_tun_active other_tun_active tunnel_kind

  client="未识别"
  endpoint=""
  source=""
  active="idle"
  system_active=""
  tun_active=""
  mihomo_tun_unconfirmed=""
  split_tun_active=""
  unknown_tun_active=""
  other_tun_active=""

  if [ -n "${PROXYGAUGE_DISCOVERY_CLIENT:-}" ]; then
    client="$PROXYGAUGE_DISCOVERY_CLIENT"
  elif /usr/bin/pgrep -x verge-mihomo >/dev/null 2>&1; then
    client="Clash Verge Rev"
  elif /usr/bin/pgrep -x mihomo >/dev/null 2>&1; then
    client="Mihomo"
  elif /usr/bin/pgrep -x clash-meta >/dev/null 2>&1; then
    client="Clash Meta"
  fi

  if system_proxy_active; then system_active=1; fi
  tunnel_kind=$(classify_tunnel_route)
  [ "$tunnel_kind" = mihomo ] && tun_active=1
  [ "$tunnel_kind" = mihomo-unconfirmed ] && mihomo_tun_unconfirmed=1
  [ "$tunnel_kind" = split ] && split_tun_active=1
  [ "$tunnel_kind" = unknown ] && unknown_tun_active=1
  [ "$tunnel_kind" = other ] && other_tun_active=1
  if [ -n "$system_active" ] && [ -n "$other_tun_active" ]; then
    mode="系统代理 + 其他 VPN / TUN"
  elif [ -n "$system_active" ] && [ -n "$tun_active" ]; then
    if system_proxy_dynamic; then
      mode="PAC / 自动代理 + Mihomo TUN"
    elif ! system_proxy_covers_https \
      || system_proxy_bypasses_exit_lookup \
      || ! system_proxy_matches_mixed; then
      mode="系统代理路径 + Mihomo TUN"
    else
      mode="双重入口"
    fi
  elif [ -n "$system_active" ] && [ -n "$mihomo_tun_unconfirmed" ]; then
    mode="系统代理 + Mihomo TUN（路由待确认）"
  elif [ -n "$system_active" ] && [ -n "$split_tun_active" ]; then
    mode="系统代理 + Mihomo TUN（代表性路由不一致）"
  elif [ -n "$system_active" ] && [ -n "$unknown_tun_active" ]; then
    mode="系统代理 + Mihomo TUN（路由查询失败）"
  elif [ -n "$tun_active" ]; then
    mode="TUN"
  elif [ -n "$mihomo_tun_unconfirmed" ]; then
    mode="Mihomo TUN（路由待确认）"
  elif [ -n "$split_tun_active" ]; then
    mode="Mihomo TUN（代表性路由不一致）"
  elif [ -n "$unknown_tun_active" ]; then
    mode="Mihomo TUN（路由查询失败）"
  elif [ -n "$other_tun_active" ]; then
    mode="其他 VPN / TUN"
  elif [ -n "$system_active" ]; then
    if system_proxy_dynamic; then mode="PAC / 自动代理"; else mode="系统代理"; fi
  else
    mode="未开启"
  fi

  if [ -z "$endpoint" ] && [ -n "$system_active" ] && ! system_proxy_dynamic; then
    candidate=$(normalize_local_endpoint "$(system_proxy_endpoint)" 2>/dev/null || true)
    if [ -n "$candidate" ]; then
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

  config_path="${PROXYGAUGE_DISCOVERY_CONFIG:-$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml}"
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
    endpoint=$(normalize_local_endpoint "$CONFIGURED_MIXED")
    source="ProxyGauge 设置"
  fi

  if [ -z "$endpoint" ]; then
    for port in 7890 7897; do
      if discovery_port_open 127.0.0.1 "$port" \
        && listener_owned_by_mihomo 127.0.0.1 "$port"; then
        endpoint="127.0.0.1:$port"
        source="本地监听端口"
        break
      fi
    done
  fi

  if [ -n "$endpoint" ]; then
    candidate="${endpoint%:*}"
    port="${endpoint##*:}"
    if discovery_port_open "$candidate" "$port" \
      && listener_owned_by_mihomo "$candidate" "$port"; then
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
  local state_owner state_mode expected_owner state_value state_detail

  if [ ! -r "$PF_CONF" ] || ! /usr/bin/grep -qE \
    '^[[:space:]]*anchor[[:space:]]+"proxygauge"' \
    "$PF_CONF" 2>/dev/null; then
    /usr/bin/printf '未配置\tidle\n'
    return
  fi

  if [ -f "$KILL_STATE" ] && [ ! -L "$KILL_STATE" ]; then
    state_owner=$(/usr/bin/stat -f '%u' "$KILL_STATE" 2>/dev/null || true)
    state_mode=$(/usr/bin/stat -f '%Lp' "$KILL_STATE" 2>/dev/null || true)
    expected_owner=0
    if [ "$KILL_STATE" != "$DEFAULT_KILL_STATE" ]; then
      expected_owner=$(/usr/bin/id -u)
    fi
    if [ "$state_owner" = "$expected_owner" ] && [ -n "$state_mode" ] \
      && [ $((8#$state_mode & 022)) -eq 0 ]; then
      IFS=$'\t' read -r state_value state_detail < "$KILL_STATE"
      case "$state_value" in
        enabled)
          if [ -e "$KILL_TOKEN" ]; then
            /usr/bin/printf '已开启\tok\n'
          else
            /usr/bin/printf '恢复中\twarning\n'
          fi
          return
          ;;
        disabled)
          /usr/bin/printf '已关闭\twarning\n'
          return
          ;;
        fault)
          /usr/bin/printf '需要修复\terror\n'
          return
          ;;
      esac
    fi
  fi

  if [ -e "$KILL_TOKEN" ]; then
    /usr/bin/printf '待确认\tidle\n'
  else
    /usr/bin/printf '已关闭\twarning\n'
  fi
}

probe() {
  local core_count core_value core_level port_value port_level
  local system_value system_level tun_value tun_level kill_value kill_level
  local entry_value entry_level entry_title entry_symbol
  local overall headline detail entry_ok system_active tun_active mihomo_tun_unconfirmed
  local split_tun_active unknown_tun_active other_tun_active tunnel_kind

  core_count=$(core_pids | /usr/bin/awk 'NF {count++} END {print count+0}')
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

  if [ -n "$MIXED_CONFIG_INVALID" ]; then
    port_value="配置无效"
    port_level="error"
  elif discovery_port_open "$MIXED_HOST" "$MIXED_PORT"; then
    if listener_owned_by_mihomo "$MIXED_HOST" "$MIXED_PORT"; then
      port_value="${MIXED_PORT} 监听中"
      port_level="ok"
    else
      port_value="${MIXED_PORT} 监听器未确认"
      port_level="warning"
    fi
  else
    port_value="${MIXED_PORT} 未监听"
    port_level="error"
  fi

  entry_ok=""
  entry_uncertain=""
  system_https_missing=""
  system_bypass=""
  system_active=""
  tun_active=""
  mihomo_tun_unconfirmed=""
  split_tun_active=""
  unknown_tun_active=""
  other_tun_active=""
  if system_proxy_active; then
    if system_proxy_dynamic; then
      system_value="按目标决定"
      system_level="warning"
      entry_uncertain=1
    elif ! system_proxy_covers_https; then
      system_value="HTTPS 未接管"
      system_level="warning"
      system_https_missing=1
      entry_uncertain=1
    elif system_proxy_bypasses_exit_lookup; then
      system_value="出口域名被绕过"
      system_level="warning"
      system_bypass=1
      entry_uncertain=1
    elif system_proxy_matches_mixed; then
      system_value="已启用"
      system_level="ok"
    else
      system_value="入口不匹配"
      system_level="warning"
      entry_uncertain=1
    fi
    system_active=1
  else
    system_value="未启用"
    system_level="idle"
  fi

  tunnel_kind=$(classify_tunnel_route)
  if [ "$tunnel_kind" = mihomo ]; then
    tun_value="代表性路由已确认"
    tun_level="ok"
    tun_active=1
  elif [ "$tunnel_kind" = mihomo-unconfirmed ]; then
    tun_value="路由归属待确认"
    tun_level="warning"
    mihomo_tun_unconfirmed=1
    entry_uncertain=1
  elif [ "$tunnel_kind" = split ]; then
    tun_value="代表性路由不一致"
    tun_level="warning"
    split_tun_active=1
    entry_uncertain=1
  elif [ "$tunnel_kind" = unknown ]; then
    tun_value="路由查询失败"
    tun_level="warning"
    unknown_tun_active=1
    entry_uncertain=1
  elif [ "$tunnel_kind" = other ]; then
    tun_value="检测到其他隧道"
    tun_level="warning"
    other_tun_active=1
  else
    tun_value="未接管"
    tun_level="idle"
  fi

  if [ -n "$tun_active" ] && [ -z "$system_active" ] \
    && [ "$port_level" != ok ]; then
    port_value="${MIXED_PORT} 非当前入口"
    port_level="idle"
  fi

  if [ -n "$system_active" ] && [ -n "$other_tun_active" ]; then
    entry_title="系统代理 + 其他 VPN / TUN"
    entry_value="同时检测"
    entry_level="warning"
    entry_symbol="exclamationmark.triangle.fill"
    entry_uncertain=1
    entry_ok=1
  elif [ -n "$system_active" ] && [ -n "$mihomo_tun_unconfirmed" ]; then
    entry_title="系统代理 + Mihomo TUN"
    entry_value="路由待确认"
    entry_level="warning"
    entry_symbol="exclamationmark.triangle.fill"
    entry_uncertain=1
    entry_ok=1
  elif [ -n "$system_active" ] && [ -n "$split_tun_active$unknown_tun_active" ]; then
    entry_title="系统代理 + Mihomo TUN"
    if [ -n "$split_tun_active" ]; then
      entry_value="代表性路由不一致"
    else
      entry_value="路由查询失败"
    fi
    entry_level="warning"
    entry_symbol="exclamationmark.triangle.fill"
    entry_uncertain=1
    entry_ok=1
  elif [ -n "$system_active" ] && [ -n "$tun_active" ]; then
    if [ -n "$entry_uncertain" ]; then
      if system_proxy_dynamic; then
        entry_title="PAC / 自动代理 + Mihomo TUN"
      else
        entry_title="系统代理路径 + Mihomo TUN"
      fi
      entry_value="$system_value"
    else
      entry_title="双重入口"
      entry_value="同时开启"
    fi
    entry_level="warning"
    entry_symbol="exclamationmark.triangle.fill"
    entry_ok=1
  elif [ -n "$tun_active" ]; then
    entry_title="TUN 路由"
    entry_value="代表性路由已确认"
    entry_level="ok"
    entry_symbol="arrow.triangle.2.circlepath"
    entry_ok=1
  elif [ -n "$mihomo_tun_unconfirmed" ]; then
    entry_title="Mihomo TUN"
    entry_value="路由待确认"
    entry_level="warning"
    entry_symbol="exclamationmark.triangle.fill"
    entry_uncertain=1
    entry_ok=1
  elif [ -n "$split_tun_active$unknown_tun_active" ]; then
    entry_title="Mihomo TUN"
    if [ -n "$split_tun_active" ]; then
      entry_value="代表性路由不一致"
    else
      entry_value="路由查询失败"
    fi
    entry_level="warning"
    entry_symbol="exclamationmark.triangle.fill"
    entry_uncertain=1
    entry_ok=1
  elif [ -n "$other_tun_active" ]; then
    entry_title="其他 VPN / TUN"
    entry_value="已检测"
    entry_level="warning"
    entry_symbol="exclamationmark.triangle.fill"
    entry_uncertain=1
    entry_ok=1
  elif [ -n "$system_active" ]; then
    if system_proxy_dynamic; then
      entry_title="PAC / 自动代理"
      entry_value="按目标决定"
      entry_level="warning"
    elif [ -n "$system_https_missing" ]; then
      entry_title="系统代理"
      entry_value="HTTPS 未接管"
      entry_level="warning"
    elif [ -n "$system_bypass" ]; then
      entry_title="系统代理"
      entry_value="出口域名被绕过"
      entry_level="warning"
    elif [ -n "$entry_uncertain" ]; then
      entry_title="系统代理"
      entry_value="入口不匹配"
      entry_level="warning"
    else
      entry_title="系统代理"
      entry_value="已启用"
      entry_level="ok"
    fi
    entry_symbol="arrow.left.arrow.right"
    entry_ok=1
  else
    entry_title="流量入口"
    entry_value="未启用"
    entry_level="idle"
    entry_symbol="arrow.triangle.branch"
  fi

  IFS=$'\t' read -r kill_value kill_level < <(kill_switch_snapshot)

  if [ "$core_count" = "1" ] && [ -n "$tun_active" ] \
    && [ -z "$system_active" ]; then
    overall="ok"
    headline="代理路径已确认"
    detail="Mihomo TUN 的代表性 IPv4 / IPv6 路由已确认"
  elif [ "$core_count" = "1" ] && [ "$port_level" = "ok" ] \
    && [ -n "$system_active" ] \
    && [ -n "$tun_active$mihomo_tun_unconfirmed$split_tun_active$unknown_tun_active$other_tun_active" ]; then
    overall="warning"
    if [ -n "$other_tun_active" ]; then
      headline="入口同时开启"
      detail="系统代理与其他 VPN/TUN 均已启用，不能归因于 Mihomo"
    elif [ -n "$mihomo_tun_unconfirmed" ]; then
      headline="Mihomo TUN 路由待确认"
      detail="Mihomo 已启用 TUN，但当前活动路由无法与具体 utun 设备匹配"
    elif [ -n "$split_tun_active" ]; then
      headline="Mihomo TUN 路由不一致"
      detail="代表性公网目标走不同接口，可能存在同族或 IPv4 / IPv6 分流"
    elif [ -n "$unknown_tun_active" ]; then
      headline="Mihomo TUN 路由查询失败"
      detail="无法可靠读取代表性公网目标的本地路由，未判定为已接管"
    elif [ -n "$entry_uncertain" ]; then
      headline="入口路径需确认"
      detail="Mihomo TUN 的代表性路由已确认，但系统代理路径未确认指向当前本地入口"
    else
      headline="入口同时开启"
      detail="系统代理与 Mihomo TUN 均已启用"
    fi
  elif [ "$core_count" = "1" ] && [ "$port_level" = "ok" ] && [ -n "$entry_ok" ]; then
    if [ -n "$entry_uncertain" ]; then
      overall="warning"
      if [ -n "$mihomo_tun_unconfirmed" ]; then
        headline="Mihomo TUN 路由待确认"
        detail="Mihomo 已启用 TUN，但当前活动路由无法与具体 utun 设备匹配"
      elif [ -n "$split_tun_active" ]; then
        headline="Mihomo TUN 路由不一致"
        detail="代表性公网目标走不同接口，可能存在同族或 IPv4 / IPv6 分流"
      elif [ -n "$unknown_tun_active" ]; then
        headline="Mihomo TUN 路由查询失败"
        detail="无法可靠读取代表性公网目标的本地路由，未判定为已接管"
      elif [ -n "$other_tun_active" ] && [ -z "$system_active" ]; then
        headline="检测到其他 VPN/TUN"
        detail="活动隧道路由不能归因于 Mihomo；请以系统实际出口为准"
      else
        headline="入口路径需确认"
        detail="系统代理未明确指向当前检测入口，请以系统实际出口为准"
      fi
    else
      overall="ok"
      headline="代理已接管"
      detail="流量入口当前工作正常"
    fi
  elif [ "$core_count" -gt 1 ] 2>/dev/null; then
    overall="warning"
    headline="状态异常"
    detail="检测到多个代理核心，请关闭重复核心后刷新状态"
  elif [ -n "$other_tun_active" ]; then
    overall="warning"
    headline="检测到其他 VPN/TUN"
    detail="系统存在活动隧道路由，但不能归因于 Mihomo；请以系统实际出口为准"
  elif [ -n "$mihomo_tun_unconfirmed" ]; then
    overall="warning"
    headline="Mihomo TUN 路由待确认"
    detail="Mihomo 已启用 TUN，但当前活动路由无法与具体 utun 设备匹配"
  elif [ -n "$split_tun_active" ]; then
    overall="warning"
    headline="Mihomo TUN 路由不一致"
    detail="代表性公网目标走不同接口，可能存在同族或 IPv4 / IPv6 分流"
  elif [ -n "$unknown_tun_active" ]; then
    overall="warning"
    headline="Mihomo TUN 路由查询失败"
    detail="无法可靠读取代表性公网目标的本地路由，未判定为已接管"
  elif [ -n "$system_active" ]; then
    overall="warning"
    headline="检测到系统代理路径"
    detail="系统代理已启用，但不是当前已确认的 Mihomo 入口；请以系统实际出口为准"
  elif [ -n "$tun_active" ]; then
    overall="warning"
    headline="检测到 TUN 路径"
    detail="代表性隧道路由已确认，但当前 Mihomo 核心状态不完整"
  else
    overall="error"
    headline="代理未完整生效"
    detail="请检查代理核心、本地入口与系统代理或 TUN 后刷新"
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

local_fingerprint() {
  local cores listeners listener_signature route_signature
  cores=$(core_pids | /usr/bin/awk 'NF' | /usr/bin/sort -n | /usr/bin/paste -sd, -)
  listeners=$(matching_listener_pids "$MIXED_HOST" "$MIXED_PORT" 2>/dev/null \
    | /usr/bin/sort -n | /usr/bin/paste -sd, -)
  listener_signature=$(core_listener_records | /usr/bin/sort | /usr/bin/cksum \
    | /usr/bin/awk '{ print $1 ":" $2 }')
  # Do not hash the complete netstat rows: macOS can include an Expire column
  # whose countdown changes even though the route itself has not changed. Keep
  # only the stable route identity that can affect our TUN classification.
  route_signature=$(tun_route_table | /usr/bin/awk '
    {
      interface = ""
      for (column = 1; column <= NF; column++) {
        if ($column ~ /^(utun|ppp|ipsec|tun|tap)[0-9]+$/) {
          interface = $column
          break
        }
      }
      if (interface != "") print tolower($1) "@" interface
    }
  ' | /usr/bin/sort -u | /usr/bin/cksum \
    | /usr/bin/awk '{ print $1 ":" $2 }')
  /usr/bin/printf 'endpoint=%s;core=%s;listener=%s;coreListeners=%s;routes=%s\n' \
    "$MIXED" "$cores" "$listeners" "$listener_signature" "$route_signature"
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
  fingerprint)
    local_fingerprint
    ;;
  *)
    echo "用法: $0 {discover|probe|health|fingerprint}"
    exit 2
    ;;
esac
