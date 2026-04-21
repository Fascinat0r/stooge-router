#!/bin/sh
set -eu

TAG="singbox-updater-installer"

URL="${1:-}"
SCHEDULE="${SCHEDULE:-0 4 * * *}"
RUN_ON_BOOT="${RUN_ON_BOOT:-1}"
RUN_ON_WAN_UP="${RUN_ON_WAN_UP:-1}"
RETRIES="${RETRIES:-8}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-10}"
MAX_TIME="${MAX_TIME:-30}"
BACKUP_KEEP="${BACKUP_KEEP:-7}"
APPLY_NOW="${APPLY_NOW:-1}"
SHA256="${SHA256:-}"
INSECURE_TLS="${INSECURE_TLS:-1}"
RESOLVE_HOST="${RESOLVE_HOST:-}"
RESOLVE_IP="${RESOLVE_IP:-}"

TELEGRAM_IP_LIST_URL="${TELEGRAM_IP_LIST_URL:-}"
[ -n "$TELEGRAM_IP_LIST_URL" ] || TELEGRAM_IP_LIST_URL="${2:-}"
TELEGRAM_IP_LIST_PATH="${TELEGRAM_IP_LIST_PATH:-/etc/sing-box/telegram_ip_cidrs_v4.txt}"
TELEGRAM_IP_LIST_SHA256="${TELEGRAM_IP_LIST_SHA256:-}"
TELEGRAM_IPSET_NAME="${TELEGRAM_IPSET_NAME:-telegram_ips}"
TELEGRAM_RULE_NAME="${TELEGRAM_RULE_NAME:-mark_telegram_ips}"
TELEGRAM_MARK_VALUE="${TELEGRAM_MARK_VALUE:-0x1}"
TELEGRAM_FIREWALL_SETUP="${TELEGRAM_FIREWALL_SETUP:-1}"
TELEGRAM_FIREWALL_RESTART="${TELEGRAM_FIREWALL_RESTART:-1}"

say() {
	echo "[$TAG] $*"
	logger -t "$TAG" "$*" 2>/dev/null || true
}

die() {
	say "ERROR: $*"
	exit 1
}

have_cmd() {
	command -v "$1" >/dev/null 2>&1
}

trim_brackets() {
	value="$1"
	case "$value" in
		\[*\]) value="${value#\[}"; value="${value%\]}" ;;
	esac
	echo "$value"
}

url_scheme() {
	url="$1"
	case "$url" in
		*://*)
			echo "${url%%://*}"
			return 0
			;;
	esac
	return 1
}

url_authority() {
	url="$1"
	case "$url" in
		*://*)
			rest="${url#*://}"
			echo "${rest%%/*}"
			return 0
			;;
	esac
	return 1
}

url_host() {
	authority="$(url_authority "$1" 2>/dev/null || true)"
	[ -n "$authority" ] || return 1
	hostport="${authority##*@}"
	case "$hostport" in
		\[*\]:*)
			host="${hostport#\[}"
			host="${host%%]*}"
			echo "$host"
			return 0
			;;
		\[*\])
			host="${hostport#\[}"
			host="${host%\]}"
			echo "$host"
			return 0
			;;
		*:*)
			echo "${hostport%%:*}"
			return 0
			;;
		*)
			echo "$hostport"
			return 0
			;;
	esac
}

url_port() {
	url="$1"
	scheme="$(url_scheme "$url" 2>/dev/null || true)"
	authority="$(url_authority "$url" 2>/dev/null || true)"
	[ -n "$authority" ] || return 1
	hostport="${authority##*@}"
	case "$hostport" in
		\[*\]:*)
			echo "${hostport##*]:}"
			return 0
			;;
		\[*\])
			:
			;;
		*:*)
			echo "${hostport##*:}"
			return 0
			;;
	esac
	case "$scheme" in
		https) echo 443 ;;
		http) echo 80 ;;
		*) return 1 ;;
	esac
}

fetch_with_curl() {
	url="$1"
	out="$2"
	insecure_tls="$3"
	resolve_host="$4"
	resolve_ip="$5"

	set -- -fsSL

	if [ "$insecure_tls" = "1" ]; then
		say "using insecure TLS mode"
		set -- "$@" -k
	fi

	url_host_value="$(url_host "$url" 2>/dev/null || true)"
	url_scheme_value="$(url_scheme "$url" 2>/dev/null || true)"

	if [ -n "$resolve_host" ] && [ -n "$resolve_ip" ]; then
		if [ -n "$url_host_value" ] && [ "$url_host_value" = "$resolve_host" ]; then
			if [ "$url_scheme_value" = "https" ]; then
				resolve_port="$(url_port "$url" 2>/dev/null || echo 443)"
				resolve_ip_fmt="$(trim_brackets "$resolve_ip")"
				say "using curl --resolve for host $resolve_host:$resolve_port -> $resolve_ip_fmt"
				set -- "$@" --resolve "$resolve_host:$resolve_port:$resolve_ip_fmt"
			else
				say "URL scheme '$url_scheme_value' is not https; skipping --resolve"
			fi
		else
			say "URL host does not match resolve_host, skipping --resolve"
		fi
	else
		say "downloading without custom resolve"
	fi

	set -- "$@" --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" -o "$out" "$url"
	curl "$@" >/dev/null 2>&1
}

usage() {
	cat <<USG
Usage:
  sh /root/install-singbox-updater.sh 'https://example.com/config.json'
  sh /root/install-singbox-updater.sh 'https://example.com/config.json' 'https://example.com/telegram_ip_cidrs_v4.txt'

Optional env vars:
  SCHEDULE='0 4 * * *'
  RUN_ON_BOOT=1
  RUN_ON_WAN_UP=1
  RETRIES=8
  CONNECT_TIMEOUT=10
  MAX_TIME=30
  BACKUP_KEEP=7
  APPLY_NOW=1
  SHA256='...'
  INSECURE_TLS=1
  RESOLVE_HOST=''
  RESOLVE_IP=''

Telegram IPv4 list options:
  TELEGRAM_IP_LIST_URL=''       # URL with IPv4 CIDR list, one CIDR per line
  TELEGRAM_IP_LIST_PATH='/etc/sing-box/telegram_ip_cidrs_v4.txt'
  TELEGRAM_IP_LIST_SHA256=''    # optional SHA256 pinning for Telegram IP list
  TELEGRAM_IPSET_NAME='telegram_ips'
  TELEGRAM_RULE_NAME='mark_telegram_ips'
  TELEGRAM_MARK_VALUE='0x1'
  TELEGRAM_FIREWALL_SETUP=1
  TELEGRAM_FIREWALL_RESTART=1

Example:
  TELEGRAM_IP_LIST_URL='https://s3.example.com/path/telegram_ip_cidrs_v4.txt' \\
    sh /root/install-singbox-updater.sh 'https://s3.example.com/path/config.json'
USG
}

