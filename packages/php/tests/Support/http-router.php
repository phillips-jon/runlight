<?php

declare(strict_types=1);

// A router for PHP's built-in server in the fetch tests: /bytes?n=... answers n bytes of "a", in chunks.
$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
if ($path === '/bytes') {
    $n = (int) ($_GET['n'] ?? 0);
    header('content-type: text/html');
    while ($n > 0) {
        $part = min($n, 8192);
        echo str_repeat('a', $part);
        flush();
        $n -= $part;
    }
    return true;
}
header('content-type: text/plain');
echo 'host ' . ($_SERVER['HTTP_HOST'] ?? '');
return true;
