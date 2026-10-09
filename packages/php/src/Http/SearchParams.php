<?php

declare(strict_types=1);

namespace Runlight\Http;

/**
 * Query parameters as JavaScript's URLSearchParams reads and writes them:
 * pairs kept in order, `+` read as a space, and written back in the
 * application/x-www-form-urlencoded form. Unlike PHP's own parsing, a name
 * like `a[]` or `a.b` is kept exactly as sent.
 */
final class SearchParams implements \IteratorAggregate
{
    /** @var list<array{string, string}> */
    private array $pairs = [];

    /** @param string|array<string, string> $init */
    public function __construct(string|array $init = '')
    {
        if (is_array($init)) {
            foreach ($init as $name => $value) {
                $this->pairs[] = [(string) $name, (string) $value];
            }
            return;
        }
        $init = ltrim($init, '?');
        if ($init === '') {
            return;
        }
        foreach (explode('&', $init) as $part) {
            if ($part === '') {
                continue;
            }
            $at = strpos($part, '=');
            $name = $at === false ? $part : substr($part, 0, $at);
            $value = $at === false ? '' : substr($part, $at + 1);
            $this->pairs[] = [self::decode($name), self::decode($value)];
        }
    }

    public function get(string $name): ?string
    {
        foreach ($this->pairs as [$key, $value]) {
            if ($key === $name) {
                return $value;
            }
        }
        return null;
    }

    /** @return list<string> */
    public function getAll(string $name): array
    {
        $out = [];
        foreach ($this->pairs as [$key, $value]) {
            if ($key === $name) {
                $out[] = $value;
            }
        }
        return $out;
    }

    public function has(string $name): bool
    {
        return $this->get($name) !== null;
    }

    public function set(string $name, string $value): void
    {
        $found = false;
        $pairs = [];
        foreach ($this->pairs as $pair) {
            if ($pair[0] !== $name) {
                $pairs[] = $pair;
            } elseif (!$found) {
                $pairs[] = [$name, $value];
                $found = true;
            }
        }
        if (!$found) {
            $pairs[] = [$name, $value];
        }
        $this->pairs = $pairs;
    }

    public function append(string $name, string $value): void
    {
        $this->pairs[] = [$name, $value];
    }

    public function delete(string $name): void
    {
        $this->pairs = array_values(array_filter($this->pairs, fn (array $pair) => $pair[0] !== $name));
    }

    /** @return list<string> */
    public function keys(): array
    {
        return array_map(fn (array $pair) => $pair[0], $this->pairs);
    }

    public function getIterator(): \Generator
    {
        foreach ($this->pairs as [$name, $value]) {
            yield $name => $value;
        }
    }

    public function toString(): string
    {
        return implode('&', array_map(fn (array $pair) => self::encode($pair[0]) . '=' . self::encode($pair[1]), $this->pairs));
    }

    public function __toString(): string
    {
        return $this->toString();
    }

    private static function decode(string $text): string
    {
        $text = rawurldecode(str_replace('+', ' ', $text));
        // Bytes that are not UTF-8 become U+FFFD, as URLSearchParams decodes them.
        return \Runlight\Js::scrub($text);
    }

    /** The form encoding: letters, digits, and *-._ as they are, spaces as +, the rest escaped. */
    public static function encode(string $text): string
    {
        return str_replace(' ', '+', preg_replace_callback('/[^A-Za-z0-9*\-._ ]/', fn ($m) => sprintf('%%%02X', ord($m[0])), $text) ?? '');
    }
}
