#!/bin/sh
# php:8.3-fpm official image (PHP under /usr/local), FPM started.
set -eu

php-fpm -D
sleep 2

sh /repo/test/install/sequence.sh -
