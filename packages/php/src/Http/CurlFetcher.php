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
        $truncate = !empty($init['truncate']);
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
            CURLOPT_WRITEFUNCTION => static function ($curl, string $chunk) use (&$received, &$tooLong, $maxBytes, $truncate): int {
                if ($maxBytes !== null && strlen($received) + strlen($chunk) > $maxBytes) {
                    $tooLong = true;
                    if ($truncate) {
                        $received .= substr($chunk, 0, $maxBytes - strlen($received));
                    }
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
        if ($tooLong && $truncate && $status !== 0) {
            return new Response($received, $status, $responseHeaders);
        }
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
        $headers = new Headers($init['headers'] ?? []);
        $ssl = [];
        // A pin connects to the checked address, with the name kept for the Host header and the certificate.
        foreach ($init['resolve'] ?? [] as $pin) {
            $parsed = Url::parse($url);
            if ($parsed !== null && preg_match('/^(.+):(\d+):\[?([^\],]+)\]?/', (string) $pin, $m) && strcasecmp($m[1], $parsed->hostname) === 0) {
                if (!$headers->has('host')) {
                    $headers->set('host', $parsed->host());
                }
                $ssl = ['peer_name' => $parsed->hostname, 'SNI_enabled' => true];
                $address = str_contains($m[3], ':') ? "[{$m[3]}]" : $m[3];
                $url = $parsed->protocol . '//' . $address . ($parsed->port !== '' ? ":{$parsed->port}" : '') . $parsed->pathname . $parsed->search;
                break;
            }
        }
        $lines = [];
        foreach ($headers->all() as $name => $values) {
            foreach ($values as $value) {
                $lines[] = "$name: $value";
            }
        }
        $context = stream_context_create(['ssl' => $ssl, 'http' => [
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
        if ($maxBytes !== null && strlen($received) > $maxBytes && !empty($init['truncate'])) {
            $received = substr($received, 0, $maxBytes);
        } elseif ($maxBytes !== null && strlen($received) > $maxBytes) {
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
