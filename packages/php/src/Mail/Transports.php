<?php

declare(strict_types=1);

namespace Runlight\Mail;

use Runlight\Hash;
use Runlight\Http\CurlFetcher;
use Runlight\Http\Fetcher;
use Runlight\Http\FetchError;
use Runlight\Http\SearchParams;
use Runlight\Http\Url;
use Runlight\Json;

/**
 * Sends mail through the service a site picked. A message is an array shaped as TS's Message:
 * `to`, `from`, `fromName` (optional), `subject`, `html`, `text`, and `headers` (optional extra
 * headers, such as List-Unsubscribe). A config is `service` plus its fields, every value a string,
 * as typed in the dashboard.
 *
 * @phpstan-type Message array{to: string, from: string, fromName?: string, subject: string, html: string, text: string, headers?: array<string, string>}
 */
final class Transports
{
    /** Every service Runlight can send through, and what each needs. */
    public const SERVICES = [
        ['id' => 'ses', 'name' => 'Amazon SES', 'fields' => [
            ['name' => 'region', 'label' => 'Region', 'placeholder' => 'us-east-1'],
            ['name' => 'accessKeyId', 'label' => 'Access key ID'],
            ['name' => 'secretAccessKey', 'label' => 'Secret access key', 'secret' => true],
        ]],
        ['id' => 'resend', 'name' => 'Resend', 'fields' => [['name' => 'apiKey', 'label' => 'API key', 'secret' => true, 'placeholder' => 're_...']]],
        ['id' => 'postmark', 'name' => 'Postmark', 'fields' => [
            ['name' => 'serverToken', 'label' => 'Server API token', 'secret' => true],
            ['name' => 'stream', 'label' => 'Message stream', 'optional' => true, 'placeholder' => 'outbound'],
        ]],
        ['id' => 'sendgrid', 'name' => 'SendGrid', 'fields' => [['name' => 'apiKey', 'label' => 'API key', 'secret' => true, 'placeholder' => 'SG....']]],
        ['id' => 'mailgun', 'name' => 'Mailgun', 'fields' => [
            ['name' => 'domain', 'label' => 'Sending domain', 'placeholder' => 'mg.example.com'],
            ['name' => 'apiKey', 'label' => 'API key', 'secret' => true],
            ['name' => 'region', 'label' => 'Region', 'options' => ['us', 'eu']],
        ]],
        ['id' => 'brevo', 'name' => 'Brevo', 'fields' => [['name' => 'apiKey', 'label' => 'API key', 'secret' => true, 'placeholder' => 'xkeysib-...']]],
        ['id' => 'mailjet', 'name' => 'Mailjet', 'fields' => [
            ['name' => 'apiKey', 'label' => 'API key'],
            ['name' => 'secretKey', 'label' => 'Secret key', 'secret' => true],
        ]],
        ['id' => 'mailersend', 'name' => 'MailerSend', 'fields' => [['name' => 'apiKey', 'label' => 'API token', 'secret' => true, 'placeholder' => 'mlsn....']]],
        ['id' => 'sparkpost', 'name' => 'SparkPost', 'fields' => [
            ['name' => 'apiKey', 'label' => 'API key', 'secret' => true],
            ['name' => 'region', 'label' => 'Region', 'options' => ['us', 'eu']],
        ]],
        ['id' => 'smtp', 'name' => 'SMTP', 'fields' => [
            ['name' => 'host', 'label' => 'Host', 'placeholder' => 'smtp.example.com'],
            ['name' => 'port', 'label' => 'Port', 'placeholder' => '587'],
            ['name' => 'security', 'label' => 'Security', 'options' => ['starttls', 'tls', 'none']],
            ['name' => 'username', 'label' => 'Username', 'optional' => true],
            ['name' => 'password', 'label' => 'Password', 'secret' => true, 'optional' => true],
        ]],
        ['id' => 'webhook', 'name' => 'Webhook', 'fields' => [
            ['name' => 'url', 'label' => 'URL', 'placeholder' => 'https://example.com/hooks/mail'],
            ['name' => 'secret', 'label' => 'Signing secret', 'secret' => true, 'optional' => true],
        ]],
    ];

