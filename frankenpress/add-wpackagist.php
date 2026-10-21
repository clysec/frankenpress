<?php
// Usage: php add-wpackagist.php [/app/composer.json]

$path = $argv[1] ?? '/app/composer.json';
$repository = (object) [
    'name' => 'wpackagist',
    'type' => 'composer',
    'url' => 'https://wpackagist.org',
    'only' => ['wpackagist-plugin/*', 'wpackagist-theme/*'],
];

try {
    $contents = file_get_contents($path);
    if ($contents === false) {
        throw new RuntimeException("Cannot read $path");
    }
    $composer = json_decode($contents, false, 512, JSON_THROW_ON_ERROR);
    if (!$composer instanceof stdClass) {
        throw new RuntimeException('composer.json must contain a JSON object');
    }
    $composer->repositories ??= [];
    if (!is_array($composer->repositories)) {
        throw new RuntimeException('repositories must be a JSON array');
    }

    $found = false;
    foreach ($composer->repositories as $index => $existing) {
        if (($existing->name ?? null) === 'wpackagist'
            || ($existing->url ?? null) === $repository->url) {
            $composer->repositories[$index] = $repository;
            $found = true;
            break;
        }
    }
    if (!$found) {
        $composer->repositories[] = $repository;
    }

    $json = json_encode($composer, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n";
    if (file_put_contents($path, $json, LOCK_EX) === false) {
        throw new RuntimeException("Cannot write $path");
    }
} catch (Throwable $error) {
    fwrite(STDERR, $error->getMessage() . "\n");
    exit(1);
}
