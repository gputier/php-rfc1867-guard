#!/bin/sh
# almalinux:9 with Remi: PHP 7.4 and 8.3 (FPM), both started. The 8.3 install is forced through phpize.
set -eu

dnf install -y -q epel-release https://rpms.remirepo.net/enterprise/remi-release-9.rpm >/dev/null
dnf install -y -q php74-php-fpm php74-php-cli php83-php-fpm php83-php-cli php83-php-devel gcc make procps-ng >/dev/null

mkdir -p /run/php
/opt/remi/php74/root/usr/sbin/php-fpm -D
/opt/remi/php83/root/usr/sbin/php-fpm -D
sleep 2

sh /repo/test/install/sequence.sh -
echo "--- forced build on the 8.3 installation"
sh /repo/install.sh --build --only /opt/remi/php83 || exit 1
sh /repo/install.sh --check --only /opt/remi/php83 || exit 1
