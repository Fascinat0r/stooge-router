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

Optional env vars:
  SCHEDULE='0 4 * * *'   # cron schedule
  RUN_ON_BOOT=1          # run once on boot
  RUN_ON_WAN_UP=1        # run on WAN ifup
  RETRIES=8
  CONNECT_TIMEOUT=10
  MAX_TIME=30
  BACKUP_KEEP=7
  APPLY_NOW=1            # after install, do real update test
  SHA256='...'           # optional SHA256 pinning for downloaded config
  INSECURE_TLS=1         # use curl -k (enabled by default)
  RESOLVE_HOST=''        # optional: force this hostname to resolve locally
  RESOLVE_IP=''          # optional: local backend IP for RESOLVE_HOST

Example:
  APPLY_NOW=1 RUN_ON_BOOT=1 RUN_ON_WAN_UP=1 sh /root/install-singbox-updater.sh 'https://s3.example.com/path/config.json'
  RESOLVE_HOST='s3.example.com' RESOLVE_IP='192.168.1.10' INSECURE_TLS=1 sh /root/install-singbox-updater.sh 'https://s3.example.com/path/config.json'
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
  --dry-run            don't write config / restart (but download+validate+compare)
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
		i=$((i+1))
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

	# resolve_host + resolve_ip exist for the case where the config source
	# sits behind this same router. The public hostname points to this
	# router's WAN IP, but the router itself should connect directly to the
	# LAN backend while keeping the original hostname for TLS SNI and Host.
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
		sleep_s=$((sleep_s*2))
		attempt=$((attempt+1))
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

	if [ -f "$CFG" ] && cmp -s "$NEW" "$CFG"; then
		if [ "$FORCE" -eq 1 ]; then
			if [ "$DRYRUN" -eq 1 ]; then
				log "[$REASON] no changes, but --force + --dry-run: would restart sing-box"
				exit 0
			fi
			if restart_singbox; then
				log "[$REASON] no changes, but --force: sing-box restarted"
				exit 0
			else
				die "No changes, but failed to restart sing-box"
			fi
		fi
		log "[$REASON] no changes"
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
		log "[$REASON] updated and restarted sing-box"
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
echo "[cron line]"
grep -n 'singbox-updater' /etc/crontabs/root || true
echo
echo "[cron process]"
ps | grep -E '[c]rond|[c]ron' || true
echo
echo "[init scripts]"
ls -1 /etc/init.d | grep -i 'sing\|cron' || true
echo
echo "[recent singbox-updater logs]"
logread -e singbox-updater | tail -n 30 || true
echo
echo "[uci config]"
uci show singbox_updater || true
echo "===== DONE ====="

say "Installation completed successfully"