[ "$(id -u)" = "0" ] || die "Run as root"
[ -n "$URL" ] || { usage; exit 1; }

fetch_url() {
	url="$1"
	out="$2"

	case "$url" in
		/*)
			[ -f "$url" ] || return 1
			cat "$url" > "$out" || return 1
			return 0
			;;
	esac

	if have_cmd curl; then
		fetch_with_curl "$url" "$out" "$INSECURE_TLS" "$RESOLVE_HOST" "$RESOLVE_IP"
		return $?
	fi

	if have_cmd uclient-fetch; then
		[ -z "$RESOLVE_HOST" ] || [ -z "$RESOLVE_IP" ] || say "curl is unavailable; custom --resolve cannot be applied"
		[ "$INSECURE_TLS" = "1" ] && say "curl is unavailable; insecure TLS mode cannot be applied with uclient-fetch"
		say "downloading with uclient-fetch"
		uclient-fetch -q -O "$out" "$url" >/dev/null 2>&1
		return $?
	fi

	return 127
}

ensure_fetcher() {
	if have_cmd curl || have_cmd uclient-fetch; then
		return 0
	fi

	say "Neither curl nor uclient-fetch found, trying to install curl"
	opkg update >/dev/null 2>&1 || true
	opkg install curl ca-bundle >/dev/null 2>&1 || \
	opkg install curl ca-certificates >/dev/null 2>&1 || true

	have_cmd curl || have_cmd uclient-fetch || die "No fetcher available (curl/uclient-fetch)"
}

ensure_singbox() {
	if have_cmd sing-box || [ -x /etc/init.d/sing-box ] || [ -x /etc/init.d/singbox ] || [ -x /etc/init.d/sing-box-service ]; then
		return 0
	fi

	say "sing-box not found, trying opkg install sing-box"
	opkg update >/dev/null 2>&1 || true
	opkg install sing-box >/dev/null 2>&1 || true

	if have_cmd sing-box || [ -x /etc/init.d/sing-box ] || [ -x /etc/init.d/singbox ] || [ -x /etc/init.d/sing-box-service ]; then
		return 0
	fi

	die "sing-box not found and could not be installed automatically from opkg"
}

validate_json_basic() {
	f="$1"
	[ -s "$f" ] || return 1
	grep -q '^[[:space:]]*{' "$f" || return 1
	grep -q '}' "$f" || return 1
	return 0
}

validate_with_singbox_if_possible() {
	f="$1"
	if have_cmd sing-box; then
		sing-box check -h >/dev/null 2>&1 || return 0
		sing-box check -c "$f" >/dev/null 2>&1 || return 1
	fi
	return 0
}

normalize_ipv4_cidr_list() {
	in_file="$1"
	out_file="$2"

	awk '
	function trim(s) {
		gsub(/^[ \t]+/, "", s)
		gsub(/[ \t]+$/, "", s)
		return s
	}
	BEGIN {
		count = 0
		err = 0
	}
	{
		sub(/\r$/, "", $0)
		sub(/#.*/, "", $0)
		line = trim($0)
		if (line == "") {
			next
		}

		if (line !~ /^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\/[0-9][0-9]*$/) {
			print "invalid IPv4 CIDR line: " line > "/dev/stderr"
			err = 1
			exit
		}

		split(line, parts, "/")
		prefix = parts[2] + 0
		if (prefix < 0 || prefix > 32) {
			print "invalid IPv4 CIDR prefix: " line > "/dev/stderr"
			err = 1
			exit
		}

		split(parts[1], octets, ".")
		for (i = 1; i <= 4; i++) {
			if (octets[i] !~ /^[0-9][0-9]*$/ || octets[i] < 0 || octets[i] > 255) {
				print "invalid IPv4 octet: " line > "/dev/stderr"
				err = 1
				exit
			}
		}

		if (!seen[line]) {
			seen[line] = 1
			print line
			count++
		}
	}
	END {
		if (err) {
			exit 1
		}
		if (count == 0) {
			print "Telegram IPv4 CIDR list contains no usable entries" > "/dev/stderr"
			exit 1
		}
	}
	' "$in_file" > "$out_file"
}

ensure_cron_init() {
	if [ -x /etc/init.d/cron ]; then
		echo "/etc/init.d/cron"
		return 0
	fi
	if [ -x /etc/init.d/crond ]; then
		echo "/etc/init.d/crond"
		return 0
	fi
	return 1
}

ensure_telegram_ip_list_file() {
	path="$1"
	dir="$(dirname "$path")"

	mkdir -p "$dir" || die "Cannot create Telegram IP list directory: $dir"

	if [ ! -f "$path" ]; then
		say "Telegram IP list file does not exist yet, creating empty placeholder: $path"
		: > "$path" || die "Cannot create Telegram IP list file: $path"
		chmod 600 "$path" >/dev/null 2>&1 || true
		chown root:root "$path" >/dev/null 2>&1 || true
	fi
}

find_firewall_section_by_name() {
	type="$1"
	name="$2"

	uci -q show firewall 2>/dev/null | awk -F= -v type="$type" -v name="$name" '
		$1 ~ "^firewall\\.@" type "\\[[0-9]+\\]\\.name$" {
			v = $2
			gsub(/\047/, "", v)
			if (v == name) {
				sub(/^firewall\./, "", $1)
				sub(/\.name$/, "", $1)
				print $1
				exit
			}
		}
	'
}