    /** @param array<string, mixed> $m */
    public static function address(array $m): string
    {
        $name = (string) ($m['fromName'] ?? '');
        return $name !== '' ? str_replace(['"', '\\', "\r", "\n"], '', $name) . " <{$m['from']}>" : (string) $m['from'];
    }

    /**
     * The error a mail service explains itself with, from its JSON or XML reply,
     * and never the raw body: a reply is shown to the dashboard, so an address
     * that is not a mail service must not be able to put its page there.
     */
    public static function serviceMessage(string $reply): string
    {
        try {
            $parsed = Json::decode($reply);
        } catch (\JsonException) {
            $parsed = null;
        }
        // JSON.parse fails, or reading a field of null does, and either way the XML form is tried.
        if ($parsed === null) {
            return preg_match('#<Message>([^<]{1,200})</Message>#u', $reply, $m) ? self::trim($m[1]) : '';
        }
        $first = static function (mixed $v) use (&$first): string {
            if (is_string($v)) {
                return $v;
            }
            if (is_array($v)) {
                return $first($v[0] ?? null);
            }
            if ($v instanceof \stdClass) {
                return $first($v->message ?? null);
            }
            return '';
        };
        $field = static fn (string $name): mixed => $parsed instanceof \stdClass ? ($parsed->{$name} ?? null) : null;
        foreach (['message', 'Message', 'error', 'errors', 'ErrorMessage'] as $name) {
            $text = $first($field($name));
            if ($text !== '') {
                return self::slice16($text, 200);
            }
        }
        return '';
    }

    /**
     * POSTs to a service, with the errors the dashboard shows.
     *
     * @param array{headers: array<string, string>, body: string} $init
     */
    private static function post(Fetcher $fetcher, string $url, array $init, bool $explains = true): void
    {
        try {
            $response = $fetcher->fetch($url, ['method' => 'POST', 'headers' => $init['headers'], 'body' => $init['body'], 'timeoutMs' => 20_000]);
        } catch (FetchError $error) {
            $host = (new Url($url))->host();
            throw new MailError("Could not reach $host: {$error->getMessage()}", 'mail_unreachable', ['host' => $host, 'detail' => $error->getMessage()]);
        }
        if ($response->ok()) {
            return;
        }
        $message = $explains ? self::serviceMessage($response->text()) : '';
        $host = (new Url($url))->host();
        throw new MailError("$host answered {$response->status}" . ($message !== '' ? ": $message" : ''), 'mail_refused', ['host' => $host, 'detail' => $response->status . ($message !== '' ? " $message" : '')]);
    }

    /** @param array<string, string> $headers */
    private static function json(array $headers = []): array
    {
        return ['content-type' => 'application/json', ...$headers];
    }

    private static function basic(string $user, string $pass): string
    {
        return 'Basic ' . self::btoa("$user:$pass");
    }

    /** Checks a config has what its service needs, before anything is saved or sent. */
    public static function checkConfig(array $config): void
    {
        $service = null;
        foreach (self::SERVICES as $s) {
            if ($s['id'] === ($config['service'] ?? null)) {
                $service = $s;
            }
        }
        if ($service === null) {
            throw new MailError('Pick a mail service', 'mail_service', []);
        }
        foreach ($service['fields'] as $f) {
            $value = isset($config[$f['name']]) ? (string) $config[$f['name']] : null;
            if (empty($f['optional']) && ($value === null || self::trim($value) === '')) {
                throw new MailError('Enter the ' . mb_strtolower($f['label']), 'mail_field', ['field' => $f['name']]);
            }
            if (isset($f['options']) && $value !== null && $value !== '' && !in_array($value, $f['options'], true)) {
                $options = implode(', ', $f['options']);
                throw new MailError("{$f['label']} must be one of $options", 'mail_option', ['field' => $f['name'], 'options' => $options]);
            }
        }
        $url = (string) ($config['url'] ?? '');
        if ($config['service'] === 'webhook' && !preg_match('#^https://#', $url) && !preg_match('#^http://(localhost|127\.0\.0\.1)(:\d+)?(/|$)#', $url)) {
            throw new MailError('The webhook URL must use https', 'mail_https', []);
        }
    }

