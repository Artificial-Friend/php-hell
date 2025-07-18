#!/usr/bin/env bash
# Start PHP-FPM and Apache in the Docker container
#
# Set PHP_VER and PHP_APP_DIR in your Docker container's ENV settings.
#
[ "${DEBUG:-0}" = "1" ] && set -x
set -eu

_cmd_start-php () {
    echo "$0: Running: /usr/sbin/php-fpm${PHP_VER} in ${PHP_APP_DIR}"
    ( cd ${PHP_APP_DIR} && /usr/sbin/php-fpm${PHP_VER} -F ) &
}
_cmd_start-apache () {
    echo "$0: Running: httpd -D FOREGROUND "
    exec httpd -D FOREGROUND 
}
_cmd_start () {
    _cmd_start-php
    _cmd_start-apache
}

# default command
CMD="start"

if [ "${1:-}" = "--help" ] ; then
    cat <<EOUSAGE
Usage: $0 [CMD]
Runs a command, and waits for any background process to exit.

Commands:
  start                 Start PHP-FPM and Apache
  start-php             Start PHP-FPM
  start-apache          Start Apache
EOUSAGE
    exit 1
fi

if [ $# -gt 0 ] ; then
    CMD="$1"; shift
fi
_cmd_"$CMD"

# Wait for any background process to die
wait -n
