<?php

declare(strict_types=1);

namespace Runlight\Http;

/** Fetches with PHP's curl extension, or with its stream wrapper when curl is missing. */
final class CurlFetcher implements Fetcher
{
    public function fetch(string $url, array $init = []): Response
    {
        if (!function_exists('curl_init')) {
            return $this->viaStreams($url, $init);
        }
        $method = strtoupper((string) ($init['method'] ?? 'GET'));
        $headers = $init['headers'] ?? [];
        $headers = $headers instanceof Headers ? $headers : new Headers($headers);
        $body = isset($init['body']) ? (string) $init['body'] : null;
        $maxBytes = isset($init['maxBytes']) ? (int) $init['maxBytes'] : null;
        $follow = ($init['redirect'] ?? 'follow') !== 'manual';

        $lines = [];
        foreach ($headers->all() as $name => $values) {
            foreach ($values as $value) {
                $lines[] = "$name: $value";
            }
        }
        $received = '';
        $tooLong = false;
        $responseHeaders = [];
        $status = 0;
        $handle = curl_init($url);
        curl_setopt_array($handle, [
            CURLOPT_CUSTOMREQUEST => $method,
            CURLOPT_HTTPHEADER => $lines,
            CURLOPT_FOLLOWLOCATION => $follow,
            CURLOPT_MAXREDIRS => 20,
            CURLOPT_TIMEOUT_MS => (int) ($init['timeoutMs'] ?? 30_000),
            CURLOPT_CONNECTTIMEOUT_MS => min((int) ($init['timeoutMs'] ?? 30_000), 15_000),
            CURLOPT_PROTOCOLS => CURLPROTO_HTTP | CURLPROTO_HTTPS,
            CURLOPT_REDIR_PROTOCOLS => CURLPROTO_HTTP | CURLPROTO_HTTPS,
            CURLOPT_ENCODING => '',
            CURLOPT_HEADERFUNCTION => static function ($curl, string $line) use (&$responseHeaders, &$status): int {
                if (preg_match('#^HTTP/\S+\s+(\d+)#', $line, $m)) {
                    // A new status line starts the next answer in a redirect chain.
                    $status = (int) $m[1];
                    $responseHeaders = [];
                } elseif (str_contains($line, ':')) {
                    [$name, $value] = explode(':', $line, 2);
                    $responseHeaders[strtolower(trim($name))][] = trim($value);
                }
                return strlen($line);
            },
            CURLOPT_WRITEFUNCTION => static function ($curl, string $chunk) use (&$received, &$tooLong, $maxBytes): int {
                if ($maxBytes !== null && strlen($received) + strlen($chunk) > $maxBytes) {
                    $tooLong = true;
                    return 0;
                }
                $received .= $chunk;
                return strlen($chunk);
            },
        ]);
        if ($body !== null && $method !== 'GET' && $method !== 'HEAD') {
            curl_setopt($handle, CURLOPT_POSTFIELDS, $body);
        }
        if ($method === 'HEAD') {
            curl_setopt($handle, CURLOPT_NOBODY, true);
        }
        if (!empty($init['resolve'])) {
            curl_setopt($handle, CURLOPT_RESOLVE, array_values($init['resolve']));
        }
        $ok = curl_exec($handle);
        $errno = curl_errno($handle);
        $error = curl_error($handle);
        curl_close($handle);
        if ($tooLong) {
            throw new BodyTooLong("Body over $maxBytes bytes");
        }
        if ($ok === false || $status === 0) {
            throw new FetchError($error !== '' ? $error : 'fetch failed', $errno === CURLE_OPERATION_TIMEDOUT);
        }
        return new Response($received, $status, $responseHeaders);
    }

    private function viaStreams(string $url, array $init): Response
    {
        $headers = $init['headers'] ?? [];
        $headers = $headers instanceof Headers ? $headers : new Headers($headers);
        $lines = [];
        foreach ($headers->all() as $name => $values) {
            foreach ($values as $value) {
                $lines[] = "$name: $value";
            }
        }
        $context = stream_context_create(['http' => [
            'method' => strtoupper((string) ($init['method'] ?? 'GET')),
            'header' => implode("\r\n", $lines),
            'content' => (string) ($init['body'] ?? ''),
            'timeout' => ((int) ($init['timeoutMs'] ?? 30_000)) / 1000,
            'ignore_errors' => true,
            'follow_location' => ($init['redirect'] ?? 'follow') !== 'manual' ? 1 : 0,
        ]]);
        $maxBytes = isset($init['maxBytes']) ? (int) $init['maxBytes'] : null;
        $stream = @fopen($url, 'rb', false, $context);
        if ($stream === false) {
            throw new FetchError('fetch failed');
        }
        $received = $maxBytes === null ? (string) stream_get_contents($stream) : (string) stream_get_contents($stream, $maxBytes + 1);
        $meta = stream_get_meta_data($stream);
        fclose($stream);
        if ($maxBytes !== null && strlen($received) > $maxBytes) {
            throw new BodyTooLong("Body over $maxBytes bytes");
        }
        $status = 0;
        $responseHeaders = [];
        foreach ($meta['wrapper_data'] ?? [] as $line) {
            if (preg_match('#^HTTP/\S+\s+(\d+)#', (string) $line, $m)) {
                $status = (int) $m[1];
                $responseHeaders = [];
            } elseif (str_contains((string) $line, ':')) {
                [$name, $value] = explode(':', (string) $line, 2);
                $responseHeaders[strtolower(trim($name))][] = trim($value);
            }
        }
        return new Response($received, $status, $responseHeaders);
    }
}
