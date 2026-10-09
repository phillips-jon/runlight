<?php

declare(strict_types=1);

namespace Runlight\Http;

/**
 * Outgoing requests, the PHP stand-in for JavaScript's fetch(). Everything
 * that calls another server (mail services, importers, connected installs,
 * the assistant's providers, site icons) goes through one, so tests can pass
 * a fake.
 *
 * `$init` takes the keys fetch's init does, where they apply:
 * - method: string, default GET
 * - headers: array<string, string> or Headers
 * - body: string
 * - redirect: "follow" (default) or "manual", which hands back the 3xx answer
 * - timeoutMs: int, the whole request's limit, default 30000
 * - maxBytes: int, stop reading past this and throw BodyTooLong
 * - truncate: bool, with maxBytes, hand back the first maxBytes instead of throwing (the start of a page)
 * - resolve: list<string> of "host:port:address" pins, so a checked address is the one connected to
 */
interface Fetcher
{
    /** @throws FetchError when no answer comes back (refused, timed out, bad TLS) */
    public function fetch(string $url, array $init = []): Response;
}
