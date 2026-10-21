#!/bin/sh
# Runs inside the PHP container: builds the extension from /work/src and writes a tar
# stream (the .so and an "info" file) on stdout. Everything else goes to stderr.
set -eu
export LC_ALL=C

MAX_GLIBC=2.17

for tool in phpize gcc make objdump strip; do
	command -v "$tool" >/dev/null 2>&1 || { echo "missing tool: $tool" >&2; exit 1; }
done

cd /work/src
phpize >&2
./configure --enable-rfc1867_guard CFLAGS="-O2 -Wall -Wextra -Wno-unused-parameter" >&2
make >/tmp/make.log 2>&1 || { cat /tmp/make.log >&2; exit 1; }
cat /tmp/make.log >&2
if grep -q 'warning:' /tmp/make.log; then
	echo "compiler warnings" >&2
	exit 1
fi

so=modules/rfc1867_guard.so
strip --strip-unneeded "$so"

objdump -f "$so" | grep -q 'elf64-x86-64' || { echo "not an x86-64 ELF" >&2; exit 1; }

glibc=$(objdump -T "$so" | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/^GLIBC_//' | sort -V | tail -n 1 || true)
if [ -n "$glibc" ]; then
	highest=$(printf '%s\n%s\n' "$glibc" "$MAX_GLIBC" | sort -V | tail -n 1)
	if [ "$highest" != "$MAX_GLIBC" ]; then
		echo "imports GLIBC_$glibc, above GLIBC_$MAX_GLIBC" >&2
		exit 1
	fi
fi

printf 'php_version=%s\nbuild_id=%s\nglibc_max=%s\n' \
	"$(php -r 'echo PHP_VERSION;')" "$(php -i | sed -n 's/^PHP Extension Build => //p')" "${glibc:-none}" > /tmp/info

tar cf - -C modules rfc1867_guard.so -C /tmp info
