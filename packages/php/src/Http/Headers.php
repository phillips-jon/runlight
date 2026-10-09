<?php

declare(strict_types=1);

namespace Runlight\Http;

/**
 * Header names are matched without regard to case, as the Fetch API's Headers
 * are. get() joins repeated values with ", "; Set-Cookie is kept apart, since
 * its values may hold commas, and read back with getSetCookie().
 */
final class Headers implements \IteratorAggregate
{
    /** @var array<string, list<string>> lowercase name to values */
    private array $values = [];

    /** @param array<string, string|list<string>>|Headers $init */
    public function __construct(array|Headers $init = [])
    {
        if ($init instanceof Headers) {
            $this->values = $init->values;
            return;
        }
        foreach ($init as $name => $value) {
            foreach ((array) $value as $one) {
                $this->append((string) $name, (string) $one);
            }
        }
    }

    public function get(string $name): ?string
    {
        $name = strtolower($name);
        if (!isset($this->values[$name])) {
            return null;
        }
        return implode(', ', $this->values[$name]);
    }

    public function has(string $name): bool
    {
        return isset($this->values[strtolower($name)]);
    }

    public function set(string $name, string $value): void
    {
        $this->values[strtolower($name)] = [self::clean($value)];
    }

    public function append(string $name, string $value): void
    {
        $this->values[strtolower($name)][] = self::clean($value);
    }

    public function delete(string $name): void
    {
        unset($this->values[strtolower($name)]);
    }

    /** @return list<string> */
    public function getSetCookie(): array
    {
        return $this->values['set-cookie'] ?? [];
    }

    /** @return array<string, list<string>> */
    public function all(): array
    {
        return $this->values;
    }

    /** Name and joined value pairs in name order, as iterating Fetch Headers gives them. */
    public function getIterator(): \Generator
    {
        $names = array_keys($this->values);
        sort($names, SORT_STRING);
        foreach ($names as $name) {
            if ($name === 'set-cookie') {
                foreach ($this->values[$name] as $value) {
                    yield $name => $value;
                }
            } else {
                yield $name => implode(', ', $this->values[$name]);
            }
        }
    }

    /** Header values never carry a line break, so nothing a caller passes can add a header of its own. */
    private static function clean(string $value): string
    {
        return trim(str_replace(["\r", "\n", "\0"], '', $value));
    }
}
