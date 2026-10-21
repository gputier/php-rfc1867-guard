#!/bin/sh
# install.sh: installs rfc1867_guard on every PHP found on this machine.
#
#   install.sh [--dry-run] [--check] [--uninstall] [--build] [--only <path>]
#
#   --dry-run    show what would be done, change nothing
#   --check      report the state only; exit 0 when every installation is guarded
#   --uninstall  remove the ini files and the extension, then reload
#   --build      compile with phpize instead of using the prebuilt binary in dist/
#   --only PATH  handle a single installation (a php binary, or its prefix directory)
#
# Exit code: 0 when everything requested succeeded (or is guarded for --check), 1 otherwise,
# 2 on a usage error. Output: one line per installation.
set -u

DIR=$(cd "$(dirname "$0")" && pwd)
MODE=install
DRY=0
FORCE_BUILD=0
ONLY=""
BAD=0
SEEN_APACHE=""
ALT_TOUCHED=0
# PHP code run by the CLI to read the live guard state: prints 1 when the multipart hook is detached.
# shellcheck disable=SC2016
CLI_PROBE='if (!function_exists("rfc1867_guard_status")) { echo "0"; } else { $s = rfc1867_guard_status(); echo $s["active"] ? "1" : "0"; }'

usage() {
	sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
	case $1 in
	--dry-run) DRY=1 ;;
	--check) MODE=check ;;
	--uninstall) MODE=uninstall ;;
	--build) FORCE_BUILD=1 ;;
	--only)
		[ $# -ge 2 ] || { usage >&2; exit 2; }
		ONLY=$2
		shift
		;;
	-h | --help) usage; exit 0 ;;
	*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done

if [ "$MODE" != check ] && [ "$DRY" = 0 ] && [ "$(id -u)" != 0 ]; then
	echo "must run as root (use --dry-run or --check to inspect)" >&2
	exit 1
fi

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- helpers

report() { # status message
	printf '%-8s %s | PHP %s %s | %s\n' "$1" "$I_BIN" "$I_VER" "$I_BUILD" "$2"
	case $1 in OK | SKIP | NOTE | WOULD) ;; *) BAD=1 ;; esac
}

real() {
	readlink -f "$1" 2>/dev/null || printf '%s' "$1"
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

# ---------------------------------------------------------------- discovery

candidates() {
	for p in /usr/bin/php /usr/bin/php[0-9]* /usr/local/bin/php /usr/local/bin/php[0-9]* \
		/opt/remi/php*/root/usr/bin/php /opt/cpanel/ea-php*/root/usr/bin/php \
		/opt/alt/php*/usr/bin/php /usr/local/php*/bin/php /opt/plesk/php/*/bin/php; do
		[ -f "$p" ] && [ -x "$p" ] && printf '%s\n' "$p"
	done
	oldifs=$IFS
	IFS=:
	for d in $PATH; do
		IFS=$oldifs
		for p in "$d"/php "$d"/php[0-9]*; do
			[ -f "$p" ] && [ -x "$p" ] && printf '%s\n' "$p"
		done
		for p in "$d"/php-config*; do
			if [ -f "$p" ] && [ -x "$p" ]; then
				b=$("$p" --php-binary 2>/dev/null </dev/null)
				[ -n "$b" ] && [ -x "$b" ] && printf '%s\n' "$b"
			fi
		done
		IFS=:
	done
	IFS=$oldifs
}

only_binary() {
	if [ -d "$ONLY" ]; then
		for p in "$ONLY/bin/php" "$ONLY/usr/bin/php" "$ONLY/root/usr/bin/php"; do
			[ -x "$p" ] && { printf '%s\n' "$p"; return; }
		done
	elif [ -x "$ONLY" ]; then
		printf '%s\n' "$ONLY"
	fi
}

# Fills I_* for the php binary $1; returns 1 when it is not a usable PHP CLI.
introspect() {
	I_BIN=$1
	line=$("$I_BIN" -r 'echo PHP_VERSION,"|",PHP_VERSION_ID,"|",php_uname("m"),"|",ini_get("extension_dir");' 2>/dev/null </dev/null) || return 1
	[ -n "$line" ] || return 1
	I_VER=${line%%|*}
	rest=${line#*|}
	I_VID=${rest%%|*}
	rest=${rest#*|}
	I_ARCH=${rest%%|*}
	I_EXT=${rest#*|}
	I_MAJOR=${I_VER%%.*}
	I_MINOR=$(printf '%s' "$I_VER" | cut -d. -f1,2)
	I_BUILD=$("$I_BIN" -i 2>/dev/null </dev/null | sed -n 's/^PHP Extension Build => //p' | head -n 1)
	I_SCAN=$("$I_BIN" --ini 2>/dev/null </dev/null | sed -n 's/^Scan for additional .ini files in: *//p' | head -n 1)
	return 0
}

# Directories that must hold rfc1867_guard.ini: one per SAPI on Debian layouts, else the scan dir.
sapi_confdirs() {
	case $I_SCAN in '' | '(none)') return 1 ;; esac
	[ -d "$I_SCAN" ] || return 1
	base=$(dirname "$I_SCAN")
	if [ "$(basename "$I_SCAN")" = conf.d ] && [ "$(basename "$base")" = cli ]; then
		for d in "$(dirname "$base")"/*/conf.d; do
			[ -d "$d" ] && printf '%s\n' "$d"
		done
	else
		printf '%s\n' "$I_SCAN"
	fi
}

# php-fpm binaries that belong to the installation (same PHP version).
fpm_binaries() {
	for bin in "$I_BIN" "$(real "$I_BIN")"; do
		bindir=$(dirname "$bin")
		suffix=${bin##*/php}
		for f in "$bindir/../sbin/php-fpm" "$bindir/php-fpm" "/usr/sbin/php-fpm$suffix" \
			"/usr/sbin/php$suffix-fpm" "/usr/sbin/php-fpm"; do
			if [ -x "$f" ] && "$f" -v 2>/dev/null </dev/null | head -n 1 | grep -q "^PHP $I_VER "; then
				real "$f"
			fi
		done
	done | sort -u
}

