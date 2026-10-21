#!/bin/sh
# debian:12 with the Sury repository: PHP 7.4 and 8.3 (FPM), both started.
set -eu

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl lsb-release >/dev/null
curl -fsSL -o /usr/share/keyrings/deb.sury.org-php.gpg https://packages.sury.org/php/apt.gpg
echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" >/etc/apt/sources.list.d/php.list
apt-get update -qq
apt-get install -y -qq php7.4-fpm php7.4-cli php8.3-fpm php8.3-cli >/dev/null

mkdir -p /run/php
php-fpm7.4 -D
php-fpm8.3 -D
sleep 2

sh /repo/test/install/sequence.sh -
