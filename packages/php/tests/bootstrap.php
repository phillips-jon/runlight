<?php

declare(strict_types=1);

require __DIR__ . '/../vendor/autoload.php';

// The tests' made-up names (blog.example, a.com) answer at a public address without asking DNS, so the
// fake Fetchers are reached; an address written out, or localhost, is still checked as it is.
Runlight\Safefetch::lookupInTests(static fn (string $name): array => match (true) {
    filter_var(trim($name, '[]'), FILTER_VALIDATE_IP) !== false => [trim($name, '[]')],
    rtrim($name, '.') === 'localhost' || str_ends_with(rtrim($name, '.'), '.localhost') => ['127.0.0.1'],
    default => ['93.184.215.14'],
});
