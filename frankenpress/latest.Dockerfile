ARG IMAGE_TAG
FROM ghcr.io/clysec/frankenphp:${IMAGE_TAG:-8.4-alpine3.23}

ARG MIN_WORDPRESS_VERSION="7.0.0"
RUN rm -rf /app/* \
    && composer create-project roots/bedrock --no-interaction --no-dev . \
    && composer require -W "roots/wordpress:^${MIN_WORDPRESS_VERSION}" \
    && cp .env.example .env