ensure_telegram_firewall_config() {
	ipset_name="$1"
	rule_name="$2"
	list_path="$3"
	mark_value="$4"

	say "Ensuring firewall ipset '$ipset_name' uses loadfile: $list_path"

	ipset_section="$(find_firewall_section_by_name ipset "$ipset_name" || true)"
	if [ -n "$ipset_section" ]; then
		ipset_ref="$ipset_section"
		say "Found existing firewall ipset section: firewall.$ipset_ref"
	else
		ipset_ref="telegram_ips_auto"
		uci -q delete "firewall.$ipset_ref" >/dev/null 2>&1 || true
		uci set "firewall.$ipset_ref=ipset" || die "Failed to create firewall.$ipset_ref"
		say "Created firewall ipset section: firewall.$ipset_ref"
	fi

	uci set "firewall.$ipset_ref.name=$ipset_name" || die "Failed to set firewall.$ipset_ref.name"
	uci set "firewall.$ipset_ref.family=ipv4" || die "Failed to set firewall.$ipset_ref.family"
	uci -q delete "firewall.$ipset_ref.match" >/dev/null 2>&1 || true
	uci add_list "firewall.$ipset_ref.match=dest_net" || die "Failed to set firewall.$ipset_ref.match"
	uci set "firewall.$ipset_ref.loadfile=$list_path" || die "Failed to set firewall.$ipset_ref.loadfile"

	say "Ensuring firewall MARK rule '$rule_name' marks '$ipset_name' with $mark_value"

	rule_section="$(find_firewall_section_by_name rule "$rule_name" || true)"
	if [ -n "$rule_section" ]; then
		rule_ref="$rule_section"
		say "Found existing firewall rule section: firewall.$rule_ref"
	else
		rule_ref="telegram_ips_mark_auto"
		uci -q delete "firewall.$rule_ref" >/dev/null 2>&1 || true
		uci set "firewall.$rule_ref=rule" || die "Failed to create firewall.$rule_ref"
		say "Created firewall rule section: firewall.$rule_ref"
	fi

	uci set "firewall.$rule_ref.name=$rule_name" || die "Failed to set firewall.$rule_ref.name"
	uci set "firewall.$rule_ref.src=lan" || die "Failed to set firewall.$rule_ref.src"
	uci set "firewall.$rule_ref.dest=*" || die "Failed to set firewall.$rule_ref.dest"
	uci set "firewall.$rule_ref.proto=all" || die "Failed to set firewall.$rule_ref.proto"
	uci set "firewall.$rule_ref.ipset=$ipset_name" || die "Failed to set firewall.$rule_ref.ipset"
	uci set "firewall.$rule_ref.set_mark=$mark_value" || die "Failed to set firewall.$rule_ref.set_mark"
	uci set "firewall.$rule_ref.target=MARK" || die "Failed to set firewall.$rule_ref.target"
	uci set "firewall.$rule_ref.family=ipv4" || die "Failed to set firewall.$rule_ref.family"

	uci commit firewall || die "Failed to commit firewall config"
	say "Firewall Telegram ipset/rule config committed"
}

say "Checking sing-box presence"
ensure_singbox

say "Checking downloader presence"
ensure_fetcher

say "Checking config source availability"
TMP_CHECK="/tmp/.singbox-updater-installer-check.$$"
rm -f "$TMP_CHECK" >/dev/null 2>&1 || true
fetch_url "$URL" "$TMP_CHECK" || die "Cannot download config from: $URL"
[ -s "$TMP_CHECK" ] || die "Downloaded config is empty"
validate_json_basic "$TMP_CHECK" || die "Downloaded file doesn't look like valid JSON"
validate_with_singbox_if_possible "$TMP_CHECK" || die "Downloaded config failed sing-box validation"

if [ -n "$SHA256" ]; then
	if have_cmd sha256sum; then
		GOT_SHA256="$(sha256sum "$TMP_CHECK" | awk '{print $1}')"
		[ "$GOT_SHA256" = "$SHA256" ] || die "SHA256 mismatch (got $GOT_SHA256, want $SHA256)"
	else
		die "SHA256 specified but sha256sum is not available"
	fi
fi
rm -f "$TMP_CHECK" >/dev/null 2>&1 || true

if [ -n "$TELEGRAM_IP_LIST_URL" ]; then
	say "Checking Telegram IPv4 list source availability"
	TMP_TG_RAW="/tmp/.singbox-updater-installer-telegram-raw.$$"
	TMP_TG_NORM="/tmp/.singbox-updater-installer-telegram-normalized.$$"
	rm -f "$TMP_TG_RAW" "$TMP_TG_NORM" >/dev/null 2>&1 || true

	if fetch_url "$TELEGRAM_IP_LIST_URL" "$TMP_TG_RAW" && [ -s "$TMP_TG_RAW" ] && normalize_ipv4_cidr_list "$TMP_TG_RAW" "$TMP_TG_NORM"; then
		TG_COUNT="$(wc -l < "$TMP_TG_NORM" | tr -d ' ')"
		say "Telegram IPv4 list source check passed: $TG_COUNT CIDR entries"
	else
		say "WARNING: Telegram IPv4 list source check failed; installer will continue and runtime updater will keep existing list on failures"
	fi

	rm -f "$TMP_TG_RAW" "$TMP_TG_NORM" >/dev/null 2>&1 || true
else
	say "Telegram IPv4 list URL is not configured; Telegram ipset list update will be skipped"
fi

say "Writing /etc/config/singbox_updater"
mkdir -p /etc/config
[ -f /etc/config/singbox_updater ] || touch /etc/config/singbox_updater
say "UCI package file: /etc/config/singbox_updater"
ls -l /etc/config/singbox_updater >/dev/null 2>&1 || die "UCI package file was not created"

uci -q delete singbox_updater.main >/dev/null 2>&1 || true
uci set singbox_updater.main='singbox_updater' || die "Failed to create UCI section singbox_updater.main"
uci set singbox_updater.main.url="$URL"
uci set singbox_updater.main.schedule="$SCHEDULE"
uci set singbox_updater.main.retries="$RETRIES"
uci set singbox_updater.main.connect_timeout="$CONNECT_TIMEOUT"
uci set singbox_updater.main.max_time="$MAX_TIME"
uci set singbox_updater.main.backup_keep="$BACKUP_KEEP"
uci set singbox_updater.main.run_on_boot="$RUN_ON_BOOT"
uci set singbox_updater.main.run_on_wan_up="$RUN_ON_WAN_UP"
uci set singbox_updater.main.insecure_tls="$INSECURE_TLS"
uci set singbox_updater.main.telegram_ip_list_path="$TELEGRAM_IP_LIST_PATH"
uci set singbox_updater.main.telegram_ipset_name="$TELEGRAM_IPSET_NAME"
uci set singbox_updater.main.telegram_rule_name="$TELEGRAM_RULE_NAME"
uci set singbox_updater.main.telegram_mark_value="$TELEGRAM_MARK_VALUE"
uci set singbox_updater.main.telegram_firewall_setup="$TELEGRAM_FIREWALL_SETUP"
uci set singbox_updater.main.telegram_firewall_restart="$TELEGRAM_FIREWALL_RESTART"

if [ -n "$TELEGRAM_IP_LIST_URL" ]; then
	uci set singbox_updater.main.telegram_ip_list_url="$TELEGRAM_IP_LIST_URL"
else
	uci -q delete singbox_updater.main.telegram_ip_list_url >/dev/null 2>&1 || true
fi
if [ -n "$TELEGRAM_IP_LIST_SHA256" ]; then
	uci set singbox_updater.main.telegram_ip_list_sha256="$TELEGRAM_IP_LIST_SHA256"
else
	uci -q delete singbox_updater.main.telegram_ip_list_sha256 >/dev/null 2>&1 || true
fi
if [ -n "$RESOLVE_HOST" ]; then
	uci set singbox_updater.main.resolve_host="$RESOLVE_HOST"
else
	uci -q delete singbox_updater.main.resolve_host >/dev/null 2>&1 || true
fi
if [ -n "$RESOLVE_IP" ]; then
	uci set singbox_updater.main.resolve_ip="$RESOLVE_IP"
else
	uci -q delete singbox_updater.main.resolve_ip >/dev/null 2>&1 || true
