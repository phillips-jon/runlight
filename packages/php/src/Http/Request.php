<?php

declare(strict_types=1);

namespace Runlight\Http;

/**
 * An incoming request, shaped like the Fetch API's Request so the routes read
 * the same as the TypeScript SDK's: an absolute URL, a method, headers, and a
 * body read once as text or JSON.
 */
final class Request
{
    public readonly string $method;
    public readonly Headers $headers;

    /** @param array<string, string|list<string>>|Headers $headers */
    public function __construct(
        public readonly string $url,
        string $method = 'GET',
        array|Headers $headers = [],
        private readonly string $body = '',
        /** The address the request came from, before any proxy header is read. */
        public readonly string $remoteAddress = '',
    ) {
        $this->method = strtoupper($method);
        $this->headers = new Headers($headers);
    }

    /**
     * The request PHP is serving now. The scheme and host come from the server's own variables;
     * the client's address is REMOTE_ADDR, and proxy headers are read later, only when trusted.
     */
    public static function fromGlobals(): self
    {
        $https = ($_SERVER['HTTPS'] ?? '') !== '' && strtolower((string) $_SERVER['HTTPS']) !== 'off';
        $scheme = $https ? 'https' : 'http';
        $host = (string) ($_SERVER['HTTP_HOST'] ?? $_SERVER['SERVER_NAME'] ?? 'localhost');
        $uri = (string) ($_SERVER['REQUEST_URI'] ?? '/');
        $headers = [];
        foreach ($_SERVER as $key => $value) {
            if (str_starts_with((string) $key, 'HTTP_')) {
                $headers[str_replace('_', '-', strtolower(substr((string) $key, 5)))] = (string) $value;
            }
        }
        // Apache under CGI or FPM passes Authorization only when a rewrite rule copies it, under this name.
        if (!isset($headers['authorization']) && isset($_SERVER['REDIRECT_HTTP_AUTHORIZATION'])) {
            $headers['authorization'] = (string) $_SERVER['REDIRECT_HTTP_AUTHORIZATION'];
        }
        if (isset($_SERVER['CONTENT_TYPE'])) {
            $headers['content-type'] = (string) $_SERVER['CONTENT_TYPE'];
        }
        if (isset($_SERVER['CONTENT_LENGTH'])) {
            $headers['content-length'] = (string) $_SERVER['CONTENT_LENGTH'];
        }
        $method = (string) ($_SERVER['REQUEST_METHOD'] ?? 'GET');
        $body = '';
        if (!in_array(strtoupper($method), ['GET', 'HEAD'], true)) {
            $input = fopen('php://input', 'rb');
            $body = $input === false ? '' : self::readBody($input, $uri, $headers['content-length'] ?? null);
        }
        return new self("$scheme://$host$uri", $method, $headers, $body, (string) ($_SERVER['REMOTE_ADDR'] ?? ''));
    }

    /**
     * A request body read from a stream, up to the limit for its path, as the Node adapter reads one: 16 KB for
     * the collect endpoint, whose payloads are under 8 KB, and 10 MB for the rest, such as a link import of 5,000
     * rows. One byte past the limit is all that is read, so a larger body never fills memory.
     *
     * @param resource $stream
     * @throws BodyTooLarge past the limit, for a 413
     */
    public static function readBody($stream, string $target, ?string $declared = null): string
    {
        $limit = preg_match('#/e$#D', (string) parse_url($target, PHP_URL_PATH)) ? 16 * 1024 : 10 * 1024 * 1024;
        if ($declared !== null && is_numeric(trim($declared)) && (float) trim($declared) > $limit) {
            throw new BodyTooLarge("Request body over $limit bytes");
        }
        $body = (string) stream_get_contents($stream, $limit + 1);
        if (strlen($body) > $limit) {
            throw new BodyTooLarge("Request body over $limit bytes");
        }
        return $body;
    }

    /** The answer to a body past its limit. The rest of the upload is unread, so the connection is not reused. */
    public static function tooLarge(): Response
    {
        return new Response('{"error":"That request is too large"}', 413, [
            'content-type' => 'application/json; charset=utf-8',
            'cache-control' => 'no-store',
            'connection' => 'close',
        ]);
    }

    public function text(): string
    {
        return $this->body;
    }

    /** The body as JSON. Throws \JsonException when it is not. */
    public function json(): mixed
    {
        return json_decode($this->body, false, 512, JSON_THROW_ON_ERROR | JSON_BIGINT_AS_STRING);
    }

    public function url(): Url
    {
        return new Url($this->url);
    }

    /** The same request with other parts, as `new Request(request, init)` makes one. */
    public function with(?string $url = null, ?string $method = null, ?Headers $headers = null, ?string $body = null): self
    {
        return new self($url ?? $this->url, $method ?? $this->method, $headers ?? $this->headers, $body ?? $this->body, $this->remoteAddress);
    }
}
