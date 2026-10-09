<?php

declare(strict_types=1);

namespace Runlight\Tests\Conformance;

use Runlight\Http\BodyTooLong;
use Runlight\Http\Fetcher;
use Runlight\Http\FetchError;
use Runlight\Http\Headers;
use Runlight\Http\Response;
use Runlight\Http\SearchParams;
use Runlight\Json;

/**
 * The servers a scenario stands in for, as the fake fetch in http-conformance.ts
 * plays them: a request goes to the first upstream whose url its URL starts with
 * (and whose method matches, when one is given); a request none matches fails as
 * a network error does. Every request is recorded, matched or not.
 */
final class UpstreamFetcher implements Fetcher
{
    /** @var list<array{seen: \stdClass, text: string}> */
    private array $fetched = [];

    /** @param list<\stdClass> $upstream the scenario's upstream entries, as Json::decode gives them */
    public function __construct(private readonly array $upstream)
    {
    }

    public function fetch(string $url, array $init = []): Response
    {
        $method = strtoupper((string) ($init['method'] ?? 'GET'));
        $given = [];
        foreach (new Headers($init['headers'] ?? []) as $name => $value) {
            $given[$name] = $value;
        }
        ksort($given, SORT_STRING);
        $text = (string) ($init['body'] ?? '');
        $seen = new \stdClass();
        $seen->method = $method;
        $seen->url = $url;
        if ($given !== []) {
            $seen->headers = (object) $given;
        }
        if ($text !== '') {
            $seen->body = self::sentBody($text, $given['content-type'] ?? '');
        }
        $this->fetched[] = ['seen' => $seen, 'text' => $text];

        $match = null;
        foreach ($this->upstream as $u) {
            if (str_starts_with($url, (string) $u->url) && (empty($u->method) || $u->method === $method)) {
                $match = $u;
                break;
            }
        }
        if ($match === null) {
            throw new FetchError('fetch failed');
        }
        $hasBody = property_exists($match, 'body');
        $body = !$hasBody ? '' : (is_string($match->body) ? $match->body : Json::encode($match->body));
        // typeof null is "object" too, so a null body is sent as JSON.
        $headers = $hasBody && !is_string($match->body) && !is_int($match->body) && !is_float($match->body) && !is_bool($match->body)
            ? ['content-type' => 'application/json']
            : [];
        foreach (get_object_vars($match->headers ?? new \stdClass()) as $name => $value) {
            $headers[$name] = (string) $value;
        }
        // The cap a real Fetcher keeps, so code that reads only the start of a page sees what it would.
        $maxBytes = isset($init['maxBytes']) ? (int) $init['maxBytes'] : null;
        if ($maxBytes !== null && strlen($body) > $maxBytes) {
            if (empty($init['truncate'])) {
                throw new BodyTooLong("Body over $maxBytes bytes");
            }
            $body = substr($body, 0, $maxBytes);
        }
        return new Response($body, (int) ($match->status ?? 200), $headers);
    }

    /**
     * The requests made since the last take, and forgets them.
     *
     * @return list<array{seen: \stdClass, text: string}>
     */
    public function take(): array
    {
        $out = $this->fetched;
        $this->fetched = [];
        return $out;
    }

    /** A body another server was sent, as JSON or form fields when it is one of those, else its text. */
    public static function sentBody(string $text, string $type): mixed
    {
        if (str_starts_with($type, 'application/x-www-form-urlencoded')) {
            $fields = new \stdClass();
            foreach (new SearchParams($text) as $name => $value) {
                $fields->{$name} = $value;
            }
            return $fields;
        }
        try {
            return Json::decode($text);
        } catch (\JsonException) {
            return $text;
        }
    }
}
