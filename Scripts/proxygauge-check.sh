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

EXPECT_IP="${PROXYGAUGE_EXPECT_IP:-}"
RAW_MIXED="${PROXYGAUGE_MIXED:-127.0.0.1:7890}"
MIXED=$(normalize_local_endpoint "$RAW_MIXED" 2>/dev/null || true)
MIXED_CONFIG_INVALID=""
if [ -z "$MIXED" ]; then
  MIXED="127.0.0.1:9"
  MIXED_CONFIG_INVALID=1
fi
TIMEOUT="${PROXYGAUGE_TIMEOUT:-6}"
TIMEOUT_CONFIG_INVALID=""
case "$TIMEOUT" in
  ''|*[!0-9]*) TIMEOUT=6; TIMEOUT_CONFIG_INVALID=1 ;;
  *)
    if [ "$TIMEOUT" -lt 1 ] || [ "$TIMEOUT" -gt 30 ]; then
      TIMEOUT=6
      TIMEOUT_CONFIG_INVALID=1
    fi
    ;;
esac
MIHOMO_SOCKET="${PROXYGAUGE_MIHOMO_SOCKET:-/private/tmp/verge/verge-mihomo.sock}"
SECONDARY_ENABLED="${PROXYGAUGE_SECONDARY_ENABLED:-auto}"
SECONDARY_LABEL="${PROXYGAUGE_SECONDARY_LABEL:-Google / Gemini / Claude}"
GOOGLE_GROUP="${PROXYGAUGE_SECONDARY_GROUP:-${PROXYGAUGE_GOOGLE_GROUP:-Google-Chain}}"
DEFAULT_GROUP="${PROXYGAUGE_DEFAULT_GROUP:-PROXY}"
RAW_GOOGLE_MIXED="${PROXYGAUGE_SECONDARY_MIXED:-${PROXYGAUGE_GOOGLE_MIXED:-127.0.0.1:7891}}"
GOOGLE_MIXED=$(normalize_local_endpoint "$RAW_GOOGLE_MIXED" 2>/dev/null || true)
GOOGLE_MIXED_CONFIG_INVALID=""
if [ -z "$GOOGLE_MIXED" ]; then
  GOOGLE_MIXED="127.0.0.1:9"
  GOOGLE_MIXED_CONFIG_INVALID=1
fi
EXPECT_GOOGLE_IP="${PROXYGAUGE_EXPECT_SECONDARY_IP:-${PROXYGAUGE_EXPECT_GOOGLE_IP:-}}"
SECONDARY_DOMAINS="${PROXYGAUGE_SECONDARY_DOMAINS:-gemini.google.com,generativelanguage.googleapis.com,www.google.com,claude.ai,api.anthropic.com,platform.claude.com,bridge.claudeusercontent.com}"
ACTIVE_AI_PROBES="${PROXYGAUGE_ACTIVE_AI_PROBES:-0}"
MIXED_HOST="${MIXED%:*}"
MIXED_PORT="${MIXED##*:}"
GOOGLE_MIXED_HOST="${GOOGLE_MIXED%:*}"
GOOGLE_MIXED_PORT="${GOOGLE_MIXED##*:}"
MIXED_HOST="${MIXED_HOST#[}"
MIXED_HOST="${MIXED_HOST%]}"
GOOGLE_MIXED_HOST="${GOOGLE_MIXED_HOST#[}"
GOOGLE_MIXED_HOST="${GOOGLE_MIXED_HOST%]}"
if [[ "$MIXED_HOST" == *:* ]]; then
  MIXED_PROXY_ENDPOINT="[$MIXED_HOST]:$MIXED_PORT"
else
  MIXED_PROXY_ENDPOINT="$MIXED_HOST:$MIXED_PORT"
fi
if [[ "$GOOGLE_MIXED_HOST" == *:* ]]; then
  GOOGLE_PROXY_ENDPOINT="[$GOOGLE_MIXED_HOST]:$GOOGLE_MIXED_PORT"
else
  GOOGLE_PROXY_ENDPOINT="$GOOGLE_MIXED_HOST:$GOOGLE_MIXED_PORT"
