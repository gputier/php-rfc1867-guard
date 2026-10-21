#!/usr/bin/env bash
# Tests install.sh in containers: debian:12 + Sury, almalinux:9 + Remi, php:8.3-fpm.
# Each container gets the repository through a tar stream (no bind mount). Logs: .build/install-logs/.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

PLATFORM=linux/amd64
CURRENT=""
export COPYFILE_DISABLE=1

# shellcheck disable=SC2329
cleanup() {
	if [ -n "$CURRENT" ]; then
		docker rm -f "$CURRENT" >/dev/null 2>&1 || true
	fi
}
trap cleanup EXIT

run_case() { # name image script
	local name=$1 image=$2 script=$3 log=".build/install-logs/$1.log"
	mkdir -p .build/install-logs
	CURRENT="r1867-inst-$name"
	if tar cf - --exclude=.git --exclude=.build --exclude=.work . \
		| docker run --rm -i --platform "$PLATFORM" --name "$CURRENT" "$image" \
			sh -c "mkdir /repo && tar xf - -C /repo && sh /repo/test/install/$script" >"$log" 2>&1; then
		echo "| $name | $image | PASS |"
	else
		echo "| $name | $image | FAIL (see $log) |"
		CURRENT=""
		return 1
	fi
	CURRENT=""
}

failed=0
echo '| case | image | result |'
echo '|---|---|---|'
run_case official php:8.3-fpm official.sh || failed=1
run_case debian debian:12 debian.sh || failed=1
run_case alma almalinux:9 alma.sh || failed=1
exit "$failed"
