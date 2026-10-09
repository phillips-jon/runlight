<?php

declare(strict_types=1);

namespace Runlight\Tests\Conformance\Fake;

/**
 * Normalizing run backwards: each placeholder in an expected answer becomes a
 * fresh value of the shape that normalizes to it (24 hex digits for a whole
 * "<k>", 32 for "<hex>" in text, an rl_ key for "<key>", 40 hex digits for a
 * secret query value), so the runner's masking is exercised on values it has
 * never seen. Values are made from a counter, so a run is repeatable.
 */
final class Denormalizer
{
    private int $made = 0;

    public function value(mixed $value, string $key = ''): mixed
    {
        if (is_array($value)) {
            return array_map(fn ($v) => $this->value($v, $key), $value);
        }
        if ($value instanceof \stdClass) {
            $out = new \stdClass();
            foreach (get_object_vars($value) as $k => $v) {
                $out->{$k} = $this->value($v, (string) $k);
            }
            return $out;
        }
        if (is_string($value)) {
            return $this->text($value, $key);
        }
        return $value;
    }

    public function text(string $text, string $key = ''): string
    {
        if ($text === '<' . ($key !== '' ? $key : 'value') . '>') {
            return $this->hex(24);
        }
        $text = (string) preg_replace_callback('/([?&](?:code|ticket|secret|code_challenge)=)<value>/', fn (array $m) => $m[1] . $this->hex(40), $text);
        $text = (string) preg_replace_callback('/<hex>/', fn () => $this->hex(32), $text);
        return (string) preg_replace_callback('/<key>/', fn () => 'rl_' . $this->letters(24), $text);
    }

    /** A Set-Cookie line with a fresh value where it says <value>. */
    public function cookie(string $line): string
    {
        return (string) preg_replace_callback('/^([^=;]+)=<value>/', fn (array $m) => $m[1] . '=' . $this->letters(16), $line, 1);
    }

    public function hex(int $length): string
    {
        $out = '';
        while (strlen($out) < $length) {
            $out .= hash('sha256', 'fake ' . $this->made++);
        }
        return substr($out, 0, $length);
    }

    /** Letters that are never hex digits, so no run of them reads as hex. */
    public function letters(int $length): string
    {
        $alphabet = 'GHJKMNPQRSTVWXYZghjkmnpqrstvwxyz';
        $out = '';
        foreach (str_split($this->hex($length)) as $c) {
            $out .= $alphabet[hexdec($c) * 2 % 32 + ($this->made % 2)];
        }
        return $out;
    }
}
