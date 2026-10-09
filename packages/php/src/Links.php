<?php

declare(strict_types=1);

namespace Runlight;

use Runlight\Http\Url;

/**
 * Short links: create, change, delete, and import, with the rules every route shares.
 *
 * A LinkInput is an array with `url`, and optionally `name`, `slug`, and `domain` (a link domain added in
 * Settings, or "" for the app's own). A key left out is TS's undefined.
 */
final class Links
{
    public const SLUG_PATTERN = '/^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$/D';
    private const ALPHABET = 'abcdefghijkmnpqrstuvwxyz23456789';

    public function __construct(private readonly Runlight $runlight)
    {
    }

    /** Six characters from an alphabet without look-alikes (no 0/o, 1/l). */
    public static function randomSlug(): string
    {
        $slug = '';
        foreach (str_split(random_bytes(6)) as $byte) {
            $slug .= self::ALPHABET[ord($byte) % strlen(self::ALPHABET)];
        }
        return $slug;
    }

    private static function cleanUrl(mixed $value): string
    {
        $text = Js::trim(Js::string($value ?? ''));
        $url = Url::parse($text);
        if ($url === null) {
            throw new LinkError('The destination must be a full URL, starting with https://', 'link_url');
        }
        if ($url->protocol !== 'https:' && $url->protocol !== 'http:') {
            throw new LinkError('The destination must start with http:// or https://', 'link_protocol');
        }
        if (Js::length($text) > 2000) {
            throw new LinkError('The destination is longer than 2,000 characters', 'link_long');
        }
        return $url->href();
    }

    private static function defaultName(string $url): string
    {
        $u = new Url($url);
        return Js::slice(Sources::stripWww($u->hostname) . ($u->pathname === '/' ? '' : $u->pathname), 0, 100);
    }

    private function domainFor(string $site, mixed $value): string
    {
        $domain = Sources::stripWww(Js::trim(Js::string($value ?? '')));
        if ($domain === '') {
            return '';
        }
        foreach ($this->runlight->store->linkDomains() as $d) {
            if ($d['domain'] === $domain && $d['site'] === $site) {
                return $domain;
            }
        }
        throw new LinkError("Add $domain as a link domain in Settings first", 'link_domain', ['domain' => $domain]);
    }

    /** Slugs are unique across every domain, so a link can always fall back to the app's own path. */
    private function freeSlug(?string $wanted, ?string $except = null): string
    {
        if ($wanted !== null && $wanted !== '') {
            if (!preg_match(self::SLUG_PATTERN, $wanted)) {
                throw new LinkError('A slug is letters, digits, dashes, and underscores, up to 100', 'link_slug');
            }
            $taken = $this->runlight->store->linkBySlug($wanted);
            if ($taken !== null && $taken['id'] !== $except) {
                throw new LinkError("/$wanted is already taken", 'link_taken', ['slug' => $wanted]);
            }
            return $wanted;
        }
        for ($i = 0; $i < 8; $i++) {
            $slug = self::randomSlug();
            if ($this->runlight->store->linkBySlug($slug) === null) {
                return $slug;
            }
        }
        throw new LinkError('Could not find a free slug; try again', 'link_no_slug');
    }

    /** @param array{url?: mixed, name?: mixed, slug?: mixed, domain?: mixed} $input */
    public function create(string $site, array $input): array
    {
        $this->runlight->init();
        $url = self::cleanUrl($input['url'] ?? null);
        $domain = $this->domainFor($site, $input['domain'] ?? null);
        $slug = $this->freeSlug(isset($input['slug']) ? Js::trim(Js::string($input['slug'])) : null);
        $now = $this->runlight->now();
        $name = isset($input['name']) ? Js::trim(Js::string($input['name'])) : '';
        $link = [
            'id' => Hash::randomId(),
            'site' => $site,
            'domain' => $domain,
            'slug' => $slug,
            'name' => Js::slice($name !== '' ? $name : self::defaultName($url), 0, 100),
            'url' => $url,
            'createdAt' => $now,
            'updatedAt' => $now,
        ];
        $this->runlight->store->insertLink($link);
        return $link;
    }

    /** @param array{url?: mixed, name?: mixed, slug?: mixed, domain?: mixed} $input keys left out are left alone */
    public function update(string $id, array $input): array
    {
        $this->runlight->init();
        $link = $this->runlight->store->linkById($id);
        if ($link === null) {
            throw new \RangeException('Unknown link');
        }
        $next = $link;
        if (array_key_exists('url', $input)) {
            $next['url'] = self::cleanUrl($input['url']);
        }
        if (array_key_exists('name', $input)) {
            $name = Js::slice(Js::trim(Js::string($input['name'])), 0, 100);
            $next['name'] = $name !== '' ? $name : self::defaultName($next['url']);
        }
        // Keeping a link's domain needs no check, even while that domain is removed.
        if (array_key_exists('domain', $input) && Sources::stripWww(Js::trim(Js::string($input['domain']))) !== $link['domain']) {
            $next['domain'] = $this->domainFor($link['site'], $input['domain']);
        }
        if (array_key_exists('slug', $input)) {
            $next['slug'] = $this->freeSlug(Js::trim(Js::string($input['slug'])), $link['id']);
        }
        $next['updatedAt'] = $this->runlight->now();
        $this->runlight->store->updateLink($next);
        return $next;
    }

    public function remove(string $id): void
    {
        $this->runlight->init();
        if ($this->runlight->store->linkById($id) === null) {
            throw new \RangeException('Unknown link');
        }
        $this->runlight->store->deleteLink($id, $this->runlight->now());
    }

    /**
     * Creates many links at once, as from a CSV. Rows that fail are reported
     * with their reason and the rest go in. Headers match the Umami fork's
     * export: name or link_name, url or destination_url, slug or link_slug,
     * domain or tracking_domain.
     *
     * @param list<array<string, mixed>> $rows
     * @return array{created: int, failed: list<array{row: int, reason: string, code: string, params: \stdClass}>} params as an object, so an empty one is written {} as in TS
     */
    public function import(string $site, array $rows): array
    {
        $failed = [];
        $created = 0;
        foreach (array_values($rows) as $i => $raw) {
            $raw = $raw instanceof \stdClass ? (array) $raw : (is_array($raw) ? $raw : []);
            $pick = static function (string ...$keys) use ($raw): ?string {
                foreach ($keys as $key) {
                    $value = $raw[$key] ?? null;
                    if (is_string($value) && Js::trim($value) !== '') {
                        return Js::trim($value);
                    }
                }
                return null;
            };
            $input = ['url' => $pick('url', 'destination_url') ?? ''];
            foreach (['name' => ['name', 'link_name'], 'slug' => ['slug', 'link_slug'], 'domain' => ['domain', 'tracking_domain']] as $field => $keys) {
                $value = $pick(...$keys);
                if ($value !== null) {
                    $input[$field] = $value;
                }
            }
            try {
                $this->create($site, $input);
                $created++;
            } catch (LinkError $error) {
                // A bad row is reported and skipped; a failing database stops the whole import.
                $failed[] = ['row' => $i + 1, 'reason' => $error->getMessage(), 'code' => $error->code, 'params' => Json::object($error->params)];
            }
        }
        return ['created' => $created, 'failed' => $failed];
    }
}
