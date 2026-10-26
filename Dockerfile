# The image of moncycle.app: the API (named context "backend", its www_data/) and the web app (named context "webapp"), built by
# build.sh, which stages the two source trees and gives the commits and the date as build arguments:
#   docker buildx build --build-context backend=DIR --build-context webapp=DIR --build-arg BACKEND_COMMIT=... .
# The versions are checked first: the build fails when the backend is out of the range of generations the web app declares.

# The web app: dependencies from npm (package-lock.json), vendored dist files, the compatibility check against the backend's
# APP_VERSION, version.json stamped with the build. Only src/ leaves this stage.
FROM --platform=$BUILDPLATFORM node:24-alpine AS webapp_build
ARG WEBAPP_COMMIT=unknown
ARG BUILD_DATE=unknown
WORKDIR /webapp
COPY --from=webapp package.json package-lock.json ./
COPY --from=webapp scripts ./scripts
COPY --from=webapp src ./src
COPY --from=backend www_data/constants.php /backend/constants.php
RUN npm ci --no-audit --no-fund \
	&& node scripts/check_api_compat.mjs /backend/constants.php \
	&& node scripts/stamp_version.mjs src/version.json "$BUILD_DATE" "$WEBAPP_COMMIT"

FROM php:8.4-apache

RUN apt-get update \
	&& apt-get install -y --no-install-recommends libfreetype6-dev libjpeg62-turbo-dev libpng-dev unzip \
	&& rm -rf /var/lib/apt/lists/*

RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
	&& docker-php-ext-install -j$(nproc) gd pdo pdo_mysql opcache

# headers: security and cache headers. rewrite: the 413 on the Content-Length of a request (zz-moncycleapp.conf).
# The others serve nothing here (/server-status shows request URLs)
RUN a2enmod headers rewrite \
	&& a2dismod -f status autoindex auth_basic authn_file authz_user access_compat env setenvif \
	&& a2disconf -q serve-cgi-bin localized-error-pages \
	&& rm -f "$PHP_INI_DIR/conf.d/docker-php-ext-sodium.ini"

# no Apache access log: the app writes its own (lib/log.php, docs/logs.md), whose `http.request` line
# has no query string, where this one has `DELETE /api/v2/totp?code=<TOTP code>` and the dates of a read.
# ErrorLog stays (stderr). The build fails if a CustomLog directive is left (apache2.conf has a comment that names it).
RUN sed -i '/CustomLog/d' /etc/apache2/sites-available/*.conf /etc/apache2/conf-available/*.conf \
	&& a2disconf -q other-vhosts-access-log \
	&& ! grep -rnE '^[[:space:]]*CustomLog' /etc/apache2

# the scheduler of the daily job (CRON_ENABLED, server_conf/moncycle.crontab). supercronic is one static binary: unlike
# the system cron it has no daemon, pid file or spool to write, so it runs in a read-only container, as the web user,
# with the environment of the container (the DB settings the job needs). Pinned and checked by its hash.
RUN arch="$(dpkg --print-architecture)" \
	&& case "$arch" in \
		amd64) sha256=a53ae236602c7338aba3fbaff40bda6300eae3b9fedb8261eb06cfe3724430c1 ;; \
		arm64) sha256=02aa0cb229ba09050cba6638059dadb9eedc2276632ea43d6a57a2f8c1629dd5 ;; \
		*) echo "no supercronic build for $arch" >&2; exit 1 ;; \
	esac \
	&& curl -fsSL -o /usr/local/bin/supercronic "https://github.com/aptible/supercronic/releases/download/v0.2.49/supercronic-linux-$arch" \
	&& echo "$sha256  /usr/local/bin/supercronic" | sha256sum -c - \
	&& chmod 755 /usr/local/bin/supercronic

# prod is the default (php.ini-production); dev is opt-in through dev.env, see server_conf/moncycleapp_php.ini
RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

# No ENV here: the settings come from the container's environment or from config.php (config.docker.php, README "Settings"), and the
# entrypoint gives the few it needs for Apache their defaults (APP_SCRIPT_ALLOW, CSP_FRAME_SRC, CSP_CONNECT_SRC; CRON_ENABLED is on unless set off).

COPY --from=composer/composer:latest-bin /composer /usr/bin/composer
COPY ./server_conf/zz-moncycleapp.conf /etc/apache2/conf-enabled/zz-moncycleapp.conf
COPY --from=backend www_data /var/www/html/
COPY --from=backend www_data/config.docker.php /var/www/html/config.php
COPY --from=webapp_build /webapp/src /var/www/webapp/

# APP_COMMIT (constants.php): 8 hex digits or "unknown", and the build fails if the line is gone.
ARG BACKEND_COMMIT=unknown
RUN case "$BACKEND_COMMIT" in unknown|[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) echo "BACKEND_COMMIT: 8 hex digits or unknown" >&2; exit 1 ;; esac \
	&& sed -i "s/^const APP_COMMIT = \"dev\";/const APP_COMMIT = \"$BACKEND_COMMIT\";/" /var/www/html/constants.php \
	&& grep -q "^const APP_COMMIT = \"$BACKEND_COMMIT\";" /var/www/html/constants.php

# The web app is the document root (the pages, config.json, version.json); the API, the Swagger UI and the scripts stay in
# /var/www/html and are reached by the Alias lines of zz-moncycleapp.conf. Nothing in the web app runs as PHP.
RUN sed -i 's#DocumentRoot /var/www/html#DocumentRoot /var/www/webapp#' /etc/apache2/sites-available/000-default.conf \
	&& grep -q 'DocumentRoot /var/www/webapp' /etc/apache2/sites-available/000-default.conf

# dependencies from composer.lock; the code is root-owned and not writable: the app never writes to disk
RUN cd /var/www/html \
	&& COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --prefer-dist --no-interaction --optimize-autoloader --classmap-authoritative \
	&& composer clear-cache \
	&& chown -R root:root /var/www/html /var/www/webapp \
	&& chmod -R a+rX,go-w /var/www/html /var/www/webapp

# where LOG_OUTPUT can point a file of the app log (open_basedir allows this directory only). Owned by the web
# user so that a named volume mounted here inherits it; a bind mount takes the host directory's owner (chown 33:33).
RUN mkdir -p /var/log/moncycle \
	&& chown www-data:www-data /var/log/moncycle \
	&& chmod 750 /var/log/moncycle

# the entrypoint makes the schema on a first launch, upgrades an older database and starts the scheduler, then hands over to Apache
COPY ./server_conf/moncycle.crontab /etc/moncycle.crontab
COPY ./server_conf/moncycle-demo.crontab /etc/moncycle-demo.crontab
COPY ./server_conf/docker-entrypoint.sh /usr/local/bin/moncycle-entrypoint
RUN chmod 644 /etc/moncycle.crontab /etc/moncycle-demo.crontab \
	&& chmod 755 /usr/local/bin/moncycle-entrypoint
ENTRYPOINT ["moncycle-entrypoint"]
# an ENTRYPOINT here drops the CMD of the php image
CMD ["apache2-foreground"]

# last: composer needs the functions that this file disables
COPY ./server_conf/moncycleapp_php.ini $PHP_INI_DIR/conf.d

ARG BACKEND_VERSION=unknown
ARG WEBAPP_VERSION=unknown
ARG BACKEND_COMMIT
ARG WEBAPP_COMMIT
LABEL org.opencontainers.image.title="moncycle.app" \
	org.opencontainers.image.licenses="AGPL-3.0-or-later" \
	app.moncycle.backend.version="$BACKEND_VERSION" \
	app.moncycle.backend.commit="$BACKEND_COMMIT" \
	app.moncycle.webapp.version="$WEBAPP_VERSION" \
	app.moncycle.webapp.commit="$WEBAPP_COMMIT"
