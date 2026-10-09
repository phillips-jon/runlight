<?php

declare(strict_types=1);

namespace Runlight\Mail;

/**
 * A small SMTP client: implicit TLS (465), STARTTLS (587), or plain (local
 * relays), with AUTH PLAIN, over stream_socket_client.
 */
final class Smtp
{
    /** Each reply must come within this long. */
    private const REPLY_TIMEOUT_MS = 20_000;

    private static function encodeWord(string $text): string
    {
        return preg_match('/^[\x20-\x7e]*$/', $text) ? $text : '=?UTF-8?B?' . base64_encode($text) . '?=';
    }

    /** Base64 in lines of 76, each ending in CRLF, as `.replace(/.{1,76}/g, "$&\r\n")` writes it. */
    private static function wrap(string $text): string
    {
        return $text === '' ? '' : chunk_split($text, 76, "\r\n");
    }

    /** A random version 4 UUID, as crypto.randomUUID() gives. */
    private static function randomUuid(): string
    {
        $b = random_bytes(16);
        $b[6] = chr((ord($b[6]) & 0x0f) | 0x40);
        $b[8] = chr((ord($b[8]) & 0x3f) | 0x80);
        $hex = bin2hex($b);
        return substr($hex, 0, 8) . '-' . substr($hex, 8, 4) . '-' . substr($hex, 12, 4) . '-' . substr($hex, 16, 4) . '-' . substr($hex, 20);
    }

    /**
     * The message as MIME: text and HTML alternatives, both base64. Public for its test.
     *
     * @param array<string, mixed> $m
     * @param int|null $now milliseconds; the clock when null
     * @param (\Closure(): string)|null $uuid stands in for crypto.randomUUID() in tests
     */
    public static function mime(array $m, string $from, ?int $now = null, ?\Closure $uuid = null): string
    {
        $uuid ??= self::randomUuid(...);
        $now ??= (int) floor(microtime(true) * 1000);
        $boundary = 'rl-' . $uuid();
        $domain = explode('@', (string) $m['from'])[1] ?? 'runlight.local';
        $fromHeader = preg_match('/^(.*)<(.+)>$/', $from, $named) ? self::encodeWord(Transports::trim($named[1])) . " <{$named[2]}>" : $from;
        $headers = [
            "From: $fromHeader",
            "To: {$m['to']}",
            'Subject: ' . self::encodeWord((string) $m['subject']),
            // Date's toUTCString(), with +0000 for GMT.
            'Date: ' . gmdate('D, d M Y H:i:s', (int) floor($now / 1000)) . ' +0000',
            'Message-ID: <' . $uuid() . "@$domain>",
            'MIME-Version: 1.0',
        ];
        foreach ($m['headers'] ?? [] as $k => $v) {
            $headers[] = "$k: " . str_replace(["\r", "\n"], '', (string) $v);
        }
        $headers[] = "Content-Type: multipart/alternative; boundary=\"$boundary\"";
        return implode("\r\n", [
            implode("\r\n", $headers),
            '',
            "--$boundary",
            'Content-Type: text/plain; charset=utf-8',
            'Content-Transfer-Encoding: base64',
            '',
            self::wrap(base64_encode((string) $m['text'])),
            "--$boundary",
            'Content-Type: text/html; charset=utf-8',
            'Content-Transfer-Encoding: base64',
            '',
            self::wrap(base64_encode((string) $m['html'])),
            "--$boundary--",
            '',
        ]);
    }

    /**
     * Sends one message. Each reply must come within 20 s, and the whole send
     * within the deadline (60 s), so a server that trickles a line now and then
     * cannot hold the scheduled check that sends reports. Its deadline is a
     * parameter for its test, as are the clock and UUIDs the MIME is written with.
     *
     * @param array<string, string> $config
     * @param array<string, mixed> $m
     */
    public static function send(array $config, array $m, string $from, int $deadline = 60_000, ?int $now = null, ?\Closure $uuid = null): void
    {
        $host = Transports::trim((string) $config['host']);
        $security = ($config['security'] ?? '') !== '' ? $config['security'] : 'starttls';
        $port = self::number((string) ($config['port'] ?? ''));
        $port = is_nan($port) || $port == 0 ? ($security === 'tls' ? 465 : 587) : (int) $port;
        $session = new SmtpSession($host, $port, hrtime(true) + $deadline * 1_000_000, "SMTP: $host:$port took longer than " . (int) floor($deadline / 1000 + 0.5) . ' s');
        try {
            self::converse($session, $config, $m, $from, $security, $now, $uuid);
        } finally {
            $session->close();
        }
    }

    private static function converse(SmtpSession $s, array $config, array $m, string $from, string $security, ?int $now, ?\Closure $uuid): void
    {
        $s->connect($security === 'tls', self::REPLY_TIMEOUT_MS);
        $expect = static function (array $codes, string $what) use ($s): array {
            $reply = $s->next(self::REPLY_TIMEOUT_MS);
            if (!in_array($reply['code'], $codes, true)) {
                throw new MailError(Transports::slice16("SMTP $what: {$reply['code']} {$reply['text']}", 300));
            }
            return $reply;
        };
        $expect([220], 'greeting');
        $name = (string) preg_replace('/>$/', '', explode('@', $from)[1] ?? '');
        $name = $name !== '' ? $name : 'localhost';
        $s->write("EHLO $name");
        $ehlo = $expect([250], 'EHLO');
        if ($security === 'starttls') {
            if (!preg_match('/STARTTLS/i', $ehlo['text'])) {
                throw new MailError('SMTP: the server does not offer STARTTLS; pick tls or none', 'smtp_starttls', []);
            }
            $s->write('STARTTLS');
            $expect([220], 'STARTTLS');
            $s->startTls();
            $s->write("EHLO $name");
            $expect([250], 'EHLO');
        }
        if (($config['username'] ?? '') !== '') {
            $s->write('AUTH PLAIN ' . base64_encode("\0{$config['username']}\0" . ($config['password'] ?? '')));
            $expect([235], 'sign-in');
        }
        $s->write("MAIL FROM:<{$m['from']}>");
        $expect([250], 'MAIL FROM');
        $s->write("RCPT TO:<{$m['to']}>");
        $expect([250, 251], 'RCPT TO');
        $s->write('DATA');
        $expect([354], 'DATA');
        // A line starting with a dot gets a second one, so it is not read as the end.
        $s->writeRaw(str_replace("\r\n.", "\r\n..", self::mime($m, $from, $now, $uuid)) . "\r\n.\r\n");
        $expect([250], 'message');
        $s->write('QUIT');
        // Wait for the goodbye, but never fail a sent message over it.
        try {
            $s->next(2000, true);
        } catch (MailError $error) {
            if ($error->code === 'mail_slow') {
                throw $error;
            }
        }
    }

    /** JavaScript's Number() for the port as typed: NaN for anything that is not a number. */
    private static function number(string $text): float
    {
        $text = Transports::trim($text);
        if ($text === '') {
            return 0;
        }
        if (preg_match('/^0[xX][0-9a-fA-F]+$/', $text)) {
            return (float) hexdec(substr($text, 2));
        }
        if (preg_match('/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/', $text)) {
            return (float) $text;
        }
        return NAN;
    }
}