fi
if [ -n "$SHA256" ]; then
	uci set singbox_updater.main.sha256="$SHA256"
else
	uci -q delete singbox_updater.main.sha256 >/dev/null 2>&1 || true
fi
uci commit singbox_updater || die "Failed to commit /etc/config/singbox_updater"

if [ "$TELEGRAM_FIREWALL_SETUP" = "1" ]; then
	say "Preparing Telegram firewall ipset/rule"
	ensure_telegram_ip_list_file "$TELEGRAM_IP_LIST_PATH"
	ensure_telegram_firewall_config "$TELEGRAM_IPSET_NAME" "$TELEGRAM_RULE_NAME" "$TELEGRAM_IP_LIST_PATH" "$TELEGRAM_MARK_VALUE"
else
	say "Telegram firewall setup is disabled by TELEGRAM_FIREWALL_SETUP=$TELEGRAM_FIREWALL_SETUP"
fi

say "Writing /usr/bin/singbox-config-update"
cat > /usr/bin/singbox-config-update <<'UPDATER_EOF'
#!/bin/sh

set -u
umask 077

TAG="singbox-updater"
CFG="/etc/sing-box/config.json"
UCI_SECTION="singbox_updater.main"

VERBOSE=0
FORCE=0
DRYRUN=0
REASON="manual"
DO_INSTALL_CRON=0
DO_REMOVE_CRON=0

log() {
	logger -t "$TAG" "$*"
	[ "$VERBOSE" -eq 1 ] && echo "$TAG: $*"
}

die() {
	log "ERROR: $*"
	exit 1
}

is_num() {
	case "${1:-}" in
		''|*[!0-9]*) return 1 ;;
		*) return 0 ;;
	esac
}

get_uci() {
	uci -q get "${UCI_SECTION}.${1}" 2>/dev/null || true
}

trim_brackets() {
	value="$1"
	case "$value" in
		\[*\]) value="${value#\[}"; value="${value%\]}" ;;
	esac
	echo "$value"
}

url_scheme() {
	url="$1"
	case "$url" in
		*://*)
			echo "${url%%://*}"
			return 0
			;;
	esac
	return 1
}

url_authority() {
	url="$1"
	case "$url" in
		*://*)
			rest="${url#*://}"
			echo "${rest%%/*}"
			return 0
			;;
	esac
	return 1
}

url_host() {
	authority="$(url_authority "$1" 2>/dev/null || true)"
	[ -n "$authority" ] || return 1
	hostport="${authority##*@}"
	case "$hostport" in
		\[*\]:*)
			host="${hostport#\[}"
			host="${host%%]*}"
			echo "$host"
			return 0
			;;
		\[*\])
			host="${hostport#\[}"
			host="${host%\]}"
			echo "$host"
			return 0
			;;
		*:*)
			echo "${hostport%%:*}"
			return 0
			;;
		*)
			echo "$hostport"
			return 0
			;;
	esac
}

url_port() {
	url="$1"
	scheme="$(url_scheme "$url" 2>/dev/null || true)"
	authority="$(url_authority "$url" 2>/dev/null || true)"
	[ -n "$authority" ] || return 1
	hostport="${authority##*@}"
	case "$hostport" in
		\[*\]:*)
			echo "${hostport##*]:}"
			return 0
			;;
		\[*\])
			:
			;;
		*:*)
			echo "${hostport##*:}"
			return 0
			;;
	esac
	case "$scheme" in
		https) echo 443 ;;
		http) echo 80 ;;
		*) return 1 ;;
	esac
}

fetch_with_curl() {
	url="$1"
	out="$2"
	connect_timeout="$3"
	max_time="$4"
	insecure_tls="$5"
	resolve_host="$6"
	resolve_ip="$7"

	set -- -fsSL

	if [ "$insecure_tls" = "1" ]; then
		log "using insecure TLS mode"
		set -- "$@" -k
	fi

	url_host_value="$(url_host "$url" 2>/dev/null || true)"
	url_scheme_value="$(url_scheme "$url" 2>/dev/null || true)"

	if [ -n "$resolve_host" ] && [ -n "$resolve_ip" ]; then
		if [ -n "$url_host_value" ] && [ "$url_host_value" = "$resolve_host" ]; then
			if [ "$url_scheme_value" = "https" ]; then
				resolve_port="$(url_port "$url" 2>/dev/null || echo 443)"
				resolve_ip_fmt="$(trim_brackets "$resolve_ip")"
				log "using curl --resolve for host $resolve_host:$resolve_port -> $resolve_ip_fmt"
				set -- "$@" --resolve "$resolve_host:$resolve_port:$resolve_ip_fmt"
			else
				log "URL scheme '$url_scheme_value' is not https; skipping --resolve"
			fi
		else
			log "URL host does not match resolve_host, skipping --resolve"
		fi
	else
		log "downloading without custom resolve"
	fi

	set -- "$@" --connect-timeout "$connect_timeout" --max-time "$max_time" -o "$out" "$url"
	curl "$@" >/dev/null 2>&1
}

usage() {
	cat <<USG
Usage: $0 [options]
  -v, --verbose        verbose output
  --force              restart even if config unchanged
  --dry-run            don't write config/list / restart firewall/sing-box
  --reason <text>      annotate logs (cron/boot/wanup/manual/installer)
  --install-cron       ensure cron entry exists (based on UCI schedule)
  --remove-cron        remove cron entry
USG
}

while [ $# -gt 0 ]; do
	case "$1" in
		-v|--verbose) VERBOSE=1; shift ;;
		--force) FORCE=1; shift ;;
		--dry-run) DRYRUN=1; shift ;;
		--reason) shift; REASON="${1:-manual}"; shift ;;
		--install-cron) DO_INSTALL_CRON=1; shift ;;
		--remove-cron) DO_REMOVE_CRON=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) die "Unknown argument: $1" ;;
	esac
done

ensure_dirs() {
	[ -d /etc/sing-box ] || mkdir -p /etc/sing-box || die "Cannot create /etc/sing-box"
}

restart_singbox() {
	if [ -x /etc/init.d/sing-box ]; then
		/etc/init.d/sing-box restart >/dev/null 2>&1 && return 0
	fi
	if [ -x /etc/init.d/singbox ]; then
		/etc/init.d/singbox restart >/dev/null 2>&1 && return 0
	fi
	if [ -x /etc/init.d/sing-box-service ]; then
		/etc/init.d/sing-box-service restart >/dev/null 2>&1 && return 0
	fi
	if pidof sing-box >/dev/null 2>&1; then
		killall -HUP sing-box >/dev/null 2>&1 && return 0
	fi
	return 1
}

restart_firewall() {
	if command -v service >/dev/null 2>&1; then
		service firewall restart >/dev/null 2>&1 && return 0
	fi
	if [ -x /etc/init.d/firewall ]; then
		/etc/init.d/firewall restart >/dev/null 2>&1 && return 0
	fi
	return 1
}

