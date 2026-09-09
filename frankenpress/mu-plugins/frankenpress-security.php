<?php
/**
 * Plugin Name: Frankenpress Security
 * Description: Permanently disables pingbacks independently of XML-RPC availability.
 */

namespace Frankenpress\Security;

defined('ABSPATH') || exit;

// Keep authenticated XML-RPC methods available when explicitly enabled in Caddy.
add_filter('xmlrpc_methods', static function (array $methods): array {
    unset($methods['pingback.ping'], $methods['pingback.extensions.getPingbacks']);
    return $methods;
}, PHP_INT_MAX);

// Covers queued pingbacks and existing posts without modifying stored settings.
add_action('pre_ping', static function (array &$links): void {
    $links = [];
}, PHP_INT_MAX);
add_filter('pre_option_default_pingback_flag', '__return_zero', PHP_INT_MAX);

add_filter('wp_headers', static function (array $headers): array {
    foreach (array_keys($headers) as $name) {
        if (strcasecmp($name, 'X-Pingback') === 0) {
            unset($headers[$name]);
        }
    }
    return $headers;
}, PHP_INT_MAX);

add_filter('bloginfo_url', static function ($url, $show) {
    return $show === 'pingback_url' ? '' : $url;
}, PHP_INT_MAX, 2);
