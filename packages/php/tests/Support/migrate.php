<?php

declare(strict_types=1);

// Creates Runlight's tables, as one of several processes starting at once: php migrate.php <kind> <url or path> [schema]

require __DIR__ . '/../../vendor/autoload.php';

use Runlight\Store\Stores;

[, $kind, $where] = $argv;
$store = match ($kind) {
    'sqlite' => Stores::sqlite($where),
    'postgres' => Stores::postgres($where, ['schema' => $argv[3]]),
    default => Stores::mysql($where),
};
$store->migrate();
$store->close();
echo "ok\n";
