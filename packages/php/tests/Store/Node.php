<?php

declare(strict_types=1);

namespace Runlight\Tests\Store;

/** Runs scripts/php-fixtures-store.mts with the TypeScript SDK, when node is at hand. */
final class Node
{
    public static function root(): string
    {
        return dirname(__DIR__, 4);
    }

    /** node 22 or later on the PATH (or RUNLIGHT_NODE), with tsx installed at the repository root. */
    public static function binary(): ?string
    {
        if (!is_dir(self::root() . '/node_modules/tsx')) {
            return null;
        }
        foreach (array_filter([getenv('RUNLIGHT_NODE') ?: null, 'node']) as $node) {
            $version = @shell_exec(escapeshellarg($node) . ' --version 2>/dev/null');
            if (is_string($version) && preg_match('/^v(\d+)\./', trim($version), $m) && (int) $m[1] >= 22) {
                return $node;
            }
        }
        return null;
    }

    /**
     * The script with these arguments: its exit status, what it wrote, and what it said on stderr.
     *
     * @param list<string> $args
     * @return array{0: int, 1: string, 2: string}
     */
    public static function store(string $node, array $args): array
    {
        $process = proc_open([$node, '--import', 'tsx', 'scripts/php-fixtures-store.mts', ...$args], [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes, self::root());
        if (!is_resource($process)) {
            return [-1, '', 'node did not start'];
        }
        $out = (string) stream_get_contents($pipes[1]);
        $err = (string) stream_get_contents($pipes[2]);
        return [proc_close($process), $out, $err];
    }
}