fi
SCRIPT_DIR=$(/usr/bin/dirname "$0")
CHAIN_PARSER="${PROXYGAUGE_CHAIN_PARSER:-$SCRIPT_DIR/proxygauge-chain-check.jxa}"
CURL="${PROXYGAUGE_CURL:-/usr/bin/curl}"
DSCACHEUTIL="${PROXYGAUGE_DSCACHEUTIL:-/usr/bin/dscacheutil}"
TEMP_ROOT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/proxygauge-health.XXXXXX")
cleanup_temp() {
  /bin/rm -rf "$TEMP_ROOT"
}
trap cleanup_temp EXIT
trap 'exit 130' HUP INT TERM

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

local_port_open() {
  local host port
  host="$1"
  port="$2"
  case "${PROXYGAUGE_DISCOVERY_PORT_ACTIVE:-}" in
    1|true|yes) return 0 ;;
    0|false|no) return 1 ;;
  esac
  (exec 3<>/dev/tcp/"$host"/"$port") 2>/dev/null
}

listener_owned_by_mihomo() {
  local host port family selector records owner_pids core_pid owner_pid
  host="$1"
  port="$2"
  host="${host#[}"
  host="${host%]}"
  case "${PROXYGAUGE_DISCOVERY_PORT_OWNER:-}" in
    mihomo) return 0 ;;
    other|unknown) return 1 ;;
  esac
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
  owner_pids=$(/usr/bin/printf '%s\n' "$records" \
    | /usr/bin/perl -e '
        use strict;
        use warnings;
        my ($target, $port, $family) = @ARGV;
        my $pid = q{};
        my %seen;
        while (<STDIN>) {
          chomp;
          if (/^p([0-9]+)$/) { $pid = $1; next; }
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
    | /usr/bin/awk 'NF && !seen[$0]++') || return 1
  [ -n "$owner_pids" ] || return 1
  while IFS= read -r core_pid; do
    case "$core_pid" in ''|*[!0-9]*) continue ;; esac
    while IFS= read -r owner_pid; do
      [ "$core_pid" = "$owner_pid" ] && return 0
    done <<< "$owner_pids"
  done <<< "$CORE_PIDS"
  return 1
}

encode_path_segment() {
  /usr/bin/perl -e '
    use strict;
    use warnings;
    my $value = shift // exit 1;
    for my $byte (unpack(q{C*}, $value)) {
      if (($byte >= 0x41 && $byte <= 0x5a) || ($byte >= 0x61 && $byte <= 0x7a) ||
          ($byte >= 0x30 && $byte <= 0x39) || $byte == 0x2d || $byte == 0x2e ||
          $byte == 0x5f || $byte == 0x7e) {
        print chr($byte);
      } else {
        printf q{%%%02X}, $byte;
      }
    }
  ' -- "$1"
}

run_with_timeout() {
  local seconds
  seconds="$1"
  shift
  /usr/bin/perl -e '
    use strict;
    use warnings;
    my $seconds = shift // exit 125;
    alarm($seconds);
    exec @ARGV;
    exit 127;
  ' -- "$seconds" "$@"
}

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