verify_firewall_set() {
	ipset_name="$1"

	if ! command -v nft >/dev/null 2>&1; then
		log "nft is unavailable; cannot verify firewall set '$ipset_name'"
		return 0
	fi

	nft list set inet fw4 "$ipset_name" >/dev/null 2>&1
}

validate_json_basic() {
	f="$1"
	[ -s "$f" ] || return 1
	grep -q '^[[:space:]]*{' "$f" || return 1
	grep -q '}' "$f" || return 1
	return 0
}

validate_with_singbox_if_possible() {
	f="$1"
	if command -v sing-box >/dev/null 2>&1; then
		sing-box check -h >/dev/null 2>&1 || return 0
		sing-box check -c "$f" >/dev/null 2>&1 || return 1
	fi
	return 0
}

fetch_to_file() {
	url="$1"
	out="$2"
	connect_timeout="$3"
	max_time="$4"
	insecure_tls="$5"
	resolve_host="$6"
	resolve_ip="$7"

	case "$url" in
		/*)
			[ -f "$url" ] || return 1
			cat "$url" > "$out" || return 1
			return 0
			;;
	esac

	if command -v curl >/dev/null 2>&1; then
		fetch_with_curl "$url" "$out" "$connect_timeout" "$max_time" "$insecure_tls" "$resolve_host" "$resolve_ip"
		return $?
	fi

	if command -v uclient-fetch >/dev/null 2>&1; then
		[ -z "$resolve_host" ] || [ -z "$resolve_ip" ] || log "curl is unavailable; custom --resolve cannot be applied"
		[ "$insecure_tls" = "1" ] && log "curl is unavailable; insecure TLS mode cannot be applied with uclient-fetch"
		log "downloading with uclient-fetch"
		uclient-fetch -q -O "$out" "$url" >/dev/null 2>&1
		return $?
	fi

	return 127
}

normalize_ipv4_cidr_list() {
	in_file="$1"
	out_file="$2"

	awk '
	function trim(s) {
		gsub(/^[ \t]+/, "", s)
		gsub(/[ \t]+$/, "", s)
		return s
	}
	BEGIN {
		count = 0
		err = 0
	}
	{
		sub(/\r$/, "", $0)
		sub(/#.*/, "", $0)
		line = trim($0)
		if (line == "") {
			next
		}

		if (line !~ /^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\/[0-9][0-9]*$/) {
			print "invalid IPv4 CIDR line: " line > "/dev/stderr"
			err = 1
			exit
		}

		split(line, parts, "/")
		prefix = parts[2] + 0
		if (prefix < 0 || prefix > 32) {
			print "invalid IPv4 CIDR prefix: " line > "/dev/stderr"
			err = 1
			exit
		}

		split(parts[1], octets, ".")
		for (i = 1; i <= 4; i++) {
			if (octets[i] !~ /^[0-9][0-9]*$/ || octets[i] < 0 || octets[i] > 255) {
				print "invalid IPv4 octet: " line > "/dev/stderr"
				err = 1
				exit
			}
		}

		if (!seen[line]) {
			seen[line] = 1
			print line
			count++
		}
	}
	END {
		if (err) {
			exit 1
		}
		if (count == 0) {
			print "Telegram IPv4 CIDR list contains no usable entries" > "/dev/stderr"
			exit 1
		}
	}
	' "$in_file" > "$out_file"
}

find_firewall_section_by_name() {
	type="$1"
	name="$2"

	uci -q show firewall 2>/dev/null | awk -F= -v type="$type" -v name="$name" '
		$1 ~ "^firewall\\.@" type "\\[[0-9]+\\]\\.name$" {
			v = $2
			gsub(/\047/, "", v)
			if (v == name) {
				sub(/^firewall\./, "", $1)
				sub(/\.name$/, "", $1)
				print $1
				exit
			}
		}
	'
}

ensure_telegram_firewall_config() {
	ipset_name="$1"
	rule_name="$2"
	list_path="$3"
	mark_value="$4"

	ipset_section="$(find_firewall_section_by_name ipset "$ipset_name" || true)"
	if [ -n "$ipset_section" ]; then
		ipset_ref="$ipset_section"
		log "Telegram firewall ipset section exists: firewall.$ipset_ref"
	else
		ipset_ref="telegram_ips_auto"
		uci -q delete "firewall.$ipset_ref" >/dev/null 2>&1 || true
		uci set "firewall.$ipset_ref=ipset" || return 1
		log "Telegram firewall ipset section created: firewall.$ipset_ref"
	fi

	uci set "firewall.$ipset_ref.name=$ipset_name" || return 1
	uci set "firewall.$ipset_ref.family=ipv4" || return 1
	uci -q delete "firewall.$ipset_ref.match" >/dev/null 2>&1 || true
	uci add_list "firewall.$ipset_ref.match=dest_net" || return 1
	uci set "firewall.$ipset_ref.loadfile=$list_path" || return 1

	rule_section="$(find_firewall_section_by_name rule "$rule_name" || true)"
	if [ -n "$rule_section" ]; then
		rule_ref="$rule_section"
		log "Telegram firewall MARK rule section exists: firewall.$rule_ref"
	else
		rule_ref="telegram_ips_mark_auto"
		uci -q delete "firewall.$rule_ref" >/dev/null 2>&1 || true
		uci set "firewall.$rule_ref=rule" || return 1
		log "Telegram firewall MARK rule section created: firewall.$rule_ref"
	fi

	uci set "firewall.$rule_ref.name=$rule_name" || return 1
	uci set "firewall.$rule_ref.src=lan" || return 1
	uci set "firewall.$rule_ref.dest=*" || return 1
	uci set "firewall.$rule_ref.proto=all" || return 1
	uci set "firewall.$rule_ref.ipset=$ipset_name" || return 1
	uci set "firewall.$rule_ref.set_mark=$mark_value" || return 1
	uci set "firewall.$rule_ref.target=MARK" || return 1
	uci set "firewall.$rule_ref.family=ipv4" || return 1

	uci commit firewall || return 1
	return 0
}

