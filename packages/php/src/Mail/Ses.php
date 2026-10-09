<?php

declare(strict_types=1);

namespace Runlight\Mail;

use Runlight\Http\CurlFetcher;
use Runlight\Http\Fetcher;
use Runlight\Http\FetchError;
use Runlight\Http\Url;
use Runlight\Json;

/**
 * Amazon SES (API v2) with a hand-rolled Signature Version 4, so there is no
 * AWS SDK to install. https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html
 */
final class Ses
{
    /**
     * Signs a request; public for its test against AWS's published example.
     *
     * @param array{method: string, url: string|Url, body: string, region: string, service: string, accessKeyId: string, secretAccessKey: string, now: int, headers: array<string, string>} $input
     *        `now` is in milliseconds
     * @return array<string, string>
     */
    public static function signV4(array $input): array
    {
        $url = $input['url'] instanceof Url ? $input['url'] : new Url($input['url']);
        $amzDate = gmdate('Ymd\THis\Z', intdiv($input['now'], 1000) - ($input['now'] % 1000 < 0 ? 1 : 0));
        $day = substr($amzDate, 0, 8);
        $payloadHash = hash('sha256', $input['body']);
        $headers = [...$input['headers'], 'host' => $url->host(), 'x-amz-date' => $amzDate];
        $names = array_map(static fn ($h) => strtolower((string) $h), array_keys($headers));
        sort($names, SORT_STRING);
        $lower = [];
        foreach ($headers as $k => $v) {
            $lower[strtolower((string) $k)] = (string) preg_replace('/\s+/u', ' ', Transports::trim($v));
        }
        $path = implode('/', array_map(static fn ($p) => Transports::encodeURIComponent(rawurldecode($p)), explode('/', $url->pathname)));
        $pairs = [];
        foreach ($url->searchParams() as $k => $v) {
            $pairs[] = [(string) $k, $v];
        }
        // A stable sort on the name alone, as Array.prototype.sort is.
        usort($pairs, static fn ($a, $b) => strcmp($a[0], $b[0]));
        $canonical = implode("\n", [
            $input['method'],
            $path !== '' ? $path : '/',
            implode('&', array_map(static fn ($p) => Transports::encodeURIComponent($p[0]) . '=' . Transports::encodeURIComponent($p[1]), $pairs)),
            implode('', array_map(static fn ($n) => "$n:{$lower[$n]}\n", $names)),
            implode(';', $names),
            $payloadHash,
        ]);
        $scope = "$day/{$input['region']}/{$input['service']}/aws4_request";
        $toSign = implode("\n", ['AWS4-HMAC-SHA256', $amzDate, $scope, hash('sha256', $canonical)]);
        $key = hash_hmac('sha256', $day, "AWS4{$input['secretAccessKey']}", true);
        $key = hash_hmac('sha256', $input['region'], $key, true);
        $key = hash_hmac('sha256', $input['service'], $key, true);
        $key = hash_hmac('sha256', 'aws4_request', $key, true);
        $signature = hash_hmac('sha256', $toSign, $key);
        return [
            ...$headers,
            'authorization' => "AWS4-HMAC-SHA256 Credential={$input['accessKeyId']}/$scope, SignedHeaders=" . implode(';', $names) . ", Signature=$signature",
        ];
    }

    /**
     * @param array<string, string> $config
     * @param array<string, mixed> $m
     * @param int|null $now milliseconds; the clock when null
     */
    public static function send(array $config, array $m, string $from, ?Fetcher $fetcher = null, ?int $now = null): void
    {
        $region = Transports::trim((string) $config['region']);
        if (!preg_match('/^[a-z]{2}(-[a-z]+)+-\d$/', $region)) {
            throw new MailError('That is not an AWS region, like us-east-1', 'mail_region', []);
        }
        $url = new Url("https://email.$region.amazonaws.com/v2/email/outbound-emails");
        $headerList = [];
        foreach ($m['headers'] ?? [] as $name => $value) {
            $headerList[] = ['Name' => (string) $name, 'Value' => $value];
        }
        $body = Json::encode([
            'FromEmailAddress' => $from,
            'Destination' => ['ToAddresses' => [$m['to']]],
            'Content' => [
                'Simple' => [
                    'Subject' => ['Data' => $m['subject'], 'Charset' => 'UTF-8'],
                    'Body' => ['Html' => ['Data' => $m['html'], 'Charset' => 'UTF-8'], 'Text' => ['Data' => $m['text'], 'Charset' => 'UTF-8']],
                    'Headers' => $headerList,
                ],
            ],
        ]);
        $headers = self::signV4([
            'method' => 'POST',
            'url' => $url,
            'body' => $body,
            'region' => $region,
            'service' => 'ses',
            'accessKeyId' => Transports::trim((string) $config['accessKeyId']),
            'secretAccessKey' => Transports::trim((string) $config['secretAccessKey']),
            'now' => $now ?? (int) floor(microtime(true) * 1000),
            'headers' => ['content-type' => 'application/json'],
        ]);
        unset($headers['host']);
        try {
            $response = ($fetcher ?? new CurlFetcher())->fetch($url->href(), ['method' => 'POST', 'headers' => $headers, 'body' => $body, 'timeoutMs' => 20_000]);
        } catch (FetchError $error) {
            throw new MailError("Could not reach Amazon SES: {$error->getMessage()}", 'mail_unreachable', ['host' => 'Amazon SES', 'detail' => $error->getMessage()]);
        }
        if (!$response->ok()) {
            $message = Transports::serviceMessage($response->text());
            throw new MailError("Amazon SES answered {$response->status}" . ($message !== '' ? ": $message" : ''), 'mail_refused', ['host' => 'Amazon SES', 'detail' => $response->status . ($message !== '' ? " $message" : '')]);
        }
    }
}
