ARG PHP_VERSION=8.4
ARG ALPINE_VERSION=3.23
ARG VARIANT=
FROM golang:1.25-alpine AS gobuild

WORKDIR /init-go

ADD init-go /init-go

RUN go build -o /init-go/init-go main.go


ARG PHP_VERSION=8.4
ARG ALPINE_VERSION=3.23
ARG VARIANT=
FROM ghcr.io/clysec/frankenphp:${PHP_VERSION}-alpine${ALPINE_VERSION}${VARIANT} AS common

COPY php.ini $PHP_INI_DIR/conf.d/wp.ini
COPY opcache.ini $PHP_INI_DIR/conf.d/opcache-recommended.ini
COPY errors.ini $PHP_INI_DIR/conf.d/errors.ini

ENV WP_CLI_CACHE_DIR="/tmp/wpcli/cache"             \
    WP_CLI_CONFIG_PATH="/etc/wpcli/wpcli.conf"      \
    WP_CLI_PACKAGES_DIR="/etc/wpcli/packages"       \
    CD_CONFIG="/init-go/config.json"                \
    COMPOSER_HOME="/etc/composer"

RUN cp $PHP_INI_DIR/php.ini-production $PHP_INI_DIR/php.ini \
    && docker-php-ext-enable opcache \

    && mkdir -p /app \
    && addgroup --system --gid 101 frank \
    && adduser \
        --system \
        --ingroup frank \
        --home /app \
        --no-create-home \
        --gecos "frankenpress user" \
        --shell /bin/false \
        --uid 101 \
        frank \
    && cd /etc/apk/keys && curl -JO https://git.cloudyne.io/api/packages/linux/alpine/key \
    && echo 'https://git.cloudyne.io/api/packages/linux/alpine/all/repository' >> /etc/apk/repositories \
    && apk add --no-cache bash vvv git git zip unzip mariadb-client nano \
    && mkdir -p /etc/composer /etc/wpcli/packages \
    && curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer \
    && curl -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar  \
    && chmod +x /usr/local/bin/wp \
    && /usr/local/bin/wp --allow-root package install aaemnnosttv/wp-cli-dotenv-command \
    && chown -R frank:frank /app \
        /data/caddy \
        /config/caddy \
        /etc/caddy \
        /etc/frankenphp \
        /usr/local/bin/docker*entrypoint* \
        /etc/wpcli \
        /etc/composer \
    && rm -rf /tmp/* /var/cache/apk/* /usr/share/doc/*
        

WORKDIR /app

USER frank

RUN rm -rf /app/* \
    && composer create-project roots/bedrock --no-interaction --no-dev . \
    && cp .env.example .env

COPY Caddyfile /etc/frankenphp/Caddyfile
COPY --from=gobuild --chown=frank:frank /init-go/init-go /init-go/init-go
COPY --chmod=755 init-go/config-sample.json /init-go/config.json

ENV FP_GLOBAL_OPTIONS="" \
    FP_FRANKENPHP_OPTIONS="" \
    FP_EXTRA_CONFIG="" \
    FP_SERVER_NAME="http://localhost:8080" \
    FP_LOG_LEVEL="WARN" \
    FP_SERVER_OPTIONS="" \
    FP_AUTO_HTTPS="off"

CMD ["--config", "/etc/frankenphp/Caddyfile", "--adapter", "caddyfile"]