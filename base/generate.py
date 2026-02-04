import os
import sys

dir = os.path.dirname(__file__)
phpver = [f.path for f in os.scandir(os.path.join(dir, 'php')) if f.is_dir() and f.name.startswith('8.')]

args = "-".join(sys.argv)

if os.path.exists(os.path.join(dir, 'patched')):
    print('Already patched')
    exit(0)

for folder in phpver:
    alpver = [f.path for f in os.scandir(folder) if f.is_dir() and f.name.startswith('alpine')]
    
    for alp in alpver:
        with open(os.path.join(alp, 'zts', 'Dockerfile'), 'r') as f:
            data = f.read()
        
        data = data.replace('sqlite-dev', 'sqlite-dev jpeg-dev freetype-dev libwebp-dev icu-dev libpng-dev libzip-dev mariadb-dev')
        data = data.replace('--disable-zend-signals', '--disable-zend-signals --enable-zend-max-execution-timers --with-pdo-mysql --with-mysqli --enable-bcmath --with-freetype --with-jpeg --with-webp --with-zip --enable-intl')

        if "-devcontainer" in args:
            data = data.replace(f'FROM alpine:{alp}', f'FROM mcr.microsoft.com/devcontainers/base:alpine-{alp}')
        if "-hardened" in args:
            data = data.replace('FROM alpine:', 'FROM dhi.io/alpine-base:')
        
        with open(os.path.join(alp, 'zts', 'Dockerfile'), 'w') as f:
            f.write(data)
        
        print(f'Patched {os.path.join(alp, "zts", "Dockerfile")}')
    
    if os.path.exists(os.path.join('trixie', 'zts', 'Dockerfile')):
        with open(os.path.join('trixie', 'zts', 'Dockerfile'), 'r') as f:
            data = f.read()
        
        data = data.replace('sqlite-dev', 'libsqlite3-dev libjpeg-dev libfreetype-dev libwebp-dev libicu-dev libpng-dev libzip-dev libmariadb-dev')
        data = data.replace('--disable-zend-signals', '--disable-zend-signals --enable-zend-max-execution-timers --with-pdo-mysql --with-mysqli --enable-bcmath --with-freetype --with-jpeg --with-webp --with-zip --enable-intl')

        if "-devcontainer" in args:
            data = data.replace(f'FROM debian:trixie-slim', f'FROM mcr.microsoft.com/devcontainers/base:debian-trixie')
        if "-hardened" in args:
            data = data.replace('FROM debian:trixie-slim', 'FROM dhi.io/debian-base:trixie')
        
        with open(os.path.join('trixie', 'zts', 'Dockerfile'), 'w') as f:
            f.write(data)
        
        print(f'Patched {os.path.join("trixie", "zts", "Dockerfile")}')

with open(os.path.join(dir, 'patched'), 'w') as f:
    f.write('Patched\n')