FROM alpine:3.22.1 AS php83

ENV PHP_VER=8.3
ENV RUNTIME_USER=www-data
ENV RUNTIME_GROUP=www-data
# Alpine www-data UID/GID is 82
ARG RUNTIME_UID=82
ENV RUNTIME_UID=$RUNTIME_UID
ARG RUNTIME_GID=82
ENV RUNTIME_GID=$RUNTIME_GID


RUN apk add -u --no-cache aws-cli bash curl ca-certificates jq sudo tini shadow ; \
    [ -e /usr/bin/tini ] || ln -sf /sbin/tini /usr/bin/tini

# install the PHP extensions we need
#  - https://make.wordpress.org/hosting/handbook/handbook/server-environment/#php-extensions)
#  - https://wiki.alpinelinux.org/wiki/WordPress
RUN set -eux; \
    apk add -u --no-cache \
        php83 php83-fpm php83-common php83-session php83-iconv php83-json php83-gd php83-curl php83-xml php83-mysqli php83-imap php83-cgi \
        php83-pdo php83-pdo_mysql php83-soap php83-posix php83-gettext php83-ldap php83-ctype php83-dom \
        php83-mbstring php83-zip php83-pecl-imagick php83-pecl-ssh2 php83-intl php83-phar php83-tokenizer php83-xmlwriter php83-simplexml \
        libxml2 fcgi wget curl mysql-client ghostscript gnupg openssl ; \
    getent group www-data   || addgroup -g ${RUNTIME_GID} -S www-data ; \
    getent passwd www-data  || adduser -u ${RUNTIME_UID} -D -S -G www-data www-data ; \
    mkdir -p /run/php ; \
    chown -R ${RUNTIME_USER}:${RUNTIME_GROUP} /run/php ; \
# Create a symlink to this Unix socket so we don't have to write configs against a single version
    ln -sf /run/php/php${PHP_VER}-fpm.sock /run/php/php-fpm.sock ; \
    ln -sf /run/php/php${PHP_VER}-fpm.pid /run/php/php-fpm.pid

FROM php83 AS php83-apache2

ENV RUNTIME_USER=www-data
ENV RUNTIME_GROUP=www-data

RUN set -eux; \
    apk add -u --no-cache \
        apache2 apache2-proxy apache2-proxy-html apache2-ctl apache2-ssl apr apr-util \
        apr-util-dbd_sqlite3 apr-util-ldap brotli-libs  && \
    mkdir -p /var/run/apache2 /var/log/apache2 /var/lock/apache2 && \
    chown -R ${RUNTIME_USER}:${RUNTIME_GROUP} /var/run/apache2 /var/log/apache2 /var/lock/apache2 && \
# Add www-data to the ssl-cert group to read the /etc/ssl/private/ keys
    if getent group ssl-cert ; then usermod -aG ssl-cert www-data ; fi && \
    if getent passwd apache ; then usermod -aG www-data apache ; fi

ARG TLS_HOST
ENV TLS_HOST=$TLS_HOST
RUN openssl req \
        -new -newkey rsa:4096 -days 3650 -nodes -x509 \
        -subj "/C=US/ST=City/L=State/O=O/CN=$TLS_HOST" \
        -keyout domain.key -out domain.crt \
    && mv domain.key domain.crt /etc/apache2/

FROM php83 AS php83-bedrock

ENV BEDROCK_DIR=/app

# Download and install composer.phar
RUN set -eux && \
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" && \
    php -r "if (hash_file('sha384', 'composer-setup.php') === 'dac665fdc30fdd8ec78b38b9800061b4150413ff2e3b6f88543c636f7cd84f6db9189d43a81e5503cda447da73c7e5b6') { echo 'Installer verified'; } else { echo 'Installer corrupt'; unlink('composer-setup.php'); } echo PHP_EOL;" && \
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer --version=2.0.8 && \
    php -r "unlink('composer-setup.php');" && \
# Make sure we can write the composer cache as the user
    homedir=`getent passwd ${RUNTIME_USER} | cut -d : -f 6` && \
    mkdir -p $homedir/.composer $homedir/.cache/composer ${BEDROCK_DIR} && \
    chown -R ${RUNTIME_USER}:${RUNTIME_GROUP} $homedir/.composer $homedir/.cache/composer ${BEDROCK_DIR}