    /**
     * Sends one message through the configured service.
     *
     * @param array<string, string> $config
     * @param array<string, mixed> $m
     * @param int|null $now milliseconds, for SES's signature; the clock when null
     */
    public static function send(array $config, array $m, ?Fetcher $fetcher = null, ?int $now = null): void
    {
        self::checkConfig($config);
        $fetcher ??= new CurlFetcher();
        /** @var array<string, string> $headers */
        $headers = $m['headers'] ?? [];
        // Written as a JSON object even when empty, as TS's `m.headers ?? {}` is.
        $headersObject = (object) $headers;
        $hasName = ($m['fromName'] ?? '') !== '';
        switch ($config['service']) {
            case 'resend':
                self::post($fetcher, 'https://api.resend.com/emails', [
                    'headers' => self::json(['authorization' => "Bearer {$config['apiKey']}"]),
                    'body' => Json::encode(['from' => self::address($m), 'to' => [$m['to']], 'subject' => $m['subject'], 'html' => $m['html'], 'text' => $m['text'], 'headers' => $headersObject]),
                ]);
                return;
            case 'postmark':
                $list = [];
                foreach ($headers as $name => $value) {
                    $list[] = ['Name' => (string) $name, 'Value' => $value];
                }
                self::post($fetcher, 'https://api.postmarkapp.com/email', [
                    'headers' => self::json(['accept' => 'application/json', 'x-postmark-server-token' => $config['serverToken']]),
                    'body' => Json::encode([
                        'From' => self::address($m), 'To' => $m['to'], 'Subject' => $m['subject'], 'HtmlBody' => $m['html'], 'TextBody' => $m['text'],
                        'MessageStream' => ($config['stream'] ?? '') !== '' ? $config['stream'] : 'outbound',
                        'Headers' => $list,
                    ]),
                ]);
                return;
            case 'sendgrid':
                self::post($fetcher, 'https://api.sendgrid.com/v3/mail/send', [
                    'headers' => self::json(['authorization' => "Bearer {$config['apiKey']}"]),
                    'body' => Json::encode([
                        'personalizations' => [['to' => [['email' => $m['to']]]]],
                        'from' => ['email' => $m['from'], ...($hasName ? ['name' => $m['fromName']] : [])],
                        'subject' => $m['subject'],
                        'content' => [['type' => 'text/plain', 'value' => $m['text']], ['type' => 'text/html', 'value' => $m['html']]],
                        'headers' => $headersObject,
                    ]),
                ]);
                return;
            case 'mailgun':
                $form = new SearchParams(['from' => self::address($m), 'to' => $m['to'], 'subject' => $m['subject'], 'html' => $m['html'], 'text' => $m['text']]);
                foreach ($headers as $k => $v) {
                    $form->set("h:$k", $v);
                }
                $host = ($config['region'] ?? '') === 'eu' ? 'api.eu.mailgun.net' : 'api.mailgun.net';
                self::post($fetcher, "https://$host/v3/" . self::encodeURIComponent($config['domain']) . '/messages', [
                    'headers' => ['authorization' => self::basic('api', $config['apiKey']), 'content-type' => 'application/x-www-form-urlencoded'],
                    'body' => $form->toString(),
                ]);
                return;
            case 'brevo':
                self::post($fetcher, 'https://api.brevo.com/v3/smtp/email', [
                    'headers' => self::json(['api-key' => $config['apiKey'], 'accept' => 'application/json']),
                    'body' => Json::encode(['sender' => ['email' => $m['from'], ...($hasName ? ['name' => $m['fromName']] : [])], 'to' => [['email' => $m['to']]], 'subject' => $m['subject'], 'htmlContent' => $m['html'], 'textContent' => $m['text'], 'headers' => $headersObject]),
                ]);
                return;
            case 'mailjet':
                self::post($fetcher, 'https://api.mailjet.com/v3.1/send', [
                    'headers' => self::json(['authorization' => self::basic($config['apiKey'], $config['secretKey'])]),
                    'body' => Json::encode([
                        'Messages' => [['From' => ['Email' => $m['from'], ...($hasName ? ['Name' => $m['fromName']] : [])], 'To' => [['Email' => $m['to']]], 'Subject' => $m['subject'], 'TextPart' => $m['text'], 'HTMLPart' => $m['html'], 'Headers' => $headersObject]],
                    ]),
                ]);
                return;
            case 'mailersend':
                $list = [];
                foreach ($headers as $name => $value) {
                    $list[] = ['name' => (string) $name, 'value' => $value];
                }
                self::post($fetcher, 'https://api.mailersend.com/v1/email', [
                    'headers' => self::json(['authorization' => "Bearer {$config['apiKey']}"]),
                    'body' => Json::encode([
                        'from' => ['email' => $m['from'], ...($hasName ? ['name' => $m['fromName']] : [])], 'to' => [['email' => $m['to']]], 'subject' => $m['subject'], 'html' => $m['html'], 'text' => $m['text'],
                        ...($list !== [] ? ['headers' => $list] : []),
                    ]),
                ]);
                return;
            case 'sparkpost':
                self::post($fetcher, 'https://' . (($config['region'] ?? '') === 'eu' ? 'api.eu.sparkpost.com' : 'api.sparkpost.com') . '/api/v1/transmissions', [
                    'headers' => self::json(['authorization' => $config['apiKey']]),
                    'body' => Json::encode([
                        'recipients' => [['address' => ['email' => $m['to']]]],
                        'content' => ['from' => $hasName ? ['email' => $m['from'], 'name' => $m['fromName']] : $m['from'], 'subject' => $m['subject'], 'html' => $m['html'], 'text' => $m['text'], 'headers' => $headersObject],
                    ]),
                ]);
                return;
            case 'ses':
                Ses::send($config, $m, self::address($m), $fetcher, $now);
                return;
            case 'smtp':
                Smtp::send($config, $m, self::address($m));
                return;
            case 'webhook':
                $body = Json::encode(['to' => $m['to'], 'from' => $m['from'], 'fromName' => $m['fromName'] ?? '', 'subject' => $m['subject'], 'html' => $m['html'], 'text' => $m['text'], 'headers' => $headersObject]);
                $secret = (string) ($config['secret'] ?? '');
                $signature = $secret !== '' ? ['x-runlight-signature' => 'sha256=' . Hash::hmac($secret, $body)] : [];
                // A webhook can be any address, so only its status comes back.
                self::post($fetcher, $config['url'], ['headers' => self::json($signature), 'body' => $body], false);
                return;
        }
        throw new MailError("Unknown mail service \"{$config['service']}\"", 'mail_service', []);
    }

