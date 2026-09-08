# syntax=docker/dockerfile:1
#checkov:skip=CKV_DOCKER_2
#checkov:skip=CKV_DOCKER_3
#checkov:skip=CKV_DOCKER_7
ARG PHP_VERSION=8.5
ARG DEBIAN_VERSION=trixie
ARG VARIANT=
# Overridable so CI can point at a per-architecture image by digest.
ARG BASE_IMAGE=ghcr.io/clysec/php-zts:${PHP_VERSION}-${DEBIAN_VERSION}${VARIANT}
# Go toolchain pinned like upstream (docker-bake.hcl GO_VERSION); Debian variant to match the builder.
ARG GO_VERSION=1.26
FROM golang:${GO_VERSION}-trixie AS golang-base

FROM ${BASE_IMAGE} AS common

ARG INSTALL_PHP_EXTENSIONS_VERSION=2.11.12

WORKDIR /app

RUN apt-get update && \
	apt-get -y install --no-install-recommends \
		ca-certificates \
		mailcap \
		libcap2-bin \
	&& \
	apt-get clean && \
	rm -rf /var/lib/apt/lists/*

RUN set -eux; \
	mkdir -p \
		/app/public \
		/config/caddy \
		/data/caddy \
		/etc/caddy \
		/etc/frankenphp; \
	sed -i 's/php/frankenphp run/g' /usr/local/bin/docker-php-entrypoint; \
	echo '<?php phpinfo();' > /app/public/index.php

COPY --link ./frankenphp/caddy/frankenphp/Caddyfile /etc/caddy/Caddyfile

RUN ln /etc/caddy/Caddyfile /etc/frankenphp/Caddyfile && \
	curl -fsSL \
		-o /usr/local/bin/install-php-extensions \
		"https://github.com/mlocati/docker-php-extension-installer/releases/download/${INSTALL_PHP_EXTENSIONS_VERSION}/install-php-extensions" && \
	chmod +x /usr/local/bin/install-php-extensions

CMD ["--config", "/etc/frankenphp/Caddyfile", "--adapter", "caddyfile"]
HEALTHCHECK CMD curl -f http://localhost:2019/metrics || exit 1

# See https://caddyserver.com/docs/conventions#file-locations for details
ENV XDG_CONFIG_HOME=/config
ENV XDG_DATA_HOME=/data

EXPOSE 80
EXPOSE 443
EXPOSE 443/udp
EXPOSE 2019

LABEL org.opencontainers.image.title=FrankenPHP
LABEL org.opencontainers.image.description="Base debian image for Frankenpress"
LABEL org.opencontainers.image.url=https://github.com/clysec/frankenpress
LABEL org.opencontainers.image.source=https://github.com/clysec/frankenpress
LABEL org.opencontainers.image.licenses=MIT
LABEL org.opencontainers.image.vendor="Cloudyne Security Labs"

FROM common AS builder

ARG FRANKENPHP_VERSION='dev'
ARG NO_COMPRESS=''
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY --from=golang-base /usr/local/go /usr/local/go

ENV PATH=/usr/local/go/bin:$PATH
ENV GOTOOLCHAIN=local

# This is required to link the FrankenPHP binary to the PHP binary
RUN apt-get update && \
	apt-get -y --no-install-recommends install \
	cmake \
	git \
	libargon2-dev \
	libbrotli-dev \
	libcurl4-openssl-dev \
	libonig-dev \
	libreadline-dev \
	libsodium-dev \
	libsqlite3-dev \
	libssl-dev \
	libxml2-dev \
	zlib1g-dev \
	libjpeg-dev \
	libfreetype-dev \
	libwebp-dev \
	libicu-dev \
	libpng-dev \
	libzip-dev \
	libmariadb-dev \
	&& \
	apt-get clean

# Install e-dant/watcher (necessary for file watching)
WORKDIR /usr/local/src/watcher
RUN --mount=type=secret,id=github-token \
    if [ -f /run/secrets/github-token ] && [ -s /run/secrets/github-token ]; then \
        curl -fsS -H "Authorization: Bearer $(cat /run/secrets/github-token)" https://api.github.com/repos/e-dant/watcher/releases/latest; \
    else \
        curl -fsS https://api.github.com/repos/e-dant/watcher/releases/latest; \
    fi | \
    grep tarball_url | \
    awk '{ print $2 }' | \
    sed 's/,$//' | \
    sed 's/"//g' | \
    xargs curl -fsSL | \
    tar xz --strip-components 1 && \
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && \
    cmake --build build --parallel && \
    cmake --install build && \
    ldconfig

WORKDIR /go/src/app

COPY --link ./frankenphp/go.mod ./frankenphp/go.sum ./
RUN go mod download

WORKDIR /go/src/app/caddy
COPY ./frankenphp/caddy/go.mod ./frankenphp/caddy/go.sum ./
RUN go mod download

WORKDIR /go/src/app
COPY --link ./frankenphp ./

# See https://github.com/docker-library/php/blob/master/8.3/alpine3.20/zts/Dockerfile#L53-L55
ENV CGO_CFLAGS="-DFRANKENPHP_VERSION=$FRANKENPHP_VERSION $PHP_CFLAGS"
ENV CGO_CPPFLAGS=$PHP_CPPFLAGS
ENV CGO_LDFLAGS="-L/usr/local/lib -lssl -lcrypto -lreadline -largon2 -lcurl -lonig -lz $PHP_LDFLAGS"

WORKDIR /go/src/app/caddy/frankenphp
RUN GOBIN=/usr/local/bin \
	../../go.sh install -ldflags "-w -s -X 'github.com/caddyserver/caddy/v2.CustomVersion=FrankenPHP $FRANKENPHP_VERSION PHP $PHP_VERSION Caddy' -X 'github.com/caddyserver/caddy/v2.CustomBinaryName=frankenphp' -X 'github.com/caddyserver/caddy/v2/modules/caddyhttp.ServerHeader=FrankenPHP Caddy'" -buildvcs=true && \
	setcap cap_net_bind_service=+ep /usr/local/bin/frankenphp && \
	cp Caddyfile /etc/frankenphp/Caddyfile && \
	frankenphp version && \
 	frankenphp build-info

WORKDIR /go/src/app

FROM common AS runner

ENV GODEBUG=cgocheck=0

# copy watcher shared library
COPY --from=builder /usr/local/lib/libwatcher* /usr/local/lib/
# fix for the file watcher on arm
RUN apt-get install -y --no-install-recommends libstdc++6 && \
	apt-get clean && \
	ldconfig

COPY --from=builder /usr/local/bin/frankenphp /usr/local/bin/frankenphp
# The builder already applied the capability; only re-apply it if the xattr
# was lost in the copy (re-applying rewrites the 50+ MB binary into a new layer).
RUN (getcap /usr/local/bin/frankenphp | grep -q cap_net_bind_service || setcap cap_net_bind_service=+ep /usr/local/bin/frankenphp) && \
	frankenphp version && \
	frankenphp build-info