update_telegram_ip_list() {
	tmpdir="$1"
	reason="$2"
	dryrun="$3"
	retries="$4"
	connect_timeout="$5"
	max_time="$6"
	insecure_tls="$7"
	resolve_host="$8"
	resolve_ip="$9"
	ip_list_url="${10}"
	ip_list_path="${11}"
	ip_list_sha256="${12}"
	ipset_name="${13}"
	rule_name="${14}"
	mark_value="${15}"
	firewall_setup="${16}"
	firewall_restart="${17}"

	[ -n "$ip_list_url" ] || {
		[ "$VERBOSE" -eq 1 ] && log "[$reason] Telegram IPv4 list URL is empty; skipping list update"
		return 0
	}

	log "[$reason] checking Telegram IPv4 list from: $ip_list_url"

	list_dir="$(dirname "$ip_list_path")"
	mkdir -p "$list_dir" || {
		log "ERROR: [$reason] cannot create Telegram IP list directory: $list_dir; keeping existing list"
		return 0
	}

	raw="$tmpdir/telegram_ip_cidrs.raw"
	normalized="$tmpdir/telegram_ip_cidrs.normalized"
	rm -f "$raw" "$normalized" >/dev/null 2>&1 || true

	attempt=1
	sleep_s=2
	ok=0
	while [ "$attempt" -le "$retries" ]; do
		if fetch_to_file "$ip_list_url" "$raw" "$connect_timeout" "$max_time" "$insecure_tls" "$resolve_host" "$resolve_ip"; then
			ok=1
			break
		fi
		log "[$reason] Telegram IPv4 list download failed (attempt $attempt/$retries), sleeping ${sleep_s}s"
		sleep "$sleep_s" >/dev/null 2>&1 || true
		sleep_s=$((sleep_s * 2))
		attempt=$((attempt + 1))
	done

	if [ "$ok" -ne 1 ]; then
		log "WARNING: [$reason] Telegram IPv4 list download failed after $retries attempts; keeping existing list"
		return 0
	fi

	if [ ! -s "$raw" ]; then
		log "WARNING: [$reason] downloaded Telegram IPv4 list is empty; keeping existing list"
		return 0
	fi

	if [ -n "$ip_list_sha256" ]; then
		if command -v sha256sum >/dev/null 2>&1; then
			got="$(sha256sum "$raw" | awk '{print $1}')"
			if [ "$got" != "$ip_list_sha256" ]; then
				log "WARNING: [$reason] Telegram IPv4 list SHA256 mismatch (got $got, want $ip_list_sha256); keeping existing list"
				return 0
			fi
		else
			log "WARNING: [$reason] sha256sum unavailable; cannot verify Telegram IPv4 list SHA256; keeping existing list"
			return 0
		fi
	fi

	if ! normalize_ipv4_cidr_list "$raw" "$normalized"; then
		log "WARNING: [$reason] Telegram IPv4 list validation failed; keeping existing list"
		return 0
	fi

	entry_count="$(wc -l < "$normalized" | tr -d ' ')"
	log "[$reason] Telegram IPv4 list validated: $entry_count CIDR entries"

	if [ -f "$ip_list_path" ] && cmp -s "$normalized" "$ip_list_path"; then
		log "[$reason] Telegram IPv4 list has no changes"
		return 0
	fi

	if [ "$dryrun" -eq 1 ]; then
		log "[$reason] Telegram IPv4 list differs; --dry-run: would replace $ip_list_path and restart firewall"
		return 0
	fi

	backup=""
	if [ -f "$ip_list_path" ]; then
		ts="$(date +%Y%m%d%H%M%S)"
		backup="${ip_list_path}.bak.${ts}"
		cp "$ip_list_path" "$backup" >/dev/null 2>&1 || backup=""
		[ -n "$backup" ] && log "[$reason] Telegram IPv4 list backup created: $backup"
	fi

	stage="$list_dir/.telegram_ip_cidrs.stage.$$"
	rm -f "$stage" >/dev/null 2>&1 || true

	cp "$normalized" "$stage" || {
		log "ERROR: [$reason] failed to stage Telegram IPv4 list; keeping existing list"
		rm -f "$stage" >/dev/null 2>&1 || true
		return 0
	}
	chmod 600 "$stage" >/dev/null 2>&1 || true
	chown root:root "$stage" >/dev/null 2>&1 || true

	if ! mv -f "$stage" "$ip_list_path"; then
		log "ERROR: [$reason] failed to replace Telegram IPv4 list; keeping existing list"
		rm -f "$stage" >/dev/null 2>&1 || true
		return 0
	fi

	sync >/dev/null 2>&1 || true
	log "[$reason] Telegram IPv4 list updated: $ip_list_path"

	if [ "$firewall_setup" = "1" ]; then
		if ensure_telegram_firewall_config "$ipset_name" "$rule_name" "$ip_list_path" "$mark_value"; then
			log "[$reason] Telegram firewall ipset/rule config is ensured"
		else
			log "ERROR: [$reason] failed to ensure Telegram firewall ipset/rule config"
		fi
	fi

	if [ "$firewall_restart" = "1" ]; then
		log "[$reason] restarting firewall to reload Telegram IPv4 ipset"
		if restart_firewall; then
			if verify_firewall_set "$ipset_name"; then
				log "[$reason] firewall restarted and set '$ipset_name' verified"
			else
				log "ERROR: [$reason] firewall restarted, but nft set '$ipset_name' was not found"
				if [ -n "$backup" ] && [ -f "$backup" ]; then
					cp "$backup" "$ip_list_path" >/dev/null 2>&1 || true
					restart_firewall >/dev/null 2>&1 || true
					log "[$reason] rolled Telegram IPv4 list back to previous backup"
				fi
			fi
		else
			log "ERROR: [$reason] firewall restart failed after Telegram IPv4 list update"
			if [ -n "$backup" ] && [ -f "$backup" ]; then
				cp "$backup" "$ip_list_path" >/dev/null 2>&1 || true
				restart_firewall >/dev/null 2>&1 || true
				log "[$reason] rolled Telegram IPv4 list back to previous backup"
			fi
		fi
	else
		log "[$reason] TELEGRAM_FIREWALL_RESTART is disabled; firewall was not restarted"
	fi

	return 0
}

install_cron() {
	schedule="$(get_uci schedule)"
	[ -n "$schedule" ] || schedule="0 4 * * *"
	line="$schedule /usr/bin/singbox-config-update --reason cron # singbox-updater"

	[ -d /etc/crontabs ] || mkdir -p /etc/crontabs || die "Cannot create /etc/crontabs"
	[ -f /etc/crontabs/root ] || touch /etc/crontabs/root || die "Cannot touch /etc/crontabs/root"
	chmod 600 /etc/crontabs/root >/dev/null 2>&1 || true

	grep -v '# singbox-updater' /etc/crontabs/root > /tmp/.root.cron.$$ 2>/dev/null || true
	echo "$line" >> /tmp/.root.cron.$$ || die "Cannot write cron temp"
	cat /tmp/.root.cron.$$ > /etc/crontabs/root || die "Cannot update /etc/crontabs/root"
	rm -f /tmp/.root.cron.$$ >/dev/null 2>&1 || true

	if [ -x /etc/init.d/cron ]; then
		/etc/init.d/cron enable >/dev/null 2>&1 || true
		/etc/init.d/cron restart >/dev/null 2>&1 || true
	elif [ -x /etc/init.d/crond ]; then
		/etc/init.d/crond enable >/dev/null 2>&1 || true
		/etc/init.d/crond restart >/dev/null 2>&1 || true
	fi

	log "cron installed: $line"
}

