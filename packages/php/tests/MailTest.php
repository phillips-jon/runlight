<?php

declare(strict_types=1);

namespace Runlight\Tests;

use PHPUnit\Framework\TestCase;
use Runlight\Http\FetchError;
use Runlight\Http\Response;
use Runlight\Json;
use Runlight\Mail\MailError;
use Runlight\Mail\Secret;
use Runlight\Mail\Ses;
use Runlight\Mail\Smtp;
use Runlight\Mail\Transports;
use Runlight\Tests\Support\FakeFetcher;
use Runlight\Tests\Support\SmtpServer;

/** Ports mail.test.ts, and replays tests/fixtures/outbound.json: every service sends the TypeScript SDK's exact requests. */
final class MailTest extends TestCase
{
    private const MESSAGE = ['to' => 'jon@example.com', 'from' => 'reports@example.com', 'fromName' => 'Runlight', 'subject' => 'Hello', 'html' => '<p>Hi</p>', 'text' => 'Hi', 'headers' => ['List-Unsubscribe' => '<https://x/u>']];

    private static ?array $fixture = null;

    public static function fixture(): array
    {
        return self::$fixture ??= Json::decode((string) file_get_contents(__DIR__ . '/fixtures/outbound.json'), true);
    }

    private static function capture(int $status = 200): FakeFetcher
    {
        return new FakeFetcher(static fn () => new Response($status === 200 ? '{}' : 'nope', $status));
    }

    /** A UUID stand-in that counts from 1, as the fixture script's does. */
    private static function uuids(): \Closure
    {
        $n = 0;
        return static function () use (&$n): string {
            return sprintf('00000000-0000-4000-8000-%012d', ++$n);
        };
    }

    public function testSealedKeysOpenOnlyWithTheSameSecret(): void
    {
        $sealed = Secret::seal('{"apiKey":"re_123"}', 'server secret');
        $this->assertTrue(str_starts_with($sealed, 'v1:') && !str_contains($sealed, 're_123'));
        $this->assertSame('{"apiKey":"re_123"}', Secret::unseal($sealed, 'server secret'));
        $this->assertNull(Secret::unseal($sealed, 'another secret'));
        $this->assertSame('x', Secret::unseal(Secret::seal('x', null), null), 'with no secret the value is kept as typed');
        $this->assertNull(Secret::unseal('v1:AAAA:AAAA', 'server secret'), 'damaged');
        $this->assertNull(Secret::unseal('v2:a:b', 'server secret'));
        $this->assertNull(Secret::unseal($sealed, null));
    }

    public function testKeysSealedByTypeScriptOpenHere(): void
    {
        foreach (self::fixture()['sealed'] as $case) {
            $this->assertSame($case['value'], Secret::unseal($case['sealed'], $case['secret']));
            $this->assertNull(Secret::unseal($case['sealed'], "{$case['secret']}!"));
            $this->assertSame($case['value'], Secret::unseal(Secret::seal($case['value'], $case['secret']), $case['secret']));
        }
    }

    public function testSigV4MatchesAwsPublishedExample(): void
    {
        // https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html (the IAM ListUsers example)
        $headers = Ses::signV4([
            'method' => 'GET',
            'url' => 'https://iam.amazonaws.com/?Action=ListUsers&Version=2010-05-08',
            'body' => '',
            'region' => 'us-east-1',
            'service' => 'iam',
            'accessKeyId' => 'AKIDEXAMPLE',
            'secretAccessKey' => 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
            'now' => (new \DateTimeImmutable('2015-08-30T12:36:00Z'))->getTimestamp() * 1000,
            'headers' => ['content-type' => 'application/x-www-form-urlencoded; charset=utf-8'],
        ]);
        $this->assertSame(
            'AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/iam/aws4_request, SignedHeaders=content-type;host;x-amz-date, Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7',
            $headers['authorization'],
        );
    }

    public function testSigV4MatchesTypeScript(): void
    {
        foreach (self::fixture()['signatures'] as $case) {
            $this->assertSame($case['headers'], Ses::signV4($case['input']), $case['input']['url']);
        }
    }

