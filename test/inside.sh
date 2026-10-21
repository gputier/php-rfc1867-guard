#!/bin/sh
# Runs inside the PHP container, with /test holding this directory and the .so.
#
#   inside.sh cli|fpm on|off
#
# Starts the SAPI (built-in server or php-fpm) with session.upload_progress forced on,
# with or without the guard, and runs the client against it.
set -eu

sapi=$1
guard=$2

ini="-d session.upload_progress.enabled=1 -d session.upload_progress.cleanup=0 -d session.save_path=/tmp -d display_errors=1 -d error_reporting=-1"
expect=unguarded
if [ "$guard" = on ]; then
	ini="$ini -d extension=/test/rfc1867_guard.so"
	expect=guarded
fi

chmod -R a+rX /test
cd /test

if [ "$sapi" = fpm ]; then
	# shellcheck disable=SC2086
	php-fpm -F $ini >/tmp/server.log 2>&1 &
	port=9000
	mode=fcgi
else
	# shellcheck disable=SC2086
	php -S 127.0.0.1:8080 -t /test/www $ini >/tmp/server.log 2>&1 &
	port=8080
	mode=http
fi
server=$!
trap 'kill $server 2>/dev/null || true' EXIT

status=0
php client.php "$mode" 127.0.0.1 "$port" "$expect" || status=$?
if [ "$status" -ne 0 ]; then
	echo "--- server log" >&2
	cat /tmp/server.log >&2
fi
exit "$status"
