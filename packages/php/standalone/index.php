<?php

/**
 * Runlight on its own domain, for PHP hosting: the dashboard at the root, sites managed in it, sign-in accounts,
 * and short links on any domain pointed here. Copy this folder to the web root of a project that ran
 * `composer require runlight/runlight`, and send every request here (the .htaccess beside this file does it on
 * Apache). Settings come from the environment or from config.php in the project folder.
 *
 * Docs: https://runlight.sh/docs/php/#the-standalone-drop-in
 */

declare(strict_types=1);

// The project folder is the one that holds vendor/, here or a few folders up.
$root = null;
for ($dir = __DIR__, $i = 0; $i < 5; $dir = dirname($dir), $i++) {
    if (is_file("$dir/vendor/autoload.php")) {
        $root = $dir;
        break;
    }
}
if ($root === null) {
    http_response_code(500);
    header('content-type: text/plain; charset=utf-8');
    echo "Runlight: run composer require runlight/runlight in the folder above this one.\n";
    exit;
}
require "$root/vendor/autoload.php";

try {
    $server = (new Runlight\Server\Config($root))->standalone();
} catch (Throwable $error) {
    error_log('Runlight: ' . $error->getMessage());
    http_response_code(500);
    header('content-type: text/plain; charset=utf-8');
    header('cache-control: no-store');
    echo "Runlight could not start. The web server's error log says why.\n";
    exit;
}
$server->serve();
