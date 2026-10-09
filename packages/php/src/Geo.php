<?php

declare(strict_types=1);

namespace Runlight;

use Runlight\Http\Headers;

/**
 * Where a visitor is, from a hosting platform's headers or a database lookup.
 *
 * A location is an array{country: string, region: string, city: string}: the country ISO 3166-1 alpha-2 in
 * upper case, the region ISO 3166-2 such as "US-CA". A lookup is a callable(string $ip): ?array giving any
 * of those keys, such as one made by fileLookup() from an MMDB file.
 *
 * Where the TypeScript would throw a TypeError on a value of the wrong type (a number for a city), this
 * throws one too, and the callers catch it where the TypeScript does.
 */
final class Geo
{
    private const EMPTY = ['country' => '', 'region' => '', 'city' => ''];

    private static function decode(?string $value): string
    {
        if ($value === null || $value === '') {
            return '';
        }
        return Js::trim(Js::decodeURIComponent($value) ?? $value);
    }

    /**
     * @param array{country?: mixed, region?: mixed, city?: mixed} $location
     * @return array{country: string, region: string, city: string}
     */
    private static function clean(array $location): array
    {
        $country = Js::slice(Js::upper(self::text($location['country'] ?? null)), 0, 2);
        if (!preg_match('/^[A-Z]{2}$/D', $country) || $country === 'XX' || $country === 'T1') {
            $country = '';
        }
        // A code ("CA", "US-CA") is kept as ISO 3166-2; a name from a database
        // that has no codes ("California") is kept readable, as "US-California".
        $raw = Js::trim(self::text($location['region'] ?? null));
        $region = preg_match('/^([A-Za-z]{2}-)?[A-Za-z0-9]{1,3}$/D', $raw) ? strtoupper($raw) : Js::slice($raw, 0, 80);
        if ($region !== '' && !preg_match('/^[A-Z]{2}-/', $region) && $country !== '') {
            $region = "$country-$region";
        }
        if ($country === '') {
            $region = '';
        }
        $city = $country !== '' ? Js::slice(self::text($location['city'] ?? null), 0, 100) : '';
        return ['country' => $country, 'region' => $region, 'city' => $city];
    }

    /** A string, or "" for null, as `value ?? ""` gives; anything else has no string methods in JavaScript. */
    private static function text(mixed $value): string
    {
        if ($value === null || $value instanceof Undefined) {
            return '';
        }
        if (!is_string($value)) {
            throw new \TypeError('Not a string');
        }
        return $value;
    }

    /**
     * Location from the headers a hosting platform adds, if any.
     *
     * @return array{country: string, region: string, city: string}|null
     */
    public static function locationFromHeaders(Headers $headers): ?array
    {
        $vercel = $headers->get('x-vercel-ip-country');
        if ($vercel !== null && $vercel !== '') {
            return self::clean([
                'country' => $vercel,
                'region' => self::decode($headers->get('x-vercel-ip-country-region')),
                'city' => self::decode($headers->get('x-vercel-ip-city')),
            ]);
        }
        $cloudflare = $headers->get('cf-ipcountry');
        if ($cloudflare !== null && $cloudflare !== '') {
            return self::clean([
                'country' => $cloudflare,
                'region' => self::decode($headers->get('cf-region-code')),
                'city' => self::decode($headers->get('cf-ipcity')),
            ]);
        }
        $netlify = $headers->get('x-nf-geo');
        if ($netlify !== null && $netlify !== '') {
            try {
                $geo = json_decode(self::atob($netlify), false, 100000, JSON_THROW_ON_ERROR);
                if ($geo === null) {
                    // Reading a field of null is a TypeError.
                    return null;
                }
                return self::clean([
                    'country' => self::field(self::field($geo, 'country'), 'code'),
                    'region' => self::field(self::field($geo, 'subdivision'), 'code'),
                    'city' => self::field($geo, 'city'),
                ]);
            } catch (\JsonException | \TypeError | \InvalidArgumentException) {
                return null;
            }
        }
        return null;
    }