    public function testEachServiceGetsTheRequestItDocuments(): void
    {
        $calls = self::capture();
        Transports::send(['service' => 'resend', 'apiKey' => 're_1'], self::MESSAGE, $calls);
        $this->assertSame('https://api.resend.com/emails', $calls->requests[0]['url']);
        $this->assertSame('Bearer re_1', $calls->requests[0]['headers']['authorization']);
        $this->assertSame(['jon@example.com'], Json::decode($calls->requests[0]['body'], true)['to']);
        $this->assertSame('Runlight <reports@example.com>', Json::decode($calls->requests[0]['body'], true)['from']);

        $calls = self::capture();
        Transports::send(['service' => 'postmark', 'serverToken' => 'pm'], self::MESSAGE, $calls);
        $this->assertSame('pm', $calls->requests[0]['headers']['x-postmark-server-token']);
        $this->assertSame('outbound', Json::decode($calls->requests[0]['body'], true)['MessageStream']);

        $calls = self::capture();
        Transports::send(['service' => 'mailgun', 'apiKey' => 'key', 'domain' => 'mg.example.com', 'region' => 'eu'], self::MESSAGE, $calls);
        $this->assertSame('https://api.eu.mailgun.net/v3/mg.example.com/messages', $calls->requests[0]['url']);
        $this->assertSame('Basic ' . base64_encode('api:key'), $calls->requests[0]['headers']['authorization']);
        $this->assertSame('<https://x/u>', (new \Runlight\Http\SearchParams($calls->requests[0]['body']))->get('h:List-Unsubscribe'));

        $calls = self::capture();
        Transports::send(['service' => 'ses', 'region' => 'eu-west-1', 'accessKeyId' => 'AKID', 'secretAccessKey' => 'secret'], self::MESSAGE, $calls);
        $this->assertSame('https://email.eu-west-1.amazonaws.com/v2/email/outbound-emails', $calls->requests[0]['url']);
        $this->assertMatchesRegularExpression('#^AWS4-HMAC-SHA256 Credential=AKID/\d{8}/eu-west-1/ses/aws4_request#', $calls->requests[0]['headers']['authorization']);

        $calls = self::capture();
        Transports::send(['service' => 'webhook', 'url' => 'https://hooks.example.com/mail', 'secret' => 's'], self::MESSAGE, $calls);
        $this->assertMatchesRegularExpression('/^sha256=[a-f0-9]{64}$/', $calls->requests[0]['headers']['x-runlight-signature']);

        $refused = self::capture(401);
        $this->assertThrowsMatching('/api.sendgrid.com answered 401/', fn () => Transports::send(['service' => 'sendgrid', 'apiKey' => 'bad'], self::MESSAGE, $refused));
        $this->assertThrowsMatching('/must use https/', fn () => Transports::send(['service' => 'webhook', 'url' => 'http://example.com/x'], self::MESSAGE, $refused));
        $this->assertThrowsMatching('/Enter the api key/', fn () => Transports::send(['service' => 'resend'], self::MESSAGE, $refused));
    }

    public function testEveryServiceSendsTheTypeScriptRequestsExactly(): void
    {
        $now = self::fixture()['now'];
        foreach (self::fixture()['mail'] as $i => $case) {
            $answer = $case['answer'];
            $fetcher = new FakeFetcher(static function () use ($answer): Response {
                if ($answer === 'unreachable') {
                    throw new FetchError('fetch failed');
                }
                return new Response($answer['body'], $answer['status']);
            });
            $error = null;
            try {
                Transports::send($case['config'], $case['message'], $fetcher, $now);
            } catch (MailError $e) {
                $error = ['message' => $e->getMessage(), 'code' => $e->code, 'params' => $e->params];
            }
            $label = "case $i: " . Json::encode($case['config']);
            $this->assertSame($case['requests'], $fetcher->requests, $label);
            $this->assertSame($case['error'], $error, $label);
        }
    }

    public function testServiceMessagesMatchTypeScript(): void
    {
        foreach (self::fixture()['replies'] as $case) {
            $this->assertSame($case['message'], Transports::serviceMessage($case['reply']), $case['reply']);
        }
    }

    public function testMimeMatchesTypeScript(): void
    {
        foreach (self::fixture()['mimes'] as $case) {
            $this->assertSame($case['mime'], Smtp::mime($case['message'], $case['from'], $case['now'], self::uuids()));
        }
        $raw = Smtp::mime([...self::MESSAGE, 'subject' => "Caf\u{e9} report"], 'Runlight <reports@example.com>');
        $this->assertMatchesRegularExpression('/Subject: =\?UTF-8\?B\?/', $raw);
        $this->assertMatchesRegularExpression('/boundary="rl-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"/', $raw);
    }

    public function testSmtpSendsTheTypeScriptConversation(): void
    {
        $server = new SmtpServer();
        try {
            foreach (self::fixture()['smtp'] as $case) {
                $error = null;
                try {
                    Smtp::send([...$case['config'], 'service' => 'smtp', 'host' => '127.0.0.1', 'port' => (string) $server->port], $case['message'], $case['from'], 60_000, self::fixture()['now'], self::uuids());
                } catch (MailError $e) {
                    $error = ['message' => $e->getMessage(), 'code' => $e->code, 'params' => $e->params];
                }
                $this->assertSame($case['error'], $error);
                $this->assertSame($case['received'], $server->conversation()['received'] ?? null);
            }
        } finally {
            $server->stop();
        }
    }