# Real executable of a process. Under qemu-user emulation /proc/<pid>/exe is the emulator and the
# guest binary is the first argument.
proc_exe() { # pid
	exe=$(readlink "/proc/$1/exe" 2>/dev/null) || return 1
	exe=${exe% (deleted)}
	case ${exe##*/} in
	qemu-*) exe=$(tr '\0' '\n' <"/proc/$1/cmdline" 2>/dev/null | sed -n 2p) ;;
	esac
	[ -n "$exe" ] && printf '%s' "$exe"
}

is_emulated() { # pid
	case $(readlink "/proc/$1/exe" 2>/dev/null) in */qemu-*) return 0 ;; esac
	return 1
}

# PIDs of running php-fpm masters of this installation: the processes running its php-fpm binary
# whose parent does not run it.
fpm_masters() {
	bins=$(fpm_binaries)
	[ -n "$bins" ] || return 0
	for p in /proc/[0-9]*; do
		pid=${p#/proc/}
		exe=$(proc_exe "$pid") || continue
		for b in $bins; do
			[ "$exe" = "$b" ] || continue
			ppid=$(sed -n 's/^PPid:[[:space:]]*//p' "$p/status" 2>/dev/null)
			[ "$(proc_exe "$ppid")" = "$b" ] || printf '%s\n' "$pid"
		done
	done
}

# PIDs of running Apache parents that embed this PHP (mod_php).
apache_parents() {
	for p in /proc/[0-9]*; do
		exe=$(readlink "$p/exe" 2>/dev/null) || continue
		case ${exe##*/} in apache2 | httpd | httpd.worker | httpd.event | httpd.prefork) ;; *) continue ;; esac
		ppid=$(sed -n 's/^PPid:[[:space:]]*//p' "$p/status" 2>/dev/null)
		pexe=$(readlink "/proc/$ppid/exe" 2>/dev/null)
		[ "${pexe##*/}" = "${exe##*/}" ] && continue
		lib=$(grep -o '[^ ]*libphp[^ ]*\.so' "$p/maps" 2>/dev/null | head -n 1)
		[ -n "$lib" ] || continue
		case ${lib##*/} in
		"libphp$I_MINOR.so" | "libphp$I_MAJOR.so" | libphp.so) printf '%s\n' "${p#/proc/}" ;;
		esac
	done
}

unit_of() { # pid -> systemd unit, empty when none
	sed -n 's#.*/\([^/]*\.service\)$#\1#p' "/proc/$1/cgroup" 2>/dev/null | head -n 1
}

has_guard_mapped() { # pid
	grep 'rfc1867_guard\.so' "/proc/$1/maps" 2>/dev/null | grep -v '(deleted)' | grep -q .
}

apache_ctl() {
	for c in apachectl apache2ctl httpd; do
		command -v "$c" >/dev/null 2>&1 && { command -v "$c"; return; }
	done
}

# ---------------------------------------------------------------- the .so

dist_so() {
	[ "$I_ARCH" = x86_64 ] || return 1
	[ -f "$DIR/dist/BUILDINFO" ] || return 1
	awk -v m="$I_MINOR" -v b="$I_BUILD" '$1 == m && $3 == b { f = 1 } END { exit !f }' "$DIR/dist/BUILDINFO" || return 1
	f="$DIR/dist/rfc1867_guard-$I_MINOR-nts-x86_64.so"
	[ -f "$f" ] || return 1
	want=$(awk -v n="$(basename "$f")" '$2 == n || $2 == "*" n { print $1 }' "$DIR/dist/SHA256SUMS" 2>/dev/null)
	[ -n "$want" ] && [ "$(sha256_of "$f")" = "$want" ] || {
		SO_NOTE="checksum mismatch for $(basename "$f")"
		return 1
	}
	printf '%s\n' "$f"
}

dry_load() { # so file
	err=$("$I_BIN" -n -d "extension=$1" -r 'var_dump(rfc1867_guard_status());' 2>&1 >"$TMP/dry.out" </dev/null)
	[ -z "$err" ] && grep -A1 '\["active"\]' "$TMP/dry.out" | grep -q 'bool(true)'
}

phpize_for() { # prints "phpize|php-config" for this installation
	for bin in "$I_BIN" "$(real "$I_BIN")"; do
		bindir=$(dirname "$bin")
		suffix=${bin##*/php}
		for s in "$suffix" ""; do
			if [ -x "$bindir/phpize$s" ] && [ -x "$bindir/php-config$s" ] \
				&& [ "$("$bindir/php-config$s" --version 2>/dev/null </dev/null)" = "$I_VER" ]; then
				printf '%s|%s\n' "$bindir/phpize$s" "$bindir/php-config$s"
				return 0
			fi
		done
	done
	return 1
}

build_so() { # prints the built .so path
	tools=$(phpize_for) || { SO_NOTE="no phpize/php-config for PHP $I_VER"; return 1; }
	phpize=${tools%%|*}
	phpconfig=${tools#*|}
	work="$TMP/build-$$-$I_MINOR"
	rm -rf "$work"
	mkdir -p "$work"
	cp -R "$DIR/src/." "$work/"
	if ! (cd "$work" && "$phpize" && ./configure --enable-rfc1867_guard --with-php-config="$phpconfig" && make) >"$work/build.log" 2>&1 </dev/null; then
		SO_NOTE="build failed: $(tail -n 3 "$work/build.log" | tr '\n' ' ')"
		return 1
	fi
	printf '%s\n' "$work/modules/rfc1867_guard.so"
}

# Sets SO_FILE (a verified, dry-loaded .so) and SO_HOW.
obtain_so() {
	SO_NOTE=""
	SO_FILE=""
	if [ "$FORCE_BUILD" = 0 ]; then
		f=$(dist_so) && if dry_load "$f"; then
			SO_FILE=$f
			SO_HOW="prebuilt"
			return 0
		else
			SO_NOTE="prebuilt binary does not load"
		fi
	fi
	if [ "$DRY" = 1 ]; then
		if phpize_for >/dev/null; then
			SO_FILE=""
			SO_HOW="build with phpize"
			return 0
		fi
		return 1
	fi
	f=$(build_so) || return 1
	dry_load "$f" || { SO_NOTE="built binary does not load"; return 1; }
	SO_FILE=$f
	SO_HOW="built with phpize"
}

# ---------------------------------------------------------------- reload

# Tests the configuration of what is about to be reloaded. Returns 1 and sets REASON on failure.
config_test() {
	REASON=""
	for b in $(fpm_binaries); do
		out=$("$b" -t 2>&1 </dev/null) || { REASON="$b -t: $(printf '%s' "$out" | tail -n 2 | tr '\n' ' ')"; return 1; }
	done
	if [ -n "$(apache_parents)" ]; then
		ctl=$(apache_ctl)
		[ -n "$ctl" ] || return 0
		out=$("$ctl" -t 2>&1 </dev/null) || { REASON="$ctl -t: $(printf '%s' "$out" | tail -n 2 | tr '\n' ' ')"; return 1; }
	fi
	return 0
}

# Reloads the php-fpm masters (graceful) and restarts Apache when it embeds this PHP.
# Sets RELOADED to a text, returns 1 when a service did not come back.
reload_services() {
	RELOADED=""
	for pid in $(fpm_masters); do
		unit=$(unit_of "$pid")
		if [ -n "$unit" ] && command -v systemctl >/dev/null 2>&1; then
			systemctl reload "$unit" >/dev/null 2>&1
			name=$unit
		else
			kill -USR2 "$pid"
			name="php-fpm[$pid]"
		fi
		sleep 2
		if ! fpm_alive "$unit" "$pid"; then
			RELOADED="$RELOADED $name:DOWN"
			[ -n "$unit" ] && systemctl restart "$unit" >/dev/null 2>&1
			return 1
		fi
		RELOADED="$RELOADED $name"
	done
	for pid in $(apache_parents); do
		case " $SEEN_APACHE " in *" $pid "*) continue ;; esac
		SEEN_APACHE="$SEEN_APACHE $pid"
		unit=$(unit_of "$pid")
		ctl=$(apache_ctl)
		if [ -n "$unit" ] && command -v systemctl >/dev/null 2>&1; then
			systemctl restart "$unit" >/dev/null 2>&1
			name=$unit
		else
			"$ctl" -k restart >/dev/null 2>&1
			name="apache[$pid]"
		fi
		sleep 2
		if [ -z "$(apache_parents)" ]; then
			RELOADED="$RELOADED $name:DOWN"
			return 1
		fi
		RELOADED="$RELOADED $name"
	done
	return 0
}

fpm_alive() { # unit pid
	if [ -n "$1" ] && command -v systemctl >/dev/null 2>&1; then
		systemctl is-active --quiet "$1"
	else
		[ -n "$(fpm_masters)" ]
	fi
}

# Proof from /proc: every running master/parent of this installation maps (or no longer maps) the .so.
# $1 = want|gone. Prints a short text, returns 1 when the proof fails.
prove_maps() {
	want=$1
	n=0
	fail=0
	emulated=0
	for pid in $(fpm_masters) $(apache_parents); do
		n=$((n + 1))
		if is_emulated "$pid"; then
			emulated=1
			continue
		fi
		i=0
		ok=0
		while [ $i -lt 10 ]; do
			if has_guard_mapped "$pid"; then
				[ "$want" = want ] && ok=1
			else
				[ "$want" = gone ] && ok=1
			fi
			[ $ok = 1 ] && break
			i=$((i + 1))
			sleep 1
		done
		[ $ok = 1 ] || fail=1
	done
	if [ $n = 0 ]; then
		PROOF="no running php-fpm or mod_php to prove"
	elif [ $emulated = 1 ]; then
		PROOF="$n master process(es) running under emulation: /proc maps not checkable"
	elif [ $fail = 0 ]; then
		PROOF="proven in /proc/<pid>/maps of $n master process(es)"
	else
		PROOF="/proc/<pid>/maps check failed"
		return 1
	fi
	return 0
}

# ---------------------------------------------------------------- per installation

write_ini() { # dir
	tmp="$1/.rfc1867_guard.ini.$$"
	printf '; Managed by php-rfc1867-guard install.sh\nextension=rfc1867_guard.so\n' >"$tmp" || return 1
	chmod 644 "$tmp" && mv -f "$tmp" "$1/rfc1867_guard.ini"
}

remove_inis() {
	for d in $(sapi_confdirs); do
		rm -f "$d/rfc1867_guard.ini"
	done
}

uploadprogress_note() {
	pecl=0
	"$I_BIN" -m 2>/dev/null </dev/null | grep -qi '^uploadprogress$' && pecl=1
	for d in $(sapi_confdirs); do
		grep -qsi 'uploadprogress' "$d"/*.ini && pecl=1
	done
	[ $pecl = 1 ] && report NOTE "PECL uploadprogress is present: its progress bars stop working with the guard"
	return 0
}

selinux_fix() {
	command -v restorecon >/dev/null 2>&1 && restorecon -F "$@" >/dev/null 2>&1
	return 0
}

do_install() {
	if [ "$I_VID" -lt 50400 ]; then
		report SKIP "PHP below 5.4 has no php_rfc1867_callback: out of scope"
		return
	fi
	dirs=$(sapi_confdirs) || { report FAIL "no ini scan directory (php --ini reports none)"; return; }
	obtain_so || { report FAIL "no usable binary: ${SO_NOTE:-no matching prebuilt binary and no phpize}"; return; }

	if [ "$DRY" = 1 ]; then
		report WOULD "install $SO_HOW .so in $I_EXT, ini in: $(printf '%s' "$dirs" | tr '\n' ' ')"
		uploadprogress_note
		return
	fi

	dest="$I_EXT/rfc1867_guard.so"
	tmp="$I_EXT/.rfc1867_guard.so.$$"
	if ! { cp "$SO_FILE" "$tmp" && chmod 755 "$tmp" && mv -f "$tmp" "$dest"; }; then
		rm -f "$tmp"
		report FAIL "cannot write $dest"
		return
	fi
	for d in $dirs; do
		write_ini "$d" || { remove_inis; report FAIL "cannot write ini in $d"; return; }
	done
	selinux_fix "$dest"

	if ! config_test; then
		remove_inis
		report FAIL "configuration test failed, ini removed: $REASON"
		return
	fi
	if ! reload_services; then
		remove_inis
		reload_services >/dev/null 2>&1
		report FAIL "service not active after reload, ini removed and unit restarted:$RELOADED"
		return
	fi
	if ! prove_maps want; then
		report FAIL "$PROOF"
		return
	fi
	cli=$("$I_BIN" -r "$CLI_PROBE" 2>&1 </dev/null)
	[ "$cli" = 1 ] || { report FAIL "php CLI does not report the guard active: $cli"; return; }
	case $I_BIN in /opt/alt/*) ALT_TOUCHED=1 ;; esac
	report OK "guard installed ($SO_HOW); reloaded:${RELOADED:- nothing running}; $PROOF"
	uploadprogress_note
}

do_check() {
	if [ "$I_VID" -lt 50400 ]; then
		report SKIP "PHP below 5.4 has no php_rfc1867_callback: out of scope"
		return
	fi
	[ -f "$I_EXT/rfc1867_guard.so" ] || { report UNGUARDED "extension file missing in $I_EXT"; return; }
	missing=""
	for d in $(sapi_confdirs); do
		grep -qs '^extension=rfc1867_guard' "$d/rfc1867_guard.ini" || missing="$missing $d"
	done
	[ -z "$missing" ] || { report UNGUARDED "ini missing in:$missing"; return; }
	cli=$("$I_BIN" -r "$CLI_PROBE" 2>&1 </dev/null)
	[ "$cli" = 1 ] || { report UNGUARDED "php CLI does not report the guard active: $cli"; return; }
	if ! prove_maps want; then
		report UNGUARDED "$PROOF: reload needed"
		return
	fi
	report OK "guarded; $PROOF"
	uploadprogress_note
}

do_uninstall() {
	if [ "$DRY" = 1 ]; then
		report WOULD "remove rfc1867_guard.ini from $(sapi_confdirs | tr '\n' ' ') and $I_EXT/rfc1867_guard.so"
		return
	fi
	remove_inis
	rm -f "$I_EXT/rfc1867_guard.so"
	if ! config_test; then
		report FAIL "configuration test failed after removal: $REASON"
		return
	fi
	if ! reload_services; then
		report FAIL "service not active after reload:$RELOADED"
		return
	fi
	prove_maps gone || { report FAIL "$PROOF (guard still mapped)"; return; }
	case $I_BIN in /opt/alt/*) ALT_TOUCHED=1 ;; esac
	report OK "guard removed; reloaded:${RELOADED:- nothing running}"
}

# ---------------------------------------------------------------- main

if [ -n "$ONLY" ]; then
	only_binary >"$TMP/cands"
	[ -s "$TMP/cands" ] || { echo "no php binary found for --only $ONLY" >&2; exit 1; }
else
	candidates >"$TMP/cands"
fi

: >"$TMP/seen"
found=0
while read -r cand <&3; do
	introspect "$cand" || continue
	key="$I_VER|$I_EXT|$I_SCAN"
	grep -qxF "$key" "$TMP/seen" && continue
	printf '%s\n' "$key" >>"$TMP/seen"
	found=$((found + 1))
	case $MODE in
	install) do_install ;;
	check) do_check ;;
	uninstall) do_uninstall ;;
	esac
done 3<"$TMP/cands"

if [ "$found" = 0 ]; then
	echo "no PHP installation found" >&2
	exit 1
fi

# CloudLinux with CageFS: user processes see a copy of /opt/alt, refreshed by the selector setup.
if [ "$ALT_TOUCHED" = 1 ] && command -v cagefsctl >/dev/null 2>&1; then
	if cagefsctl --setup-cl-selector >/dev/null 2>&1; then
		echo "NOTE     cagefsctl --setup-cl-selector done"
	else
		echo "FAIL     cagefsctl --setup-cl-selector failed"
		BAD=1
	fi
fi

echo "$found installation(s), $([ "$BAD" = 0 ] && echo 'all good' || echo 'problems found')"
exit "$BAD"