    /** `value?.key`: a field of a JSON object, or null (undefined) for anything else. */
    private static function field(mixed $value, string $key): mixed
    {
        return $value instanceof \stdClass && property_exists($value, $key) ? $value->{$key} : null;
    }

    /**
     * atob(): forgiving base64 to a binary string, each byte one character, which in PHP is the bytes read
     * as ISO-8859-1 and written as UTF-8.
     */
    private static function atob(string $text): string
    {
        $text = (string) preg_replace('/[\t\n\f\r ]/', '', $text);
        if (strlen($text) % 4 === 0) {
            $text = (string) preg_replace('/={1,2}$/D', '', $text);
        }
        if (strlen($text) % 4 === 1 || preg_match('/[^A-Za-z0-9+\/]/', $text)) {
            throw new \InvalidArgumentException('The string to be decoded is not correctly encoded.');
        }
        $bytes = base64_decode(str_pad($text, (int) ceil(strlen($text) / 4) * 4, '='), true);
        if ($bytes === false) {
            throw new \InvalidArgumentException('The string to be decoded is not correctly encoded.');
        }
        return mb_convert_encoding($bytes, 'UTF-8', 'ISO-8859-1');
    }

    /**
     * @param (callable(string): ?array)|null $lookup
     * @return array{country: string, region: string, city: string}
     */
    public static function locate(Headers $headers, string $ip, ?callable $lookup = null): array
    {
        $fromHeaders = self::locationFromHeaders($headers);
        if ($fromHeaders !== null && $fromHeaders['country'] !== '') {
            return $fromHeaders;
        }
        if ($lookup !== null && $ip !== '') {
            try {
                $found = $lookup($ip);
                if ($found !== null && $found !== false) {
                    return self::clean($found);
                }
            } catch (\Throwable) {
                // A broken lookup must never lose the event.
            }
        }
        return self::EMPTY;
    }

    /**
     * A lookup answering from an MMDB reader. DB-IP's records follow MaxMind's city layout, with names but
     * no subdivision codes; a city loses the district DB-IP adds in brackets, as in "Toronto (Old Toronto)".
     * This is the TypeScript server's lookupFrom (packages/server/src/geo.ts).
     *
     * @param Mmdb|object{get: callable} $reader anything with get(string $ip): mixed
     * @return \Closure(string): ?array{country: string, region: string, city: string}
     */
    public static function lookupFrom(object $reader): \Closure
    {
        return static function (string $ip) use ($reader): ?array {
            try {
                $found = $reader->get($ip);
            } catch (\Throwable) {
                return null;
            }
            $country = self::at($found, 'country', 'iso_code');
            if ($country === null || $country === '' || $country === false || $country === 0) {
                return null;
            }
            $sub = self::at($found, 'subdivisions', 0);
            $city = self::at($found, 'city', 'names', 'en') ?? '';
            return [
                'country' => $country,
                'region' => self::at($sub, 'iso_code') ?? self::at($sub, 'names', 'en') ?? '',
                'city' => is_string($city) ? self::cityName($city) : $city,
            ];
        };
    }

    /** A lookup from an MMDB file the owner supplies, such as MaxMind's GeoLite2 City. */
    public static function fileLookup(string $file): \Closure
    {
        return self::lookupFrom(Mmdb::open($file));
    }

    /** A city as people say it, without a trailing bracketed district. */
    public static function cityName(string $name): string
    {
        return Js::trim((string) preg_replace('/[' . Js::SPACE . ']*\([^)]*\)[' . Js::SPACE . ']*$/uD', '', Js::scrub($name)));
    }

    /** `value?.a?.b`, through arrays decoded from a database record. */
    private static function at(mixed $value, string|int ...$path): mixed
    {
        foreach ($path as $key) {
            if (!is_array($value) || !array_key_exists($key, $value)) {
                return null;
            }
            $value = $value[$key];
        }
        return $value;
    }
}
