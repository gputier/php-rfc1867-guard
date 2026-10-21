#!/usr/bin/env bash
# Builds rfc1867_guard for every supported PHP minor (NTS, linux/amd64) in Docker containers.
#
#   ./build.sh [minor ...]     default: all minors listed below
#
# Output: dist/rfc1867_guard-<minor>-nts-x86_64.so, dist/BUILDINFO, dist/SHA256SUMS.
#
# Minors 5.6 to 8.5 use the official php:<minor>-cli images, pinned by digest in build/images.lock.
# php:5.4-cli and php:5.5-cli cannot be used: the registry serves a schema v1 manifest for 5.4
# (rejected by containerd 2.1+) and 5.5 has a missing layer. These two minors are compiled from the
# official release tarballs listed in build/sources.lock, on top of php:5.6-cli (Debian 9, gcc/make).
#
# The build fails if a .so imports a glibc symbol above GLIBC_2.17 (checked in build/in-container.sh).
# Containers get the code through a tar stream: no bind mount.
set -euo pipefail

cd "$(dirname "$0")"

ALL_MINORS="5.4 5.5 5.6 7.0 7.1 7.2 7.3 7.4 8.0 8.1 8.2 8.3 8.4 8.5"
PLATFORM=linux/amd64
MODULE_VERSION=$(sed -n 's/^#define RFC1867_GUARD_VERSION "\(.*\)"/\1/p' src/rfc1867_guard.c)
CURRENT=""

export COPYFILE_DISABLE=1

cleanup() {
	if [ -n "$CURRENT" ]; then
		docker rm -f "$CURRENT" >/dev/null 2>&1 || true
	fi
}
trap cleanup EXIT

lock_field() { # file minor field-number
	awk -v m="$2" -v f="$3" '$1 == m { print $f }' "$1"
}

# Prints the image reference to build with; compiles PHP from source first when the minor needs it.
resolve_image() {
	local minor=$1 digest release sha url
	digest=$(lock_field build/images.lock "$minor" 2)
	if [ -n "$digest" ]; then
		echo "php:${minor}-cli@${digest}"
		return
	fi

	release=$(lock_field build/sources.lock "$minor" 2)
	sha=$(lock_field build/sources.lock "$minor" 3)
	url=$(lock_field build/sources.lock "$minor" 4)
	[ -n "$release" ] || { echo "no image digest nor source for $minor" >&2; return 1; }

	local tarball=".build/src/php-${release}.tar.bz2" base ctx=".build/ctx-$minor"
	mkdir -p .build/src "$ctx"
	if [ ! -f "$tarball" ]; then
		curl -fsSL -o "$tarball" "$url"
	fi
	echo "${sha}  ${tarball}" | shasum -a 256 -c - >&2 || return 1

	base="php:5.6-cli@$(lock_field build/images.lock 5.6 2)"
	cp build/Dockerfile.php-src "$ctx/Dockerfile"
	cp "$tarball" "$ctx/"
	tar cf - -C "$ctx" . | docker build --platform "$PLATFORM" -q \
		--build-arg "BASE=$base" --build-arg "PHP_VERSION=$release" \
		-t "r1867-php:${minor}" - >&2 || return 1
	echo "r1867-php:${minor}"
}

build_one() {
	local minor=$1 image out
	image=$(resolve_image "$minor") || exit 1
	out=".build/out/$minor"
	mkdir -p "$out"
	CURRENT="r1867-build-${minor}"

	echo "== PHP $minor ($image)" >&2
	# Under qemu emulation (Apple silicon) cc1 segfaults at random: retry, a real error repeats.
	local attempt
	for attempt in 1 2 3; do
		if tar cf - src build/in-container.sh \
			| docker run --rm -i --platform "$PLATFORM" --name "$CURRENT" "$image" \
				sh -c 'mkdir /work && tar xf - -C /work && sh /work/build/in-container.sh' \
			| tar xf - -C "$out"; then
			break
		fi
		[ "$attempt" -lt 3 ] || exit 1
		echo "attempt $attempt failed, retrying" >&2
	done
	CURRENT=""

	cp "$out/rfc1867_guard.so" "dist/rfc1867_guard-${minor}-nts-x86_64.so"
	mkdir -p .build/rows
	# shellcheck disable=SC1090,SC1091,SC2154
	( ."$out/info"; printf '%s %s %s %s %s\n' "$minor" "$php_version" "$build_id" "$glibc_max" "$image" ) > ".build/rows/$minor"
}

minors=("$@")
[ ${#minors[@]} -gt 0 ] || read -r -a minors <<< "$ALL_MINORS"

mkdir -p dist .build/rows
for minor in "${minors[@]}"; do
	build_one "$minor"
done

# BUILDINFO covers every minor built so far, so a partial run keeps the others.
{
	echo "rfc1867_guard ${MODULE_VERSION}"
	echo "# minor  php_version  build_id  max_glibc_symbol  image"
	cat .build/rows/* | sort -V
} > dist/BUILDINFO

( cd dist && shasum -a 256 -- *.so > SHA256SUMS )
echo "done: $(wc -l < dist/SHA256SUMS | tr -d ' ') binaries in dist/" >&2