    public function testSmtpStartTlsRefusedIsAnErrorAndAPlainRelayTakesTheMessage(): void
    {
        $server = new SmtpServer();
        try {
            $config = ['service' => 'smtp', 'host' => '127.0.0.1', 'port' => (string) $server->port];
            $this->assertThrowsMatching('/does not offer STARTTLS/', fn () => Smtp::send([...$config, 'security' => 'starttls'], self::MESSAGE, 'reports@example.com'));
            $server->conversation();
            Smtp::send([...$config, 'security' => 'none', 'username' => 'jon', 'password' => 'pw'], [...self::MESSAGE, 'text' => '.starts with a dot'], 'Runlight <reports@example.com>');
            $received = $server->conversation()['received'];
            $seen = [];
            $inData = false;
            $data = '';
            foreach (explode("\r\n", $received) as $line) {
                if ($inData) {
                    if ($line === '.') {
                        $inData = false;
                    } else {
                        $data .= "$line\n";
                    }
                    continue;
                }
                if ($line !== '') {
                    $seen[] = explode(' ', $line)[0];
                }
                $inData = $line === 'DATA';
            }
            $this->assertSame(['EHLO', 'AUTH', 'MAIL', 'RCPT', 'DATA', 'QUIT'], $seen);
            $this->assertMatchesRegularExpression('/Subject: Hello/', $data);
            $this->assertMatchesRegularExpression('#List-Unsubscribe: <https://x/u>#', $data);
            $this->assertMatchesRegularExpression('#multipart/alternative#', $data);
        } finally {
            $server->stop();
        }
    }

    public function testSmtpThroughTransportsSendsToo(): void
    {
        $server = new SmtpServer();
        try {
            Transports::send(['service' => 'smtp', 'host' => '127.0.0.1', 'port' => (string) $server->port, 'security' => 'none'], self::MESSAGE);
            $this->assertStringContainsString("From: Runlight <reports@example.com>\r\n", $server->conversation()['received']);
        } finally {
            $server->stop();
        }
    }

    public function testSmtpServerThatTricklesIsCutOffAtTheDeadline(): void
    {
        $server = new SmtpServer('trickle');
        try {
            $started = microtime(true);
            try {
                Smtp::send(['service' => 'smtp', 'host' => '127.0.0.1', 'port' => (string) $server->port, 'security' => 'none'], self::MESSAGE, 'reports@example.com', 600);
                $this->fail('the send should give up');
            } catch (MailError $error) {
                $this->assertSame('mail_slow', $error->code, $error->getMessage());
                $this->assertSame(['host' => "127.0.0.1:{$server->port}"], $error->params);
                $this->assertSame("SMTP: 127.0.0.1:{$server->port} took longer than 1 s", $error->getMessage());
            }
            $this->assertLessThan(2, microtime(true) - $started, 'the send gives up at its deadline');
            $this->assertTrue($server->conversation(2)['closed'] ?? false, 'the connection is closed');
        } finally {
            $server->stop();
        }
    }

    public function testSmtpReplyJustBeforeTheServerClosesIsTheErrorNotTheClose(): void
    {
        $server = new SmtpServer('refuse');
        try {
            $this->assertThrowsMatching('/^SMTP greeting: 535 no$/', fn () => Smtp::send(['service' => 'smtp', 'host' => '127.0.0.1', 'port' => (string) $server->port, 'security' => 'none'], self::MESSAGE, 'reports@example.com'));
        } finally {
            $server->stop();
        }
    }

    public function testSmtpThatCannotConnectSaysSo(): void
    {
        // A port that was free a moment ago.
        $probe = stream_socket_server('tcp://127.0.0.1:0');
        $port = (int) explode(':', stream_socket_get_name($probe, false))[1];
        fclose($probe);
        try {
            Smtp::send(['service' => 'smtp', 'host' => '127.0.0.1', 'port' => (string) $port, 'security' => 'none'], self::MESSAGE, 'reports@example.com');
            $this->fail('the send should fail');
        } catch (MailError $error) {
            $this->assertSame('mail_unreachable', $error->code);
            $this->assertSame("127.0.0.1:$port", $error->params['host']);
            $this->assertStringStartsWith("SMTP: could not connect to 127.0.0.1:$port: ", $error->getMessage());
        }
    }

    public function testErrorsCarryCodesAndParams(): void
    {
        $error = new MailError('Something');
        $this->assertSame('mail_failed', $error->code);
        $this->assertSame(['detail' => 'Something'], $error->params);
        $this->assertSame('ses', Transports::SERVICES[0]['id']);
    }

    private function assertThrowsMatching(string $pattern, \Closure $run): void
    {
        try {
            $run();
        } catch (MailError $error) {
            $this->assertMatchesRegularExpression($pattern, $error->getMessage());
            return;
        }
        $this->fail("Expected an error matching $pattern");
    }
}
