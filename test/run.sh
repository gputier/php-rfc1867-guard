#!/usr/bin/env bash
# Functional test of the built extensions, one container per case. Needs dist/ from build.sh.
#
#   test/run.sh [minor ...]     default: every minor listed in dist/BUILDINFO
#
# Per minor: built-in server (cli) without the guard, then with it. For 7.4 and 8.3 also a real
# FastCGI request against php-fpm, without and with the guard.
# Prints a table (minor, SAPI, guard, result) and exits 1 if any case failed.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

PLATFORM=linux/amd64
FPM_MINORS="7.4 8.3"
CURRENT=""
export COPYFILE_DISABLE=1

# shellcheck disable=SC2329
cleanup() {
	if [ -n "$CURRENT" ]; then
		docker rm -f "$CURRENT" >/dev/null 2>&1 || true
	fi
}
trap cleanup EXIT

image_of() { # minor sapi
	if [ "$2" = fpm ]; then
		echo "php:$1-fpm@$(awk -v m="$1-fpm" '$1 == m { print $2 }' build/images.lock)"
	else
		awk -v m="$1" '$1 == m { print $5 }' dist/BUILDINFO
	fi
}

run_case() { # minor sapi guard
	local minor=$1 sapi=$2 guard=$3 image stage log
	image=$(image_of "$minor" "$sapi")
	stage=".build/test-stage/$minor"
	log=".build/test-logs/$minor-$sapi-$guard.log"
	mkdir -p "$stage" ".build/test-logs"
	cp -R test/. "$stage/"
	cp "dist/rfc1867_guard-${minor}-nts-x86_64.so" "$stage/rfc1867_guard.so"

	CURRENT="r1867-test-${minor}-${sapi}-${guard}"
	if tar cf - -C "$stage" . \
		| docker run --rm -i --platform "$PLATFORM" --name "$CURRENT" "$image" \
			sh -c "mkdir /test && tar xf - -C /test && sh /test/inside.sh $sapi $guard" >"$log" 2>&1; then
		result=PASS
	else
		result=FAIL
	fi
	CURRENT=""
	printf '| %s | %s | %s | %s |\n' "$minor" "$sapi" "$guard" "$result"
	[ "$result" = PASS ]
}

minors=("$@")
if [ ${#minors[@]} -eq 0 ]; then
	read -r -a minors <<< "$(awk '!/^#/ && NF == 5 { printf "%s ", $1 }' dist/BUILDINFO)"
fi

failed=0
echo '| PHP | SAPI | guard | result |'
echo '|---|---|---|---|'
for minor in "${minors[@]}"; do
	run_case "$minor" cli off || failed=1
	run_case "$minor" cli on || failed=1
	case " $FPM_MINORS " in
	*" $minor "*)
		run_case "$minor" fpm off || failed=1
		run_case "$minor" fpm on || failed=1
		;;
	esac
done
exit "$failed"
