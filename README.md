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
| `FP_CSP` | WordPress-compatible policy (see below) | Full `Content-Security-Policy` value. Leave unset for the default; do not set it to an empty string |
| `FP_CSP_HEADER` | `Content-Security-Policy` | Set to `Content-Security-Policy-Report-Only` to test a policy without enforcing it |
| `FP_CSP_ENABLED` | `true` | `false` disables the CSP header entirely |
| `FP_SECURITY_HEADERS` | `true` | `false` disables `X-Content-Type-Options: nosniff`, `X-Frame-Options: SAMEORIGIN`, `Referrer-Policy: strict-origin-when-cross-origin` and the removal of `X-Powered-By` |
| `FP_XMLRPC_ENABLED` | `false` | Only `true` allows XML-RPC HTTP requests; pingbacks remain disabled. Set in the container environment and restart, not just Bedrock's `.env` |
| `FP_GLOBAL_OPTIONS` | empty | Extra Caddy global options (e.g. `servers { metrics }` to expose FrankenPHP Prometheus metrics on the loopback admin API `localhost:2019/metrics`) |
| `FP_FRANKENPHP_OPTIONS` | empty | Extra directives inside the `frankenphp` block (e.g. `num_threads 4`) |
| `FP_EXTRA_CONFIG` | empty | Extra top-level Caddyfile content (additional sites) |
| `FP_SERVER_OPTIONS` | empty | Extra directives inside the site block |
| `FP_PHP_SERVER_OPTIONS` | empty | Extra directives inside `php_server` |

WordPress itself is configured through Bedrock's `.env` and environment variables (`WP_ENV`, `WP_HOME`, `DATABASE_URL`, salts).
Images that have a `.webp` sibling (`photo.jpg.webp` or `photo.webp`) are served to clients that send `Accept: image/webp`.

### Request hardening

XML-RPC requests return 403 by default, including `/wp/xmlrpc.php` and requests with
path suffixes. Set `FP_XMLRPC_ENABLED=true` in the container environment for integrations
that require XML-RPC. The bundled `frankenpress-security.php` must-use plugin still removes
both pingback XML-RPC methods, prevents outgoing pingbacks (including queued ones), and
suppresses WordPress's pingback discovery header and URL.

Uploads, cache and `wp-includes` trees are static-only: direct PHP requests return 403,
and directory requests cannot execute `index.php`. This covers `/app/uploads`, `/app/cache`,
`/wp/wp-includes`, and conventional `/uploads`, `/cache`, `/wp-includes` and
`/wp-content/{uploads,cache}` paths, including nested files and PHP path suffixes.
Internal PHP includes continue to work. There are no exceptions for legacy Multisite
media serving or PHP endpoints used by legacy editors/cache plugins. Custom upload/cache
locations require corresponding Caddy rules.

Dotfiles, Composer manifests/credentials, `wp-config.php` and its backups, and `debug.log`
are denied over HTTP. Public `/.well-known/` resources remain accessible, but nested
dotfiles there are denied too. Static media, WebP negotiation and ordinary plugin PHP
endpoints remain available.

The Caddy rules live outside the application at `/etc/frankenphp/Caddyfile`. The standalone
MU plugin lives at `/app/web/app/mu-plugins/frankenpress-security.php`, outside Composer's
package directories; WordPress loads it automatically without activation. Both survive
`composer update`, including WordPress replacement, without patching core or Bedrock files.
If a deployment replaces/mounts all of `/app` or `web/app/mu-plugins`, it must include this
file in its application tree. Custom replacement Caddyfiles must retain the hardening rules.

Run regression checks against a locally built image:

```sh
python3 frankenpress/tests/security.py --image oci.fi/frankenpress:8.5-trixie
# Also verify the installed MU plugin survives an actual Composer update (network required):
python3 frankenpress/tests/security.py --image oci.fi/frankenpress:8.5-trixie --composer-update
```

Tests use disposable containers, check HTTP denial and normal routing, and exercise the
plugin with WordPress's hook implementation. They do not need a database.

### Content-Security-Policy

The default policy is:

```
default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' https:; style-src 'self' 'unsafe-inline' https:;
img-src 'self' data: blob: https:; font-src 'self' data: https:; connect-src 'self' https: wss:;
media-src 'self' data: blob: https:; frame-src 'self' https:; worker-src 'self' blob:;
object-src 'none'; base-uri 'self'; form-action 'self' https:; frame-ancestors 'self'
```

It keeps wp-admin, Gutenberg and typical plugins working (they rely on inline and eval scripts and inline styles)
while blocking plugins/objects, `<base>` hijacking, framing by other origins and any non-HTTPS external resource.
To tighten it for a specific site, roll out the stricter value with `FP_CSP_HEADER=Content-Security-Policy-Report-Only`
first, watch the browser console / `report-to` endpoint, then switch the header back. `Strict-Transport-Security` is
intentionally not set here; add it at the TLS-terminating proxy or via `FP_SERVER_OPTIONS="header Strict-Transport-Security max-age=31536000"`.

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