proxy_state_bypasses_exit_lookup() {
  /usr/bin/perl -e '
    use strict;
    use warnings;
    sub wildcard_matches {
      my ($pattern, $host) = @_;
      return 1 if $pattern =~ /^\./ && substr($pattern, 1) eq $host;
      my $regex = quotemeta($pattern);
      $regex =~ s/\\\*/.*/g;
      return $host =~ /\A$regex\z/i;
    }
    my @target = qw(ipapi.co api.ipify.org ifconfig.me ip.sb);
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

normalize_ip() {
  /usr/bin/perl -MSocket=AF_INET,AF_INET6,inet_pton,inet_ntop -e '
    use strict;
    use warnings;
    sub public_v4 {
      my @byte = unpack("C4", $_[0]);
      return 0 unless @byte == 4;
      return 0 if $byte[0] == 0 || $byte[0] == 10 || $byte[0] == 127 || $byte[0] >= 224;
      return 0 if $byte[0] == 100 && $byte[1] >= 64 && $byte[1] <= 127;
      return 0 if $byte[0] == 169 && $byte[1] == 254;
      return 0 if $byte[0] == 172 && $byte[1] >= 16 && $byte[1] <= 31;
      return 0 if $byte[0] == 192 && $byte[1] == 0 && ($byte[2] == 0 || $byte[2] == 2);
      return 0 if $byte[0] == 192 && $byte[1] == 31 && $byte[2] == 196;
      return 0 if $byte[0] == 192 && $byte[1] == 52 && $byte[2] == 193;
      return 0 if $byte[0] == 192 && $byte[1] == 88 && $byte[2] == 99;
      return 0 if $byte[0] == 192 && $byte[1] == 168;
      return 0 if $byte[0] == 192 && $byte[1] == 175 && $byte[2] == 48;
      return 0 if $byte[0] == 198 && ($byte[1] == 18 || $byte[1] == 19);
      return 0 if $byte[0] == 198 && $byte[1] == 51 && $byte[2] == 100;
      return 0 if $byte[0] == 203 && $byte[1] == 0 && $byte[2] == 113;
      return 1;
    }
    sub public_v6 {
      my @byte = unpack("C16", $_[0]);
      return 0 unless @byte == 16 && ($byte[0] & 0xe0) == 0x20;
      return 0 if $byte[0] == 0x20 && $byte[1] == 0x01 &&
        $byte[2] == 0x0d && $byte[3] == 0xb8;
      return 0 if $byte[0] == 0x20 && $byte[1] == 0x01 && $byte[2] < 0x02;
      return 0 if $byte[0] == 0x20 && $byte[1] == 0x02;
      return 0 if $byte[0] == 0x26 && $byte[1] == 0x20 && $byte[2] == 0x00 &&
        $byte[3] == 0x4f && $byte[4] == 0x80 && $byte[5] == 0x00;
      return 0 if $byte[0] == 0x3f && $byte[1] == 0xff && ($byte[2] & 0xf0) == 0;
      return 1;
    }
    my $value = shift // exit 1;
    exit 1 if $value eq q{} || $value =~ /[\s\x00%]/;
    if (index($value, q{.}) >= 0) {
      my $v4_tail = $value;
      $v4_tail =~ s/.*://;
      my @octet = split(/\./, $v4_tail, -1);
      exit 1 unless @octet == 4;
      for my $octet (@octet) {
        exit 1 unless $octet =~ /\A(?:0|[1-9][0-9]{0,2})\z/ && $octet <= 255;
      }
    }
    for my $family (AF_INET, AF_INET6) {
      my $packed = inet_pton($family, $value);
      next unless defined $packed;
      if ($family == AF_INET6 &&
          substr($packed, 0, 12) eq (("\x00" x 10) . "\xff\xff")) {
        my $mapped = substr($packed, 12, 4);
        exit 1 unless public_v4($mapped);
        print inet_ntop(AF_INET, $mapped);
      } else {
        exit 1 unless $family == AF_INET ? public_v4($packed) : public_v6($packed);
        print inet_ntop($family, $packed);
      }
      exit 0;
    }
    exit 1;
  ' -- "$1"
}

select_consensus_ip() {
  /usr/bin/awk '
    NF { count[$0]++ }
    END {
      maximum = 0
      winners = 0
      winner = ""
      for (address in count) {
        if (count[address] > maximum) {
          maximum = count[address]
          winner = address
          winners = 1
        } else if (count[address] == maximum) {
          winners++
        }
      }
      if (maximum >= 2 && winners == 1) print winner
    }
  '
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
        if ($column ~ /^utun[0-9]+$/) { interface = $column; break }
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
        if ($column ~ /^utun[0-9]+$/) { interface = $column; break }
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
  local json enabled device
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
      [ -S "$MIHOMO_SOCKET" ] || return 1
      json=$("$CURL" --disable --proxy "" -fsS --connect-timeout "$TIMEOUT" \
        --max-filesize 65536 --max-time "$TIMEOUT" --unix-socket "$MIHOMO_SOCKET" \
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

check_site() {
  name="$1"
  url="$2"
  kind="$3"
  probe_proxy="$4"
  headers=$(/usr/bin/mktemp "$TEMP_ROOT/site-headers.XXXXXX")
  body=$(/usr/bin/mktemp "$TEMP_ROOT/site-body.XXXXXX")
  out=$("$CURL" --disable --noproxy "" -sS -D "$headers" -o "$body" -w '%{http_code} %{time_total}' \
    --retry 1 --retry-all-errors --retry-delay 1 \
    --proxy "http://$probe_proxy" --max-filesize 1048576 --max-time "$TIMEOUT" "$url" 2>/dev/null)
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

if [ -n "${PROXYGAUGE_SYSTEM_PROXY_STATE+x}" ]; then
  RAW_SYSTEM_PROXY_STATE="$PROXYGAUGE_SYSTEM_PROXY_STATE"
else
  RAW_SYSTEM_PROXY_STATE=$(/usr/sbin/scutil --proxy 2>/dev/null || true)
fi
SYSTEM_PROXY_STATE=$(/usr/bin/printf '%s\n' "$RAW_SYSTEM_PROXY_STATE" \
  | top_level_system_proxy_state)
TUN_KIND=$(classify_tunnel_route)
PURE_TUN_ONLY=""
if [ "$TUN_KIND" = mihomo ] && ! /usr/bin/printf '%s\n' "$SYSTEM_PROXY_STATE" \
  | /usr/bin/grep -qE '(HTTP|HTTPS|SOCKS)Enable : 1|ProxyAuto(Config|Discovery)Enable : 1'; then
  PURE_TUN_ONLY=1
fi

echo "检查时间: $(date '+%F %T')"
if [ -n "$SECONDARY_ACTIVE" ]; then
  echo "检测方案: 通用检测 + $SECONDARY_LABEL"
  echo "额外分流: 1"
else
  echo "检测方案: 通用检测"
  echo "额外分流: 0"
fi

echo "===== 1. 代理核心进程 ====="
CORE_PIDS=$(core_pids)
CORE_COUNT=$(printf '%s\n' "$CORE_PIDS" | /usr/bin/awk 'NF {count++} END {print count+0}')
if [ "$CORE_COUNT" -eq 1 ]; then
  CORE_PID=$(printf '%s\n' "$CORE_PIDS" | /usr/bin/head -1)
  check ok "Mihomo 核心运行中 (PID $CORE_PID)"
elif [ "$CORE_COUNT" -gt 1 ]; then
  echo "$CORE_PIDS" | while IFS= read -r pid; do
    [ -n "$pid" ] && /bin/ps -p "$pid" -o '  user=,pid=,command=' 2>/dev/null
  done
  check no "发现 $CORE_COUNT 个 Mihomo 核心 — 可能是双核心分裂"
else
  check no "未发现 Mihomo 核心 — helper 进程不会被误判为核心"
fi

echo "===== 2. mixed 端口监听 ($MIXED) ====="
MIXED_LISTENER_CONFIRMED=""
if [ -n "$MIXED_CONFIG_INVALID" ]; then
  if [ -n "$PURE_TUN_ONLY" ]; then
    check warn "默认 mixed 入口配置无效，但当前已确认的是 TUN 系统路径 ($RAW_MIXED)"
  else
    check no "默认 mixed 入口配置无效或不是本机回环地址 ($RAW_MIXED)"
  fi
elif local_port_open "$MIXED_HOST" "$MIXED_PORT"; then
  if listener_owned_by_mihomo "$MIXED_HOST" "$MIXED_PORT"; then
    check ok "$MIXED 监听中，且属于已检测的 Mihomo 核心"
    MIXED_LISTENER_CONFIRMED=1
  else
    check warn "$MIXED 可以连接，但监听器不属于已检测的 Mihomo 核心"
  fi
else
  if [ -n "$PURE_TUN_ONLY" ]; then
    echo "  ℹ️ $MIXED 未监听；当前 TUN 系统路径不依赖 mixed 入口"
  else
    check no "$MIXED 未监听 — 核心未启动或端口已改"
  fi
fi
if [ -n "$TIMEOUT_CONFIG_INVALID" ]; then
  check no "超时配置必须是 1–30 秒的整数；本次使用安全默认值 6 秒"
fi

echo "===== 3. 代理入口 (系统代理 / TUN, 至少一个) ====="
MODE_OK=""
SYSTEM_ACTIVE=""
TUN_ACTIVE=""
OTHER_TUN_ACTIVE=""
MIHOMO_TUN_UNCONFIRMED=""
SPLIT_TUN_ACTIVE=""
UNKNOWN_TUN_ACTIVE=""
SYSTEM_DYNAMIC=""
SYSTEM_MISMATCH=""
if /usr/bin/printf '%s\n' "$SYSTEM_PROXY_STATE" \
  | /usr/bin/grep -qE '(HTTP|HTTPS|SOCKS)Enable : 1|ProxyAuto(Config|Discovery)Enable : 1'; then
  MODE_OK=1
  SYSTEM_ACTIVE=1
  if /usr/bin/printf '%s\n' "$SYSTEM_PROXY_STATE" \
    | /usr/bin/grep -qE 'ProxyAuto(Config|Discovery)Enable : 1'; then
    echo "  ℹ️ 系统代理: PAC / 自动发现已启用（路径按目标决定）"
    SYSTEM_DYNAMIC=1
  elif ! /usr/bin/printf '%s\n' "$SYSTEM_PROXY_STATE" \
    | /usr/bin/grep -qE '(HTTPS|SOCKS)Enable : 1'; then
    echo "  ℹ️ 系统代理: 仅 HTTP 已启用，HTTPS 路径未接管"
    SYSTEM_MISMATCH=1
  elif /usr/bin/printf '%s\n' "$SYSTEM_PROXY_STATE" | proxy_state_bypasses_exit_lookup; then
    echo "  ℹ️ 系统代理: 出口查询域名命中绕过列表"
    SYSTEM_MISMATCH=1
  else
    SYSTEM_ENDPOINT=$(/usr/bin/printf '%s\n' "$SYSTEM_PROXY_STATE" | /usr/bin/awk '
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
        if (https_enabled && https_host != "" && https_port ~ /^[0-9]+$/) print endpoint(https_host, https_port)
        else if (socks_enabled && socks_host != "" && socks_port ~ /^[0-9]+$/) print endpoint(socks_host, socks_port)
      }
    ')
    NORMALIZED_SYSTEM_ENDPOINT=$(normalize_local_endpoint "$SYSTEM_ENDPOINT" 2>/dev/null || true)
    if [ -z "$NORMALIZED_SYSTEM_ENDPOINT" ] || [ "$NORMALIZED_SYSTEM_ENDPOINT" != "$MIXED" ]; then
      echo "  ℹ️ 系统代理: 已启用，但 HTTPS 路径未明确指向当前检测入口"
      SYSTEM_MISMATCH=1
    else
      echo "  ℹ️ 系统代理: 已启用并指向当前检测入口"
    fi
  fi
else
  echo "  ℹ️ 系统代理: 未启用"
fi
if [ "$TUN_KIND" = mihomo ]; then
  echo "  ℹ️ TUN: 代表性 IPv4 / IPv6 路由已确认"
  MODE_OK=1
  TUN_ACTIVE=1
elif [ "$TUN_KIND" = mihomo-unconfirmed ]; then
  echo "  ℹ️ Mihomo TUN: 配置已启用，但活动路由无法匹配具体 utun 设备"
  MODE_OK=1
  MIHOMO_TUN_UNCONFIRMED=1
elif [ "$TUN_KIND" = split ]; then
  echo "  ℹ️ Mihomo TUN: 代表性公网目标走不同接口"
  MODE_OK=1
  SPLIT_TUN_ACTIVE=1
elif [ "$TUN_KIND" = unknown ]; then
  echo "  ℹ️ Mihomo TUN: 本地路由查询失败，未判定为已接管"
  MODE_OK=1
  UNKNOWN_TUN_ACTIVE=1
elif [ "$TUN_KIND" = other ]; then
  echo "  ℹ️ 其他 VPN / TUN: 检测到隧道路由，但不能归因于 Mihomo"
  MODE_OK=1
  OTHER_TUN_ACTIVE=1
else
  echo "  ℹ️ TUN: 未检测到有效隧道路由"
fi
if [ -n "$SYSTEM_ACTIVE" ] \
  && [ -n "$TUN_ACTIVE$MIHOMO_TUN_UNCONFIRMED$SPLIT_TUN_ACTIVE$UNKNOWN_TUN_ACTIVE$OTHER_TUN_ACTIVE" ]; then
  check warn "系统代理与 TUN 同时开启 — 通常只需保留一个流量入口"
elif [ -n "$SYSTEM_DYNAMIC" ]; then
  check warn "PAC / 自动代理会按目标地址选择路径 — 请以系统实际出口为准"
elif [ -n "$SYSTEM_MISMATCH" ]; then
  check warn "系统代理与当前检测入口不一致 — 请核对正在使用的客户端"
elif [ -n "$OTHER_TUN_ACTIVE" ]; then
  check warn "检测到其他 VPN / TUN；请以系统实际出口确认当前路径"
elif [ -n "$MIHOMO_TUN_UNCONFIRMED" ]; then
  check warn "Mihomo TUN 已启用，但路由归属仍需确认；请以系统实际出口为准"
elif [ -n "$SPLIT_TUN_ACTIVE" ]; then
  check warn "代表性公网目标走不同接口，可能存在同族或 IPv4 / IPv6 分流"
elif [ -n "$UNKNOWN_TUN_ACTIVE" ]; then
  check warn "无法可靠读取代表性公网路由，未把 TUN 判定为已接管"
elif [ -n "$MODE_OK" ]; then
  check ok "代理入口已生效"
else
  check no "系统代理与 TUN 都未开启 — 普通流量不会进入代理"
fi

if [ -n "$TUN_ACTIVE" ]; then
  DNS_IP=$(run_with_timeout "$TIMEOUT" "$DSCACHEUTIL" -q host -a name www.cloudflare.com 2>/dev/null \
    | /usr/bin/awk '/ip_address:/ {print $2; exit}')
  if echo "$DNS_IP" | /usr/bin/grep -qE '^198\.18\.'; then
    check ok "TUN DNS 返回 Fake-IP ($DNS_IP)，域名分流可用"
  elif [ -z "$DNS_IP" ]; then
    check no "TUN 代表性路由已确认，但系统 DNS 无法解析域名 — 请检查 dns-hijack 与 dns 配置"
  else
    check warn "TUN 代表性路由已确认，但 DNS 返回真实地址 ($DNS_IP)，DOMAIN 规则可能无法按预期命中"
  fi
fi

if [ -n "$PURE_TUN_ONLY" ] && [ -z "$MIXED_LISTENER_CONFIRMED" ]; then
  echo "===== 4. 出口 IP (TUN 系统路径) ====="
  EXIT_VIA_SYSTEM_PATH=1
else
  echo "===== 4. 出口 IP (mixed 入口) ====="
  EXIT_VIA_SYSTEM_PATH=""
fi
EXT=""
EXIT_VALUES=""
EXIT_RESPONSES=0
while IFS='|' read -r service api; do
  if [ -n "$EXIT_VIA_SYSTEM_PATH" ]; then
    value=$("$CURL" --disable --proxy "" -s --retry 1 --retry-all-errors --retry-delay 1 \
      --max-filesize 256 --max-time "$TIMEOUT" "$api" 2>/dev/null)
  else
    value=$("$CURL" --disable --noproxy "" -s --retry 1 --retry-all-errors --retry-delay 1 \
      --proxy "http://$MIXED_PROXY_ENDPOINT" --max-filesize 256 --max-time "$TIMEOUT" "$api" 2>/dev/null)
  fi
  normalized_value=$(normalize_ip "$value" 2>/dev/null || true)
  if [ -n "$normalized_value" ]; then
    EXIT_VALUES="${EXIT_VALUES}${normalized_value}"$'\n'
    EXIT_RESPONSES=$((EXIT_RESPONSES+1))
    echo "  ℹ️ $service: $normalized_value"
  else
    echo "  ℹ️ $service: 未响应"
  fi
done <<'EOF'
ipify|https://api.ipify.org
ifconfig.me|https://ifconfig.me/ip
ip.sb|https://ip.sb/ip
EOF

EXT=$(printf '%s' "$EXIT_VALUES" | select_consensus_ip)
if [ -n "$EXT" ]; then
  UNIQUE_EXITS=$(printf '%s' "$EXIT_VALUES" | /usr/bin/awk 'NF' | /usr/bin/sort -u | /usr/bin/wc -l | /usr/bin/tr -d ' ')
  if [ "$UNIQUE_EXITS" -gt 1 ]; then
    check warn "多数查询源确认出口 ${EXT}，但仍有来源不一致"
  else
    check ok "$EXIT_RESPONSES 个查询源确认出口一致 ($EXT)"
  fi

  NORMALIZED_EXPECT_IP=$(normalize_ip "$EXPECT_IP" 2>/dev/null || true)
  if [ -z "$EXPECT_IP" ]; then
    echo "  ℹ️ 未配置期望出口 IP；如使用固定节点，建议在设置中保存基线"
  elif [ -z "$NORMALIZED_EXPECT_IP" ]; then
    check no "配置的期望出口 IP 无效 ($EXPECT_IP)"
  elif [ "$EXT" = "$NORMALIZED_EXPECT_IP" ]; then
    check ok "出口符合配置 ($NORMALIZED_EXPECT_IP)"
  else
    check no "出口非预期 ($EXT != $NORMALIZED_EXPECT_IP)，请检查节点配置"
  fi
elif [ "$EXIT_RESPONSES" -eq 0 ]; then
  check no "无法经代理获取出口 IP (多个查询源均失败)"
elif [ "$EXIT_RESPONSES" -eq 1 ]; then
  check warn "只收到 1 个有效公网出口响应，不采用单源结果"
else
  check warn "出口查询无多数一致结果，不选择任意地址"
fi
if [ -z "$EXT" ] && [ -n "$EXPECT_IP" ]; then
  NORMALIZED_EXPECT_IP=$(normalize_ip "$EXPECT_IP" 2>/dev/null || true)
  if [ -z "$NORMALIZED_EXPECT_IP" ]; then
    check no "配置的期望出口 IP 无效 ($EXPECT_IP)"
  else
    check warn "当前没有多数一致出口，无法与期望 IP $NORMALIZED_EXPECT_IP 比较"
  fi
fi

run_secondary_checks() {
echo "===== 5. 额外分流链路 ($SECONDARY_LABEL) ====="
GOOGLE_EXT=""
CHAIN_CONFIGURED=""
if [ -S "$MIHOMO_SOCKET" ] && [ -r "$CHAIN_PARSER" ]; then
  PROXIES_JSON=$(/usr/bin/mktemp "$TEMP_ROOT/proxies.XXXXXX")
  RULES_JSON=$(/usr/bin/mktemp "$TEMP_ROOT/rules.XXXXXX")
  DELAY_JSON=$(/usr/bin/mktemp "$TEMP_ROOT/chain-delay.XXXXXX")
  : > "$PROXIES_JSON"
  : > "$RULES_JSON"
  : > "$DELAY_JSON"

  "$CURL" --disable --proxy "" -sS --connect-timeout "$TIMEOUT" --max-filesize 4194304 --max-time "$TIMEOUT" \
    --unix-socket "$MIHOMO_SOCKET" \
    http://localhost/proxies -o "$PROXIES_JSON" 2>/dev/null || true
  "$CURL" --disable --proxy "" -sS --connect-timeout "$TIMEOUT" --max-filesize 4194304 --max-time "$TIMEOUT" \
    --unix-socket "$MIHOMO_SOCKET" \
    http://localhost/rules -o "$RULES_JSON" 2>/dev/null || true
  ENCODED_GOOGLE_GROUP=$(encode_path_segment "$GOOGLE_GROUP")
  "$CURL" --disable --proxy "" -sS --connect-timeout "$TIMEOUT" --max-filesize 65536 --max-time "$TIMEOUT" \
    --unix-socket "$MIHOMO_SOCKET" --get \
    --data-urlencode 'url=https://cp.cloudflare.com/generate_204' \
    --data-urlencode "timeout=$((TIMEOUT * 1000))" \
    "http://localhost/proxies/$ENCODED_GOOGLE_GROUP/delay" \
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

if [ -n "$GOOGLE_MIXED_CONFIG_INVALID" ]; then
  check no "$SECONDARY_LABEL mixed 入口配置无效或不是本机回环地址 ($RAW_GOOGLE_MIXED)"
elif [ "$GOOGLE_MIXED" = "$MIXED" ]; then
  check no "$SECONDARY_LABEL 入口与默认 mixed 端口相同，无法区分两个出口"
elif local_port_open "$GOOGLE_MIXED_HOST" "$GOOGLE_MIXED_PORT"; then
  if ! listener_owned_by_mihomo "$GOOGLE_MIXED_HOST" "$GOOGLE_MIXED_PORT"; then
    check warn "$SECONDARY_LABEL mixed 入口可以连接，但监听器未归属于 Mihomo ($GOOGLE_MIXED)"
  else
    CHAIN_CONFIGURED=1
    GOOGLE_EXT=""
    GOOGLE_EXIT_VALUES=""
    GOOGLE_EXIT_RESPONSES=0
    while IFS='|' read -r service api; do
    value=$("$CURL" --disable --noproxy "" -s --retry 1 --retry-all-errors --retry-delay 1 \
      --proxy "http://$GOOGLE_PROXY_ENDPOINT" --max-filesize 256 --max-time "$TIMEOUT" "$api" 2>/dev/null)
    normalized_value=$(normalize_ip "$value" 2>/dev/null || true)
    if [ -n "$normalized_value" ]; then
      GOOGLE_EXIT_VALUES="${GOOGLE_EXIT_VALUES}${normalized_value}"$'\n'
      GOOGLE_EXIT_RESPONSES=$((GOOGLE_EXIT_RESPONSES+1))
      echo "  ℹ️ ${service}（${SECONDARY_LABEL}）: $normalized_value"
    else
      echo "  ℹ️ ${service}（${SECONDARY_LABEL}）: 未响应"
    fi
  done <<'EOF'
ipify|https://api.ipify.org
ifconfig.me|https://ifconfig.me/ip
ip.sb|https://ip.sb/ip
EOF

  GOOGLE_EXT=$(printf '%s' "$GOOGLE_EXIT_VALUES" | select_consensus_ip)
  if [ -n "$GOOGLE_EXT" ]; then
    GOOGLE_UNIQUE_EXITS=$(printf '%s' "$GOOGLE_EXIT_VALUES" | /usr/bin/awk 'NF' | /usr/bin/sort -u | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    if [ "$GOOGLE_UNIQUE_EXITS" -gt 1 ]; then
      check warn "多数查询源确认 ${SECONDARY_LABEL} 出口 ${GOOGLE_EXT}，但仍有来源不一致"
    else
      check ok "$GOOGLE_EXIT_RESPONSES 个查询源确认 $SECONDARY_LABEL 出口一致 ($GOOGLE_EXT)"
    fi

    NORMALIZED_EXPECT_GOOGLE_IP=$(normalize_ip "$EXPECT_GOOGLE_IP" 2>/dev/null || true)
    if [ -n "$EXPECT_GOOGLE_IP" ] && [ -z "$NORMALIZED_EXPECT_GOOGLE_IP" ]; then
      check no "$SECONDARY_LABEL 配置的期望出口 IP 无效 ($EXPECT_GOOGLE_IP)"
    elif [ -n "$EXPECT_GOOGLE_IP" ] && [ "$GOOGLE_EXT" != "$NORMALIZED_EXPECT_GOOGLE_IP" ]; then
      check no "$SECONDARY_LABEL 出口非预期 ($GOOGLE_EXT != $NORMALIZED_EXPECT_GOOGLE_IP)"
    elif [ -n "$NORMALIZED_EXPECT_GOOGLE_IP" ]; then
      check ok "$SECONDARY_LABEL 出口符合配置 ($NORMALIZED_EXPECT_GOOGLE_IP)"
    fi

    if [ -n "$EXT" ] && [ "$GOOGLE_EXT" = "$EXT" ]; then
      check warn "$SECONDARY_LABEL 出口与默认出口相同 ($GOOGLE_EXT) — 请确认策略选择"
    elif [ -n "$EXT" ]; then
      check ok "出口已分离：默认 $EXT / $SECONDARY_LABEL $GOOGLE_EXT"
    fi

  else
    if [ "$GOOGLE_EXIT_RESPONSES" -eq 0 ]; then
      check no "无法通过 $GOOGLE_MIXED 获取 $SECONDARY_LABEL 出口 IP"
    elif [ "$GOOGLE_EXIT_RESPONSES" -eq 1 ]; then
      check warn "$SECONDARY_LABEL 只收到 1 个有效公网出口响应，不采用单源结果"
    else
      check warn "$SECONDARY_LABEL 出口查询无多数一致结果，不选择任意地址"
    fi
    if [ -n "$EXPECT_GOOGLE_IP" ]; then
      NORMALIZED_EXPECT_GOOGLE_IP=$(normalize_ip "$EXPECT_GOOGLE_IP" 2>/dev/null || true)
      if [ -z "$NORMALIZED_EXPECT_GOOGLE_IP" ]; then
        check no "$SECONDARY_LABEL 配置的期望出口 IP 无效 ($EXPECT_GOOGLE_IP)"
      else
        check warn "$SECONDARY_LABEL 当前没有多数一致出口，无法与期望 IP $NORMALIZED_EXPECT_GOOGLE_IP 比较"
      fi
    fi
    fi
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
  check_site "OpenAI API" "https://api.openai.com/v1/models" "api" "$MIXED_PROXY_ENDPOINT"
  check_site "Anthropic API" "https://api.anthropic.com/v1/models" "api" "$MIXED_PROXY_ENDPOINT"
  GEMINI_PROBE_PROXY="$MIXED_PROXY_ENDPOINT"
  if [ -n "$SECONDARY_ACTIVE" ]; then
    GEMINI_PROBE_PROXY="$GOOGLE_PROXY_ENDPOINT"
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
  check_site "OpenAI API" "https://api.openai.com/v1/models" "api" "$MIXED_PROXY_ENDPOINT"
  check_site "Anthropic API" "https://api.anthropic.com/v1/models" "api" "$MIXED_PROXY_ENDPOINT"
  check_site "Gemini API" "https://generativelanguage.googleapis.com/v1beta/models" "gemini" "$MIXED_PROXY_ENDPOINT"
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