remove_cron() {
	[ -f /etc/crontabs/root ] || { log "cron not present"; return 0; }
	grep -v '# singbox-updater' /etc/crontabs/root > /tmp/.root.cron.$$ 2>/dev/null || true
	cat /tmp/.root.cron.$$ > /etc/crontabs/root || true
	rm -f /tmp/.root.cron.$$ >/dev/null 2>&1 || true

	if [ -x /etc/init.d/cron ]; then
		/etc/init.d/cron restart >/dev/null 2>&1 || true
	elif [ -x /etc/init.d/crond ]; then
		/etc/init.d/crond restart >/dev/null 2>&1 || true
	fi

	log "cron removed"
}

rotate_backups() {
	keep="$1"
	[ -f "$CFG" ] || return 0
	i=0
	for f in $(ls -1t "${CFG}.bak."* 2>/dev/null); do
		i=$((i + 1))
		if [ "$i" -gt "$keep" ]; then
			rm -f "$f" >/dev/null 2>&1 || true
		fi
	done
}

make_stage_path() {
	cfgdir="$(dirname "$CFG")"
	if command -v mktemp >/dev/null 2>&1; then
		mktemp "$cfgdir/.config.json.stage.XXXXXX" 2>/dev/null && return 0
	fi
	echo "$cfgdir/.config.json.stage.$$"
	return 0
}

main_update() {
	url="$(get_uci url)"
	[ -n "$url" ] || die "UCI option 'url' is empty in /etc/config/singbox_updater"

	retries="$(get_uci retries)"; is_num "$retries" || retries=8
	connect_timeout="$(get_uci connect_timeout)"; is_num "$connect_timeout" || connect_timeout=10
	max_time="$(get_uci max_time)"; is_num "$max_time" || max_time=30
	backup_keep="$(get_uci backup_keep)"; is_num "$backup_keep" || backup_keep=7
	insecure_tls="$(get_uci insecure_tls)"
	[ -n "$insecure_tls" ] || insecure_tls=1
	resolve_host="$(get_uci resolve_host)"
	resolve_ip="$(get_uci resolve_ip)"
	want_sha256="$(get_uci sha256)"

	telegram_ip_list_url="$(get_uci telegram_ip_list_url)"
	telegram_ip_list_path="$(get_uci telegram_ip_list_path)"
	[ -n "$telegram_ip_list_path" ] || telegram_ip_list_path="/etc/sing-box/telegram_ip_cidrs_v4.txt"
	telegram_ip_list_sha256="$(get_uci telegram_ip_list_sha256)"
	telegram_ipset_name="$(get_uci telegram_ipset_name)"
	[ -n "$telegram_ipset_name" ] || telegram_ipset_name="telegram_ips"
	telegram_rule_name="$(get_uci telegram_rule_name)"
	[ -n "$telegram_rule_name" ] || telegram_rule_name="mark_telegram_ips"
	telegram_mark_value="$(get_uci telegram_mark_value)"
	[ -n "$telegram_mark_value" ] || telegram_mark_value="0x1"
	telegram_firewall_setup="$(get_uci telegram_firewall_setup)"
	[ -n "$telegram_firewall_setup" ] || telegram_firewall_setup=1
	telegram_firewall_restart="$(get_uci telegram_firewall_restart)"
	[ -n "$telegram_firewall_restart" ] || telegram_firewall_restart=1

	ensure_dirs

	if [ "$REASON" = "boot" ] && command -v ubus >/dev/null 2>&1; then
		if ! ubus call network.interface.wan status 2>/dev/null | grep -q '"up": true'; then
			log "[boot] WAN not up yet; skip (wanup will handle if enabled)"
			exit 0
		fi
	fi

	LOCKDIR="/tmp/singbox-updater.lock"
	if ! mkdir "$LOCKDIR" 2>/dev/null; then
		log "[$REASON] another instance is running; exit"
		exit 0
	fi
	trap 'rmdir "$LOCKDIR" >/dev/null 2>&1 || true' EXIT INT TERM

	TMPDIR="/tmp/singbox-updater"
	NEW="$TMPDIR/config.json.new"
	mkdir -p "$TMPDIR" || die "Cannot create $TMPDIR"
	rm -f "$NEW" >/dev/null 2>&1 || true

	log "[$REASON] checking config from: $url"
	[ -n "$resolve_host" ] && [ -n "$resolve_ip" ] && log "[$REASON] local resolve override configured: $resolve_host -> $resolve_ip"

	attempt=1
	sleep_s=2
	ok=0
	while [ "$attempt" -le "$retries" ]; do
		if fetch_to_file "$url" "$NEW" "$connect_timeout" "$max_time" "$insecure_tls" "$resolve_host" "$resolve_ip"; then
			ok=1
			break
		fi
		log "[$REASON] download failed (attempt $attempt/$retries), sleeping ${sleep_s}s"
		sleep "$sleep_s" >/dev/null 2>&1 || true
		sleep_s=$((sleep_s * 2))
		attempt=$((attempt + 1))
	done
	[ "$ok" -eq 1 ] || die "Download failed after $retries attempts"
	[ -s "$NEW" ] || die "Downloaded file is empty"

	if [ -n "${want_sha256:-}" ]; then
		if command -v sha256sum >/dev/null 2>&1; then
			got="$(sha256sum "$NEW" | awk '{print $1}')"
			[ "$got" = "$want_sha256" ] || die "SHA256 mismatch (got $got, want $want_sha256)"
		else
			die "sha256 is set in UCI but sha256sum is not available"
		fi
	fi

	validate_json_basic "$NEW" || die "Downloaded file doesn't look like valid JSON"
	validate_with_singbox_if_possible "$NEW" || die "sing-box validation failed for new config"

	update_telegram_ip_list \
		"$TMPDIR" \
		"$REASON" \
		"$DRYRUN" \
		"$retries" \
		"$connect_timeout" \
		"$max_time" \
		"$insecure_tls" \
		"$resolve_host" \
		"$resolve_ip" \
		"$telegram_ip_list_url" \
		"$telegram_ip_list_path" \
		"$telegram_ip_list_sha256" \
		"$telegram_ipset_name" \
		"$telegram_rule_name" \
		"$telegram_mark_value" \
		"$telegram_firewall_setup" \
		"$telegram_firewall_restart"

	if [ -f "$CFG" ] && cmp -s "$NEW" "$CFG"; then
		if [ "$FORCE" -eq 1 ]; then
			if [ "$DRYRUN" -eq 1 ]; then
				log "[$REASON] no config changes, but --force + --dry-run: would restart sing-box"
				exit 0
			fi
			if restart_singbox; then
				log "[$REASON] no config changes, but --force: sing-box restarted"
				exit 0
			else
				die "No config changes, but failed to restart sing-box"
			fi
		fi
		log "[$REASON] no config changes"
		exit 0
	fi

	if [ "$DRYRUN" -eq 1 ]; then
		log "[$REASON] config differs; --dry-run: would replace $CFG and restart sing-box"
		exit 0
	fi

	if [ -f "$CFG" ]; then
		ts="$(date +%Y%m%d%H%M%S)"
		cp "$CFG" "${CFG}.bak.${ts}" >/dev/null 2>&1 || true
		rotate_backups "$backup_keep"
	fi

	STAGE="$(make_stage_path)"
	rm -f "$STAGE" >/dev/null 2>&1 || true
	trap 'rm -f "$STAGE" >/dev/null 2>&1 || true; rmdir "$LOCKDIR" >/dev/null 2>&1 || true' EXIT INT TERM

	cp "$NEW" "$STAGE" || die "Failed to stage new config (cp)"
	chmod 600 "$STAGE" >/dev/null 2>&1 || die "Failed to chmod staged config"
	chown root:root "$STAGE" >/dev/null 2>&1 || true

	mv -f "$STAGE" "$CFG" || die "Failed to replace $CFG"
	sync >/dev/null 2>&1 || true

	if restart_singbox; then
		log "[$REASON] config updated and sing-box restarted"
		exit 0
	fi

	die "Config updated, but failed to restart sing-box"
}

