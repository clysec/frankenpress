"""Patch the docker-library PHP ZTS Dockerfiles (base/php submodule) so the
resulting php-zts base image ships the extensions Frankenpress needs.

Idempotent: a Dockerfile that already contains the patch marker is skipped, so
the script can run on every CI build without a state file.

Usage: python3 generate.py [-devcontainer] [-hardened]
"""
import os
import sys

dir = os.path.dirname(os.path.abspath(__file__))
phpver = [f.path for f in os.scandir(os.path.join(dir, 'php')) if f.is_dir() and f.name.startswith('8.')]

args = "-".join(sys.argv)

# Inserted into every patched Dockerfile; used as the idempotency marker.
MARKER = '# frankenpress: patched by base/generate.py'

CONFIGURE_FLAGS = (
    '--disable-zend-signals'
    ' --enable-zend-max-execution-timers'
    ' --with-pdo-mysql --with-mysqli'
    ' --enable-bcmath'
    ' --with-freetype --with-jpeg --with-webp --enable-gd'
    ' --with-zip'
    ' --enable-intl'
)

IMAGICK_VERSION = '3.8.1'
APCU_VERSION = '5.1.28'


def replace_once(data, old, new, path):
    """Replace exactly one occurrence; fail loudly if upstream changed the text."""
    count = data.count(old)
    if count != 1:
        raise SystemExit(f'{path}: expected exactly one occurrence of {old!r}, found {count}')
    return data.replace(old, new)


def patch_file(path, patcher):
    if not os.path.exists(path):
        return
    with open(path, 'r') as f:
        data = f.read()

    if MARKER in data:
        print(f'Already patched {path}')
        return

    data = patcher(data, path)
    # Keep a leading "# syntax=" parser directive (if any) on the first line.
    first, sep, rest = data.partition('\n')
    if first.startswith('# syntax='):
        data = first + sep + MARKER + '\n' + rest
    else:
        data = MARKER + '\n' + data

    with open(path, 'w') as f:
        f.write(data)
    print(f'Patched {path}')


def patch_alpine(alp):
    def patcher(data, path):
        data = data.replace(
            'sqlite-dev',
            'sqlite-dev jpeg-dev freetype-dev libwebp-dev icu-dev libpng-dev libzip-dev mariadb-dev',
        )
        data = data.replace('--disable-zend-signals', CONFIGURE_FLAGS)

        if "-devcontainer" in args:
            data = data.replace(f'FROM alpine:{alp}', f'FROM mcr.microsoft.com/devcontainers/base:alpine-{alp}')
        if "-hardened" in args:
            data = data.replace('FROM alpine:', 'FROM dhi.io/alpine-base:')
        return data
    return patcher


def patch_trixie(data, path):
    # Build dependencies for the extra extensions (runtime libraries are kept
    # automatically by the upstream ldd/dpkg-query step below).
    data = replace_once(
        data,
        'libsqlite3-dev \\\n',
        'libsqlite3-dev \\\n'
        '\t\tlibjpeg-dev \\\n'
        '\t\tlibfreetype-dev \\\n'
        '\t\tlibwebp-dev \\\n'
        '\t\tlibicu-dev \\\n'
        '\t\tlibpng-dev \\\n'
        '\t\tlibzip-dev \\\n'
        '\t\tlibmariadb-dev \\\n'
        '\t\tlibmagickwand-dev \\\n',
        path,
    )
    data = replace_once(data, '--disable-zend-signals', CONFIGURE_FLAGS, path)

    # imagick and apcu are built with pecl right after PHP itself, while the
    # toolchain and -dev packages are still installed.
    data = replace_once(
        data,
        'make clean;',
        f"make clean; printf '\\n' | pecl install imagick-{IMAGICK_VERSION} apcu-{APCU_VERSION} &&",
        path,
    )

    # Upstream only inspects executable files when deciding which runtime
    # libraries to keep. pecl-built extensions are mode 0644, so include *.so
    # or the ImageMagick runtime libraries would be auto-removed.
    data = replace_once(
        data,
        "find /usr/local -type f -executable -exec ldd '{}' ';'",
        "find /usr/local -type f \\( -executable -o -name '*.so' \\) -exec ldd '{}' ';'",
        path,
    )

    data = replace_once(
        data,
        'RUN docker-php-ext-enable sodium',
        'RUN docker-php-ext-enable sodium imagick apcu',
        path,
    )

    if "-devcontainer" in args:
        data = data.replace('FROM debian:trixie-slim', 'FROM mcr.microsoft.com/devcontainers/base:debian-trixie')
    if "-hardened" in args:
        data = data.replace('FROM debian:trixie-slim', 'FROM dhi.io/debian-base:trixie')
    return data


for folder in phpver:
    alpver = [f.path for f in os.scandir(folder) if f.is_dir() and f.name.startswith('alpine')]
    for alp in alpver:
        patch_file(os.path.join(alp, 'zts', 'Dockerfile'), patch_alpine(os.path.basename(alp)))

    patch_file(os.path.join(folder, 'trixie', 'zts', 'Dockerfile'), patch_trixie)
