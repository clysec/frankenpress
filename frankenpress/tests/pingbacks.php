<?php
// Exercise the installed MU plugin with WordPress's real hook implementation, without a database.
define('ABSPATH', '/app/web/wp/');
define('WPINC', 'wp-includes');
define('WPMU_PLUGIN_DIR', '/app/web/app/mu-plugins');
require ABSPATH . WPINC . '/plugin.php';
require ABSPATH . WPINC . '/load.php';
require ABSPATH . WPINC . '/functions.php';

$plugin = WPMU_PLUGIN_DIR . '/frankenpress-security.php';
if (!in_array($plugin, wp_get_mu_plugins(), true)) {
    throw new RuntimeException('Security plugin is not discoverable as a MU plugin');
}
require $plugin;

function check($actual, $expected, string $label): void {
    if ($actual !== $expected) {
        throw new RuntimeException($label . ': ' . var_export($actual, true));
    }
}
check(apply_filters('xmlrpc_methods', [
    'pingback.ping' => 'ping',
    'pingback.extensions.getPingbacks' => 'get',
    'wp.getPosts' => 'posts',
]), ['wp.getPosts' => 'posts'], 'XML-RPC methods');
$links = ['https://example.org/post'];
$pung = [];
$postId = 1;
do_action_ref_array('pre_ping', [&$links, &$pung, $postId]);
check($links, [], 'Queued outgoing pingbacks');
check(apply_filters('pre_option_default_pingback_flag', false), 0, 'New outgoing pingbacks');
check(apply_filters('wp_headers', ['X-Pingback' => 'url', 'x-pingback' => 'url', 'Content-Type' => 'text/html']), ['Content-Type' => 'text/html'], 'Headers');
check(apply_filters('bloginfo_url', 'url', 'pingback_url'), '', 'Pingback discovery');
check(apply_filters('bloginfo_url', 'url', 'url'), 'url', 'Other discovery');
echo "MU plugin discovery and pingback checks passed\n";
