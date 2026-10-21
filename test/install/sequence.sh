#!/bin/sh
# Shared sequence of the install.sh tests, run inside a container where the PHP services are
# already started. Every step has an expected exit code.
#
#   sequence.sh <extra install.sh option for the install step, or "-">
set -u

cd /repo || exit 1
extra=${1:--}
fail=0

step() { # expected-rc description command...
	want=$1
	desc=$2
	shift 2
	out=$("$@" 2>&1)
	rc=$?
	if [ "$rc" = "$want" ]; then
		echo "ok   $desc (rc=$rc)"
	else
		echo "FAIL $desc (rc=$rc, expected $want)"
		fail=1
	fi
	printf '%s\n' "$out" | sed 's/^/     /'
}

step 1 "check before install reports unguarded" sh install.sh --check
step 0 "dry-run" sh install.sh --dry-run
if [ "$extra" = - ]; then
	step 0 "install" sh install.sh
else
	step 0 "install $extra" sh install.sh "$extra"
fi
step 0 "check after install" sh install.sh --check
step 0 "install again (idempotent)" sh install.sh
step 0 "uninstall" sh install.sh --uninstall
step 1 "check after uninstall reports unguarded" sh install.sh --check

exit "$fail"
