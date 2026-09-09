# syntax=docker/dockerfile:1
ARG PHP_VERSION=8.5
ARG DEBIAN_VERSION=trixie
ARG VARIANT=
# Overridable so CI can point at a per-architecture image by digest.
ARG BASE_IMAGE=ghcr.io/clysec/frankenphp:${PHP_VERSION}-${DEBIAN_VERSION}${VARIANT}

# -----------------------------------------------------------------------------
# init-go: static helper binary run at container start
# -----------------------------------------------------------------------------
FROM golang:1-trixie AS gobuild

WORKDIR /init-go
COPY init-go/go.mod init-go/main.go ./
RUN --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /init-go/init-go main.go

# -----------------------------------------------------------------------------
# builder: complete image including the PHP build toolchain.
# Published as <tag>-builder so downstream images can still run
# install-php-extensions / phpize. Everything below is also what the slim
# runtime is assembled from.
# -----------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS builder

ARG COMPOSER_VERSION=2.10.3
ARG WP_CLI_VERSION=2.12.0

ENV WP_CLI_CACHE_DIR="/tmp/wpcli/cache"             \
    WP_CLI_CONFIG_PATH="/etc/wpcli/wpcli.conf"      \
    WP_CLI_PACKAGES_DIR="/etc/wpcli/packages"       \
    CD_CONFIG="/init-go/config.json"                \
    COMPOSER_HOME="/etc/composer"                   \
    COMPOSER_CACHE_DIR="/tmp/composer-cache"