# Change to Bedrock dir to copy files and run composer
USER ${RUNTIME_USER}
WORKDIR ${BEDROCK_DIR}
COPY --chown=${RUNTIME_USER}:${RUNTIME_GROUP} composer.json composer.lock ./
RUN set -eux && \
    composer install --no-scripts --no-autoloader && \
    homedir=`getent passwd ${RUNTIME_USER} | cut -d : -f 6` && \
    rm -rf $homedir/.composer/* $homedir/.cache/composer/*

# Then copy anything else which might have invalidated the cache.
# This way dependencies are cached in the step above.
COPY --chown=${RUNTIME_USER}:${RUNTIME_GROUP} wp-cli.yml plugins.txt phpcs.xml ./
COPY --chown=${RUNTIME_USER}:${RUNTIME_GROUP} web web
COPY --chown=${RUNTIME_USER}:${RUNTIME_GROUP} config config
RUN set -eux ; composer dump-autoload --optimize

FROM php83-apache2 AS production-bedrock

ENV BEDROCK_DIR=/app
ENV PHP_VER=8.3
ENV HTTPD_PREFIX=/etc/apache2
ARG HTTPD_LOGLEVEL=debug
ENV HTTPD_LOGLEVEL=$HTTPD_LOGLEVEL
ARG PHP_FPM_LOGLEVEL=notice
ENV PHP_FPM_LOGLEVEL=$PHP_FPM_LOGLEVEL
# This is the Apache2 docroot, so it must end in '/web'.
# The WP_SITEURL must then set to include '/wp'.
# If both are not done, the site will not load correctly.
ENV PHP_APP_DIR=/app/web
ENV PHP_PORT=9000
ENV RUNTIME_USER=www-data
ENV RUNTIME_GROUP=www-data

# Alpine www-data UID/GID is 82
ARG RUNTIME_UID=82
ENV RUNTIME_UID=$RUNTIME_UID
ARG RUNTIME_GID=82
ENV RUNTIME_GID=$RUNTIME_GID

WORKDIR ${BEDROCK_DIR}

COPY --from=php83-bedrock /usr/local/bin/composer /usr/local/bin/composer
COPY --from=php83-bedrock --chown=${RUNTIME_USER}:${RUNTIME_GROUP} ${BEDROCK_DIR} ${BEDROCK_DIR}

USER root

# This is mostly for calling /usr/sbin/php83-fpm and its sub-processes
ENV PATH=$PATH:/sbin:/usr/sbin:/usr/local/sbin

# add the user to the tty group so it can write to /dev/pts/0
# (stdout and stderr are all /dev/pts/0 in docker)
RUN set -eux ; usermod -aG tty ${RUNTIME_USER}

# used by Bedrock
ARG WP_ENV=development
ENV WP_ENV=$WP_ENV

# THIS IS TEMPORARY (in case I do not have my own configuration)
# RUN rm -rf /etc/apache2/*

# Uncomment these to copy Apache and PHP-FPM configuration into the container
#COPY --chown=${RUNTIME_USER}:${RUNTIME_GROUP} .deploy/etc/ /etc/
#COPY --chown=${RUNTIME_USER}:${RUNTIME_GROUP} .deploy/usr/ /usr/

# Gemini said this is too old to be true
#RUN set -eux ; \
#    [ -e /etc/apache2/conf.d/proxy-html.conf ] && sed -i -e 's/libxml2\.so$/libxml2.so.2/' /etc/apache2/conf.d/proxy-html.conf ; \
#    ln -sf /etc/apache2/envvars /usr/sbin/envvars ; \
#    [ ! -e /usr/lib/apache2/modules ] && ln -sf /usr/lib/apache2 /usr/lib/apache2/modules ; \
#    [ ! -e /etc/mime.types ] && ln -sf /etc/apache2/mime.types /etc/mime.types ; \
#    touch /usr/share/apache2/ask-for-passphrase ; \
#    apachectl -t ; \
#    cp -a /etc/php/phpenmod /etc/php/phpdismod /etc/php/phpquery /usr/sbin/ ; \
#    /etc/php/phpenmod `cd /etc/php/${PHP_VER}/mods-available/; ls *.ini | sed -e 's/\.ini//g'` ; \
#    [ ! -e /usr/sbin/php-fpm${PHP_VER} ] && [ -e /usr/sbin/php-fpm7 ] && ln -sf /usr/sbin/php-fpm7 /usr/sbin/php-fpm${PHP_VER} ; \
#    php-fpm${PHP_VER} -t ; \
#    chown ${RUNTIME_USER}:${RUNTIME_GROUP} ${BEDROCK_DIR}
# Note: this command includes a sanity check of apache and php
RUN set -eux ; \
    [ -e /etc/apache2/conf.d/proxy-html.conf ] && sed -i -e 's/libxml2\.so$/libxml2.so.2/' /etc/apache2/conf.d/proxy-html.conf ; \
    ln -sf /etc/apache2/envvars /usr/sbin/envvars ; \
    [ ! -e /usr/lib/apache2/modules ] && ln -sf /usr/lib/apache2 /usr/lib/apache2/modules ; \
    [ ! -e /etc/mime.types ] && ln -sf /etc/apache2/mime.types /etc/mime.types ; \
    touch /usr/share/apache2/ask-for-passphrase ; \
    apachectl -t ; \
    [ ! -e /usr/sbin/php-fpm${PHP_VER} ] && [ -e /usr/sbin/php-fpm83 ] && ln -sf /usr/sbin/php-fpm83 /usr/sbin/php-fpm${PHP_VER} ; \
    php-fpm${PHP_VER} -t ; \
    chown ${RUNTIME_USER}:${RUNTIME_GROUP} ${BEDROCK_DIR}

EXPOSE 8080
EXPOSE 8443

# https://httpd.apache.org/docs/2.4/stopping.html#gracefulstop
#STOPSIGNAL SIGWINCH
STOPSIGNAL SIGQUIT

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY apache-wordpress.sh /usr/local/bin/apache-wordpress.sh

RUN chmod +x /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/apache-wordpress.sh

CMD [ "/usr/local/bin/apache-wordpress.sh" ]

# Look up AWS secrets on start-up
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]

HEALTHCHECK --interval=10s --timeout=30s --retries=3 CMD curl -iLf http://localhost:8080/ || exit 1