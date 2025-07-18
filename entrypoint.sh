#!/bin/sh
[ "${DEBUG:-0}" = "1" ] && set -x

echo "$0: Running as: $(id -un) ($(id -u))"
echo ""

# Set PHP-FPM defaults at runtime
if [ "${ENV:-}" = "production" ] ; then
     cp -f /usr/lib/php/${PHP_VER}/php.ini-production /etc/php/${PHP_VER}/fpm/php.ini
fi

# Set PHP-FPM log level at runtime
PHP_FPM_LOGLEVEL="${PHP_FPM_LOGLEVEL:-notice}"
# sed -i -e "s/log_level.*/log_level = $PHP_FPM_LOGLEVEL/g" /etc/php/${PHP_VER}/fpm/php-fpm.conf

# Modify the UID and GID of the runtime user (if they changed at runtime)
OLDUID=$(id -u $RUNTIME_USER)
OLDGID=$(id -g $RUNTIME_USER)
if [ ! "$OLDUID" = "$RUNTIME_UID" ] || [ ! "$OLDGID" = "$RUNTIME_GID" ] ; then
    usermod -u $RUNTIME_UID $RUNTIME_USER
    groupmod -g $RUNTIME_GID $RUNTIME_USER
    echo "$0: Please wait, changing filesystem ownership (this will take a while)..."
    find /var/ /run/ -uid $OLDUID -exec chown -hR $RUNTIME_USER:$RUNTIME_GID {} \;
    chown -hR $RUNTIME_USER:$(id -g $RUNTIME_USER) /app/
fi

chown $RUNTIME_USER:$RUNTIME_GROUP /proc/self/fd/*

exec sudo -H -E -u $RUNTIME_USER -s /bin/bash "$@"