if [ "$DO_INSTALL_CRON" -eq 1 ]; then
	install_cron
	exit 0
fi

if [ "$DO_REMOVE_CRON" -eq 1 ]; then
	remove_cron
	exit 0
fi

main_update
UPDATER_EOF
chmod +x /usr/bin/singbox-config-update

say "Writing /etc/init.d/singbox-updater"
cat > /etc/init.d/singbox-updater <<'INIT_EOF'
#!/bin/sh /etc/rc.common

START=99
STOP=10

start() {
	/usr/bin/singbox-config-update --install-cron >/dev/null 2>&1 || true

	run_on_boot="$(uci -q get singbox_updater.main.run_on_boot 2>/dev/null || echo 0)"
	if [ "$run_on_boot" = "1" ]; then
		/usr/bin/singbox-config-update --reason boot >/dev/null 2>&1 || true
	fi
}

stop() {
	:
}
INIT_EOF
chmod +x /etc/init.d/singbox-updater

say "Writing /etc/hotplug.d/iface/99-singbox-updater"
mkdir -p /etc/hotplug.d/iface
cat > /etc/hotplug.d/iface/99-singbox-updater <<'HOTPLUG_EOF'
#!/bin/sh

[ "${ACTION:-}" = "ifup" ] || exit 0
[ "${INTERFACE:-}" = "wan" ] || exit 0

run_on_wan_up="$(uci -q get singbox_updater.main.run_on_wan_up 2>/dev/null || echo 0)"
[ "$run_on_wan_up" = "1" ] || exit 0

/usr/bin/singbox-config-update --reason wanup >/dev/null 2>&1 || true
HOTPLUG_EOF
chmod +x /etc/hotplug.d/iface/99-singbox-updater

CRON_INIT="$(ensure_cron_init || true)"
[ -n "$CRON_INIT" ] || die "cron/crond init script not found"

say "Enabling and starting cron"
"$CRON_INIT" enable >/dev/null 2>&1 || true
"$CRON_INIT" start >/dev/null 2>&1 || "$CRON_INIT" restart >/dev/null 2>&1 || true

say "Installing cron line"
/usr/bin/singbox-config-update --install-cron >/dev/null 2>&1 || die "Failed to install cron line"

say "Enabling singbox-updater service"
/etc/init.d/singbox-updater enable >/dev/null 2>&1 || true
/etc/init.d/singbox-updater restart >/dev/null 2>&1 || /etc/init.d/singbox-updater start >/dev/null 2>&1 || true

say "Configured UCI values"
echo "url=$(uci -q get singbox_updater.main.url 2>/dev/null || true)"
echo "insecure_tls=$(uci -q get singbox_updater.main.insecure_tls 2>/dev/null || true)"
echo "resolve_host=$(uci -q get singbox_updater.main.resolve_host 2>/dev/null || true)"
echo "resolve_ip=$(uci -q get singbox_updater.main.resolve_ip 2>/dev/null || true)"
echo "telegram_ip_list_url=$(uci -q get singbox_updater.main.telegram_ip_list_url 2>/dev/null || true)"
echo "telegram_ip_list_path=$(uci -q get singbox_updater.main.telegram_ip_list_path 2>/dev/null || true)"
echo "telegram_ipset_name=$(uci -q get singbox_updater.main.telegram_ipset_name 2>/dev/null || true)"
echo "telegram_rule_name=$(uci -q get singbox_updater.main.telegram_rule_name 2>/dev/null || true)"
echo "telegram_mark_value=$(uci -q get singbox_updater.main.telegram_mark_value 2>/dev/null || true)"
echo "telegram_firewall_setup=$(uci -q get singbox_updater.main.telegram_firewall_setup 2>/dev/null || true)"
echo "telegram_firewall_restart=$(uci -q get singbox_updater.main.telegram_firewall_restart 2>/dev/null || true)"

say "Running dry-run self-test"
/usr/bin/singbox-config-update --reason installer --dry-run -v || die "Dry-run self-test failed"

if [ "$APPLY_NOW" = "1" ]; then
	say "Running real self-test"
	/usr/bin/singbox-config-update --reason installer -v || die "Real self-test failed"
else
	say "Skipping real self-test because APPLY_NOW=$APPLY_NOW"
fi

say "Final checks"
echo
echo "===== STATUS ====="
date || true
echo
echo "[telegram ip list]"
ls -l "$(uci -q get singbox_updater.main.telegram_ip_list_path 2>/dev/null || echo /etc/sing-box/telegram_ip_cidrs_v4.txt)" 2>/dev/null || true
echo
echo "[telegram firewall set]"
if command -v nft >/dev/null 2>&1; then
	nft list set inet fw4 "$(uci -q get singbox_updater.main.telegram_ipset_name 2>/dev/null || echo telegram_ips)" 2>/dev/null || true
fi
echo
echo "[telegram firewall rule]"
nft list ruleset 2>/dev/null | grep -A5 -B5 "$(uci -q get singbox_updater.main.telegram_ipset_name 2>/dev/null || echo telegram_ips)" || true
echo
echo "[cron line]"
grep -n 'singbox-updater' /etc/crontabs/root || true
echo
echo "[cron process]"
ps | grep -E '[c]rond|[c]ron' || true
echo
echo "[init scripts]"
ls -1 /etc/init.d | grep -i 'sing\|cron\|firewall' || true
echo
echo "[recent singbox-updater logs]"
logread -e singbox-updater | tail -n 40 || true
echo
echo "[uci updater config]"
uci show singbox_updater || true
echo
echo "[uci firewall telegram entries]"
uci show firewall | grep -E "telegram_ips|mark_telegram_ips" || true
echo "===== DONE ====="

say "Installation completed successfully"