RUN set -eux; \
    cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"; \
    # The extensions are compiled into the php-zts base (see base/generate.py); fail fast if not.
    for ext in mysqli pdo_mysql gd zip intl imagick apcu; do \
        php -m | grep -qix "$ext" || { echo "PHP extension '$ext' is missing from the base image" >&2; exit 1; }; \
    done; \
    # Create the runtime user before installing packages so nothing else can take uid/gid 101.
    groupadd --system --gid 101 frank; \
    useradd \
        --system \
        -g frank \
        --home /app \
        --no-create-home \
        --comment "frankenpress user" \
        --shell /bin/false \
        --uid 101 \
        frank; \
    apt-get update; \
    apt-get -y install --no-install-recommends \
        git \
        zip \
        unzip \
        mariadb-client \
        nano; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    mkdir -p /app /etc/composer /etc/wpcli/packages; \
    # Composer, verified against the published installer signature
    curl -fsSL -o /tmp/composer-setup.php https://getcomposer.org/installer; \
    echo "$(curl -fsSL https://composer.github.io/installer.sig | awk '{print $1}')  /tmp/composer-setup.php" | sha384sum -c -; \
    php /tmp/composer-setup.php --quiet --install-dir=/usr/local/bin --filename=composer --version="$COMPOSER_VERSION"; \
    # WP-CLI, verified against the published checksum
    curl -fsSL -o /usr/local/bin/wp "https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar"; \
    echo "$(curl -fsSL "https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar.sha512" | awk '{print $1}')  /usr/local/bin/wp" | sha512sum -c -; \
    chmod +x /usr/local/bin/wp; \
    wp --allow-root package install aaemnnosttv/wp-cli-dotenv-command; \
    chown -R frank:frank \
        /app \
        /data/caddy \
        /config/caddy \
        /etc/caddy \
        /etc/frankenphp \
        /etc/wpcli \
        /etc/composer; \
    rm -rf /tmp/* /usr/share/doc/*

COPY php.ini $PHP_INI_DIR/conf.d/wp.ini
COPY opcache.ini $PHP_INI_DIR/conf.d/opcache-recommended.ini
COPY errors.ini $PHP_INI_DIR/conf.d/errors.ini

WORKDIR /app
USER frank

# Set by the nightly "latest" workflow to force a fresh Bedrock/WordPress install.
ARG BEDROCK_CACHE_BUST=
RUN set -eux; \
    echo "bedrock cache bust: ${BEDROCK_CACHE_BUST}"; \
    rm -rf /app/*; \
    composer config --global audit.block-insecure false; \
    composer create-project roots/bedrock --no-interaction --no-dev --prefer-dist --no-progress .; \
    composer update --no-interaction --no-dev --prefer-dist --no-progress roots/wordpress; \
    composer config classmap-authoritative true; \
    composer config apcu-autoloader true; \
    composer dump-autoload --no-dev; \
    cp .env.example .env; \
    composer clear-cache; \
    rm -rf /tmp/composer-cache

# Config last so edits do not invalidate the Bedrock layer above.
COPY --chown=frank:frank Caddyfile /etc/frankenphp/Caddyfile
# Standalone MU plugin is outside Composer-managed package directories.
COPY --chown=frank:frank mu-plugins/frankenpress-security.php /app/web/app/mu-plugins/frankenpress-security.php
COPY --from=gobuild --chown=frank:frank /init-go/init-go /init-go/init-go
COPY --chown=frank:frank init-go/config-sample.json /init-go/config.json

ENV FP_GLOBAL_OPTIONS="" \
    FP_FRANKENPHP_OPTIONS="" \
    FP_EXTRA_CONFIG="" \
    FP_SERVER_NAME="http://localhost:8080" \
    FP_HTTP_PORT="8080" \
    FP_LOG_LEVEL="WARN" \
    FP_SERVER_OPTIONS="" \
    FP_PHP_SERVER_OPTIONS="" \
    FP_MAX_EXECUTION_TIME="600" \
    FP_MAX_INPUT_TIME="600" \
    FP_MAX_WAIT_TIME="30s" \
    FP_TRUSTED_PROXIES="private_ranges" \
    FP_CSP_ENABLED="true" \
    FP_CSP_HEADER="Content-Security-Policy" \
    FP_SECURITY_HEADERS="true" \
    FP_AUTO_HTTPS="off"

CMD ["--config", "/etc/frankenphp/Caddyfile", "--adapter", "caddyfile"]

# -----------------------------------------------------------------------------
# prune: compute the runtime package list and drop build-only files so the
# COPY into the slim runtime stays small. Never published.
# -----------------------------------------------------------------------------
FROM builder AS prune

USER root
RUN set -eux; \
    # Debian packages providing every shared library that PHP, FrankenPHP and
    # the extensions link against (same technique as docker-library/php).
    find /usr/local -type f \( -executable -o -name '*.so' \) -exec ldd '{}' ';' 2>/dev/null \
        | awk '/=>/ { so = $(NF-1); if (index(so, "/usr/local/") == 1) { next }; gsub("^/(usr/)?", "", so); printf "*%s\n", so }' \
        | sort -u \
        | xargs -r dpkg-query --search \
        | awk 'sub(":$", "", $1) { print $1 }' \
        | sort -u > /runtime-deps.txt; \
    cat /runtime-deps.txt; \
    # The runtime serves on an unprivileged port: drop the file capability so the
    # binary can exec under "capabilities: drop: [ALL]" (Pod Security "restricted").
    setcap -r /usr/local/bin/frankenphp; \
    cd /usr/local; \
    rm -rf \
        bin/php-cgi bin/phpdbg bin/phpize bin/php-config bin/pecl bin/pear bin/peardev \
        bin/phar bin/phar.phar bin/install-php-extensions bin/docker-php-source \
        bin/docker-php-ext-configure bin/docker-php-ext-install \
        include \
        lib/libwatcher-c.a \
        lib/php/build lib/php/test lib/php/doc lib/php/.registry lib/php/.channels \
        lib/php/.depdb lib/php/.depdblock lib/php/.filemap lib/php/.lock \
        lib/php/PEAR lib/php/PEAR.php lib/php/pearcmd.php lib/php/peclcmd.php \
        etc/pear.conf \
        php \
        lib/python3*

# -----------------------------------------------------------------------------
# runner (default target): slim runtime without compilers or headers.
# -----------------------------------------------------------------------------
FROM debian:${DEBIAN_VERSION}-slim AS runner

ENV PHP_INI_DIR=/usr/local/etc/php \
    XDG_CONFIG_HOME=/config \
    XDG_DATA_HOME=/data \
    GODEBUG=cgocheck=0 \
    WP_CLI_CACHE_DIR="/tmp/wpcli/cache" \
    WP_CLI_CONFIG_PATH="/etc/wpcli/wpcli.conf" \
    WP_CLI_PACKAGES_DIR="/etc/wpcli/packages" \
    CD_CONFIG="/init-go/config.json" \
    COMPOSER_HOME="/etc/composer" \
    COMPOSER_CACHE_DIR="/tmp/composer-cache"

RUN --mount=type=bind,from=prune,source=/runtime-deps.txt,target=/tmp/runtime-deps.txt \
    set -eux; \
    groupadd --system --gid 101 frank; \
    useradd \
        --system \
        -g frank \
        --home /app \
        --no-create-home \
        --comment "frankenpress user" \
        --shell /bin/false \
        --uid 101 \
        frank; \
    apt-get update; \
    # shellcheck disable=SC2046
    apt-get -y install --no-install-recommends \
        $(cat /tmp/runtime-deps.txt) \
        ca-certificates \
        curl \
        mailcap \
        git \
        nano \
        mariadb-client \
        unzip \
        zip; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    mkdir -p /app /config/caddy /data/caddy /etc/caddy /etc/frankenphp /etc/wpcli /etc/composer /init-go; \
    chown -R frank:frank /app /config/caddy /data/caddy /etc/caddy /etc/frankenphp /etc/wpcli /etc/composer /init-go

# PHP, FrankenPHP, extensions, ini files, composer and wp-cli
COPY --from=prune /usr/local /usr/local
RUN ldconfig && \
    php --version && \
    frankenphp version

COPY --from=prune --chown=frank:frank /etc/caddy /etc/caddy
COPY --from=prune --chown=frank:frank /etc/frankenphp /etc/frankenphp
COPY --from=prune --chown=frank:frank /etc/composer /etc/composer
COPY --from=prune --chown=frank:frank /etc/wpcli /etc/wpcli
COPY --from=prune --chown=frank:frank /app /app
COPY --from=gobuild --chown=frank:frank /init-go/init-go /init-go/init-go
COPY --chown=frank:frank init-go/config-sample.json /init-go/config.json

ENV FP_GLOBAL_OPTIONS="" \
    FP_FRANKENPHP_OPTIONS="" \
    FP_EXTRA_CONFIG="" \
    FP_SERVER_NAME="http://localhost:8080" \
    FP_HTTP_PORT="8080" \
    FP_LOG_LEVEL="WARN" \
    FP_SERVER_OPTIONS="" \
    FP_PHP_SERVER_OPTIONS="" \
    FP_MAX_EXECUTION_TIME="600" \
    FP_MAX_INPUT_TIME="600" \
    FP_MAX_WAIT_TIME="30s" \
    FP_TRUSTED_PROXIES="private_ranges" \
    FP_CSP_ENABLED="true" \
    FP_CSP_HEADER="Content-Security-Policy" \
    FP_SECURITY_HEADERS="true" \
    FP_AUTO_HTTPS="off"

WORKDIR /app
USER frank

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s \
    CMD curl -fsS "http://localhost:${FP_HTTP_PORT:-8080}/unit-ping" || exit 1

ENTRYPOINT ["docker-php-entrypoint"]
CMD ["--config", "/etc/frankenphp/Caddyfile", "--adapter", "caddyfile"]

LABEL org.opencontainers.image.title=Frankenpress
LABEL org.opencontainers.image.description="WordPress (Bedrock) on FrankenPHP, Debian slim runtime"
LABEL org.opencontainers.image.url=https://github.com/clysec/frankenpress
LABEL org.opencontainers.image.source=https://github.com/clysec/frankenpress
LABEL org.opencontainers.image.licenses=MIT
LABEL org.opencontainers.image.vendor="Cloudyne Security Labs"
