#!/usr/bin/env python3
"""Request regression tests against a local image; only disposable containers are modified."""
import argparse
import pathlib
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--image', default='oci.fi/frankenpress:8.5-trixie')
parser.add_argument('--composer-update', action='store_true', help='Also run a real Composer update (requires network)')
args = parser.parse_args()


def docker(*argv):
    return subprocess.check_output(['docker', *argv], text=True).rstrip()


with tempfile.TemporaryDirectory(prefix='frankenpress-security-') as tmp:
    web = pathlib.Path(tmp)
    web.chmod(0o755)
    files = {
        'index.php': '<?php echo "front-controller";',
        'include-check.php': '<?php require __DIR__ . "/wp/wp-includes/helper.php";',
        'wp/wp-includes/helper.php': '<?php echo "internal-include";',
        'wp/xmlrpc.php': '<?php echo "xmlrpc-enabled";',
        'wp/wp-login.php': '<?php echo "login";',
        'wp/wp-admin/index.php': '<?php echo "admin";',
        'app/plugins/example/endpoint.php': '<?php echo "plugin-endpoint";',
        '.env': 'secret', '.git/config': 'secret',
        'composer.json': 'secret', 'wp/wp-config.php.bak': 'secret',
        'app/debug.log': 'secret', '.well-known/acme-challenge/token': 'challenge',
        '.well-known/.env': 'secret', '.well-known/nested/.git/config': 'secret',
        'app/uploads/photo.jpg': 'original', 'app/uploads/photo.jpg.webp': 'webp',
    }
    trees = ['app/uploads', 'app/cache', 'wp/wp-includes', 'wp-includes',
             'wp-content/uploads', 'wp-content/cache', 'uploads', 'cache']
    for tree in trees:
        files.update({f'{tree}/{name}': content for name, content in {
            'shell.php': '<?php echo "executed";', 'nested/shell.php': '<?php echo "executed";',
            'index.php': '<?php echo "executed-index";',
            'shell.PHP': 'source', 'shell.phtml': 'source', 'shell.php.bak': 'source',
            'asset.css': 'static-asset',
        }.items()})
    for name, content in files.items():
        path = web / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
    count = 0
    for enabled in [None, 'false', 'true', 'invalid']:
        cid = docker('run', '-d', '--rm', '--network', 'none',
                     *(['-e', f'FP_XMLRPC_ENABLED={enabled}'] if enabled is not None else []),
                     '-v', f'{ROOT / "Caddyfile"}:/etc/frankenphp/Caddyfile:ro',
                     '-v', f'{web}:/app/web:ro', args.image)
        try:
            for attempt in range(30):
                try:
                    docker('exec', cid, 'curl', '-fsS', 'http://localhost:8080/unit-ping')
                    break
                except subprocess.CalledProcessError:
                    time.sleep(0.2)
            else:
                raise RuntimeError(docker('logs', cid))

            def request(path, status, body=None, *extra):
                global count
                result = docker('exec', cid, 'curl', '--path-as-is', '-sS',
                                '-H', 'Accept: image/webp', *extra,
                                '-w', '\n%{http_code}', 'http://localhost:8080' + path)
                actual_body, actual_status = result.rsplit('\n', 1)
                assert actual_status == str(status), (enabled, path, result)
                if body is not None:
                    assert actual_body == body, (enabled, path, result)
                count += 1

            for tree in trees:
                for suffix in ['shell.php', 'nested/shell.php', 'shell.php/extra',
                               'shell.php/photo.jpg', 'shell.PHP', 'shell.phtml',
                               'shell.php.bak', '%73hell%2ephp', 'shell.php%2fextra']:
                    request(f'/{tree}/{suffix}', 403)
                request(f'/{tree}/', 404)  # Must never execute index.php.
                request(f'/{tree}/asset.css', 200, 'static-asset')
            for path in ['/.env', '/.git/config', '/composer.json', '/wp/wp-config.php.bak',
                         '/app/debug.log', '/auth.json.bak', '/composer.json.old', '/app/debug.log.1', '/.well-known/.env', '/.well-known/nested/.git/config',
                         '/app/uploads/../uploads/shell.php', '/app//uploads/shell.php']:
                request(path, 403)
            for path in ['/xmlrpc.php', '/wp/xmlrpc.php', '/wp/xmlrpc.php/extra', '/wp/xmlrpc%2ephp', '/wp//xmlrpc.php', '/wp/xmlrpc.php.jpg']:
                if enabled != 'true':
                    request(path, 403, None, '-X', 'POST')
            if enabled == 'true':
                request('/wp/xmlrpc.php', 200, 'xmlrpc-enabled', '-X', 'POST')
            request('/', 200, 'front-controller')
            request('/include-check.php', 200, 'internal-include')
            request('/pretty/permalink', 200, 'front-controller')
            request('/wp/wp-login.php', 200, 'login')
            request('/wp/wp-admin/', 200, 'admin')
            request('/app/plugins/example/endpoint.php', 200, 'plugin-endpoint')
            request('/app/uploads/photo.jpg', 200, 'webp')
            request('/.well-known/acme-challenge/token', 200, 'challenge')
        finally:
            docker('rm', '-f', cid)
    print(f'{count} HTTP checks passed')

cid = docker('run', '-d', '--rm', '--network', 'bridge' if args.composer_update else 'none',
             '--entrypoint', 'sleep', args.image, 'infinity')
try:
    # Copy, rather than bind-mount, so Composer could actually remove the plugin if packaging were wrong.
    docker('cp', str(ROOT / 'mu-plugins/frankenpress-security.php'),
           f'{cid}:/app/web/app/mu-plugins/frankenpress-security.php')
    docker('cp', str(ROOT / 'tests/pingbacks.php'), f'{cid}:/tmp/pingbacks.php')
    print(docker('exec', cid, 'php', '/tmp/pingbacks.php'))
    if args.composer_update:
        before = docker('exec', cid, 'sha256sum', '/app/web/app/mu-plugins/frankenpress-security.php')
        print(docker('exec', '-w', '/app', cid, 'composer', 'update', '--no-dev', '--no-interaction', '--prefer-dist', '--no-progress'))
        after = docker('exec', cid, 'sha256sum', '/app/web/app/mu-plugins/frankenpress-security.php')
        assert before == after, 'Composer changed the security plugin'
        print(docker('exec', cid, 'php', '/tmp/pingbacks.php'))
        print(docker('exec', '-w', '/app', cid, 'composer', 'reinstall', 'roots/wordpress', '--no-interaction', '--prefer-dist', '--no-progress'))
        assert before == docker('exec', cid, 'sha256sum', '/app/web/app/mu-plugins/frankenpress-security.php')
        print(docker('exec', cid, 'php', '/tmp/pingbacks.php'))
        print('Composer update and WordPress core reinstall preserved the plugin and its behavior')
finally:
    docker('rm', '-f', cid)
