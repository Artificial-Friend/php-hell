#!/usr/bin/env bash
# Start PHP-FPM and Apache in the Docker container
#
# Set PHP_VER and PHP_APP_DIR in your Docker container's ENV settings.
#
[ "${DEBUG:-0}" = "1" ] && set -x
set -eu

_cmd_start-php () {
    # FIX: Construct the correct binary name for Alpine (e.g., 'php-fpm83' from '8.3')
    local PHP_FPM_BIN="php-fpm$(echo ${PHP_VER} | tr -d '.')"
    echo "$0: Running: /usr/sbin/${PHP_FPM_BIN} in ${PHP_APP_DIR}"
    ( cd ${PHP_APP_DIR} && /usr/sbin/${PHP_FPM_BIN} -F ) &
}
_cmd_start-apache () {
    echo "$0: Running: httpd -D FOREGROUND & "
    httpd -D FOREGROUND &
}

# FIX: Start PHP-FPM first, wait for its socket, then start Apache.
# This prevents a race condition where Apache starts before PHP-FPM is ready.
_cmd_start () {
    # Start PHP-FPM in the background
    _cmd_start-php

    # Wait for the PHP-FPM socket to be created before starting Apache
    echo "$0: Waiting for PHP-FPM socket to be created at /run/php/php-fpm.sock..."
    while [ ! -e /run/php/php-fpm.sock ] ; do
        # Output a dot to show we are waiting
        echo -n "."
        sleep 0.1
    done
    echo "" # Newline after the dots
    echo "$0: PHP-FPM socket found. Starting Apache."

    # Now that PHP-FPM is ready, start Apache in the background
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