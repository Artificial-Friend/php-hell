FROM alpine:3.22.1 AS php83

ENV PHP_VER=83
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
ENV PHP_VER=83
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

# Create and permission the log directory that the default httpd.conf requires.
# This allows the httpd process to start successfully.
RUN mkdir -p /var/www/logs && chown -R www-data:www-data /var/www

# This is mostly for calling /usr/sbin/php83-fpm and its sub-processes
ENV PATH=$PATH:/sbin:/usr/sbin:/usr/local/sbin

RUN rm -f /etc/apache2/conf.d/*.conf && \
    sed -i \
        -e 's/^Listen 80/Listen 8080/' \
        -e 's/^User .*/User www-data/' \
        -e 's/^Group .*/Group www-data/' \
        -e 's#^DocumentRoot ".*"#DocumentRoot "/app/web"#' \
        -e 's#<Directory "/var/www/localhost/htdocs">#<Directory "/app/web">#' \
        -e '/<Directory "\/app\/web">/,/<\/Directory>/ s/AllowOverride None/AllowOverride All/' \
        -e 's/DirectoryIndex index.html/DirectoryIndex index.php index.html/' \
        /etc/apache2/httpd.conf && \
    echo -e "LoadModule rewrite_module modules/mod_rewrite.so\nLoadModule proxy_module modules/mod_proxy.so\nLoadModule proxy_fcgi_module modules/mod_proxy_fcgi.so" > /etc/apache2/conf.d/modules.conf && \
    echo -e '<FilesMatch \.php$>\n    SetHandler "proxy:unix:/run/php/php-fpm.sock|fcgi://localhost/"\n</FilesMatch>' > /etc/apache2/conf.d/php-fpm.conf && \
    sed -i \
        -e 's/^user = .*/user = www-data/' \
        -e 's/^group = .*/group = www-data/' \
        -e 's#^listen = .*#listen = /run/php/php83-fpm.sock#' \
        -e 's/^;listen.owner = .*/listen.owner = www-data/' \
        -e 's/^;listen.group = .*/listen.group = www-data/' \
        -e 's/^;listen.mode = .*/listen.mode = 0660/' \
        /etc/php83/php-fpm.d/www.conf && \
    chmod -R 775 /run/php

# Ensure PHP-FPM can start by redirecting logs to stderr.
RUN sed -i 's#^;*error_log = .*#error_log = /proc/self/fd/2#' /etc/php83/php-fpm.conf && \
    sed -i 's#^;catch_workers_output = yes#catch_workers_output = yes#' /etc/php83/php-fpm.d/www.conf

# add the user to the tty group so it can write to /dev/pts/0
RUN set -eux ; usermod -aG tty ${RUNTIME_USER}

# used by Bedrock
ARG WP_ENV=development
ENV WP_ENV=$WP_ENV

EXPOSE 8080
EXPOSE 8443

STOPSIGNAL SIGQUIT

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY apache-wordpress.sh /usr/local/bin/apache-wordpress.sh

RUN chmod +x /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/apache-wordpress.sh

CMD [ "/usr/local/bin/apache-wordpress.sh" ]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]

HEALTHCHECK --interval=10s --timeout=30s --retries=3 CMD curl -iLf http://localhost:8080/ || exit 1