    /** JavaScript's encodeURIComponent. */
    public static function encodeURIComponent(string $text): string
    {
        return strtr(rawurlencode($text), ['%21' => '!', '%27' => "'", '%28' => '(', '%29' => ')', '%2A' => '*']);
    }

    /** JavaScript's String.prototype.trim, which also takes Unicode spaces. */
    public static function trim(string $text): string
    {
        return (string) preg_replace('/^[\s\x{FEFF}\x{A0}]+|[\s\x{FEFF}\x{A0}]+$/u', '', $text);
    }

    /** btoa(): base64 of Latin-1 text, refusing a character past U+00FF as the browser's does. */
    private static function btoa(string $text): string
    {
        if (preg_match('/[^\x00-\x7f]/', $text)) {
            if (preg_match('/[^\x{0}-\x{ff}]/u', $text)) {
                throw new \InvalidArgumentException('Invalid character');
            }
            $text = mb_convert_encoding($text, 'ISO-8859-1', 'UTF-8');
        }
        return base64_encode($text);
    }

    /** The first `$units` UTF-16 code units, as String.prototype.slice counts them. */
    public static function slice16(string $text, int $units): string
    {
        if (strlen($text) <= $units) {
            return $text;
        }
        $wide = mb_convert_encoding($text, 'UTF-16LE', 'UTF-8');
        if (strlen($wide) <= $units * 2) {
            return $text;
        }
        $cut = substr($wide, 0, $units * 2);
        // A pair cut in half keeps no half; JavaScript would keep a lone surrogate, which PHP cannot hold.
        $last = ord($cut[$units * 2 - 1]);
        if ($last >= 0xd8 && $last <= 0xdb) {
            $cut = substr($cut, 0, -2);
        }
        return mb_convert_encoding($cut, 'UTF-8', 'UTF-16LE');
    }
}
