# frankenpress
FrankenPHP and Wordpress/Bedrock application containers

## Images

| Image | Tags | Contents |
|---|---|---|
| `clysec/php-zts` | `<php>-<debian>` | docker-library PHP (ZTS) with mysqli, pdo_mysql, gd, zip, intl, bcmath and imagick compiled in. Includes the PHP build toolchain. |
| `clysec/frankenphp` | `<php>-<debian>`, `latest` | php-zts + FrankenPHP. Includes the build toolchain and `install-php-extensions`. |
| `clysec/frankenpress` | `<php>-<debian>`, `latest` | Slim Debian runtime: FrankenPHP, Bedrock/WordPress, composer, wp-cli, git, mariadb-client. **No compiler or PHP headers.** |
| `clysec/frankenpress` | `<php>-<debian>-builder`, `latest-builder` | Same content as above but on the full base, so `install-php-extensions`/`phpize` work. |

All images are published to `ghcr.io`, `docker.io` and `oci.fi` for `linux/amd64` and `linux/arm64`.

### Adding PHP extensions downstream

Extensions cannot be compiled in the slim runtime image. Build them in a stage based on the
`-builder` tag instead:

```Dockerfile
FROM ghcr.io/clysec/frankenpress:8.5-trixie-builder
USER root
RUN install-php-extensions redis
USER frank
```

### Runtime configuration (frankenpress)

All knobs are environment variables read by the Caddyfile at start-up:

| Variable | Default | Purpose |
|---|---|---|
| `FP_SERVER_NAME` | `http://localhost:8080` | Site address (a catch-all `http://` block is always present) |
| `FP_HTTP_PORT` | `8080` | Listening port |
| `FP_LOG_LEVEL` | `WARN` | Caddy access/error log level |
| `FP_MAX_EXECUTION_TIME` / `FP_MAX_INPUT_TIME` | `600` | PHP limits in seconds |
| `FP_MAX_WAIT_TIME` | `30s` | How long a request may wait for a free PHP thread before a 503 |
| `FP_TRUSTED_PROXIES` | `private_ranges` | Proxies whose `X-Forwarded-*` headers are trusted; `X-Forwarded-Proto: https` from them sets `HTTPS=on` for PHP |
| `FP_GLOBAL_OPTIONS` | empty | Extra Caddy global options (e.g. `servers { metrics }` to expose FrankenPHP Prometheus metrics on the loopback admin API `localhost:2019/metrics`) |
| `FP_FRANKENPHP_OPTIONS` | empty | Extra directives inside the `frankenphp` block (e.g. `num_threads 4`) |
| `FP_EXTRA_CONFIG` | empty | Extra top-level Caddyfile content (additional sites) |
| `FP_SERVER_OPTIONS` | empty | Extra directives inside the site block |
| `FP_PHP_SERVER_OPTIONS` | empty | Extra directives inside `php_server` |

WordPress itself is configured through Bedrock's `.env` and environment variables (`WP_ENV`, `WP_HOME`, `DATABASE_URL`, salts).
Images that have a `.webp` sibling (`photo.jpg.webp` or `photo.webp`) are served to clients that send `Accept: image/webp`.

### Running in Kubernetes / hardened environments

- The runtime image listens on 8080 as uid 101 and carries no file capabilities, so it runs under the Pod Security
  "restricted" profile (`runAsNonRoot`, `allowPrivilegeEscalation: false`, `capabilities: drop: [ALL]`).
- With `readOnlyRootFilesystem: true`, mount writable volumes at `/config`, `/data` and `/tmp`.
- Set `GOMEMLIMIT` to the container memory limit (e.g. `GOMEMLIMIT=900MiB` for a 1 GiB limit) so the Go runtime
  respects it, and size `num_threads` (via `FP_FRANKENPHP_OPTIONS="num_threads 4"`) so that
  `num_threads x memory_limit` stays below the limit.
- Use `/unit-ping` on the app port for readiness and liveness probes; the Caddy admin API on 2019 is loopback-only.

### Local build

```sh
python3 base/generate.py          # patch the docker-library Dockerfiles (idempotent)
docker compose build php-zts
docker compose build frankenphp
docker compose build frankenpress-builder frankenpress
```
