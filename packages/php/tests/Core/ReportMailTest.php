<?php

declare(strict_types=1);

namespace Runlight\Tests\Core;

use PHPUnit\Framework\TestCase;
use Runlight\Hash;
use Runlight\Http\Response;
use Runlight\Json;
use Runlight\Mail\MailError;
use Runlight\Reports;
use Runlight\Runlight;
use Runlight\Store\Stores;
use Runlight\Tests\Support\FakeFetcher;

/** The mail service's settings and the reports sent through it, as mail.test.ts and audit.test.ts test them without routes. */
final class ReportMailTest extends TestCase
{
    private int $status = 200;
    private FakeFetcher $fetcher;
    private string|false $errorLog = false;

    protected function setUp(): void
    {
        // A failed send is logged, as TS logs it; the test reads the result instead.
        $this->errorLog = ini_set('error_log', '/dev/null');
        $this->fetcher = new FakeFetcher(fn (): Response => new Response($this->status === 200 ? '{}' : 'nope', $this->status));
    }

    protected function tearDown(): void
    {
        ini_set('error_log', (string) $this->errorLog);
    }

    private function runlight(int &$now, array $options = []): Runlight
    {
        return new Runlight([
            'store' => Stores::sqlite(':memory:'),
            'now' => static function () use (&$now): int {
                return $now;
            },
            'fetcher' => $this->fetcher,
            ...$options,
        ]);
    }

    /** A report as the routes add one: a period already due counts as sent. */
    private static function addReport(Runlight $rl, string $email, string $frequency, string $lang = 'en', string $origin = 'https://stats.example.com/runlight'): void
    {
        $site = $rl->site('default');
        $due = Reports::lastPeriod($frequency, $rl->now(), $site['timezone']);
        $rl->store->insertReport([
            'id' => Hash::randomId(), 'site' => 'default', 'email' => $email, 'frequency' => $frequency, 'lang' => $lang, 'token' => Hash::randomId(16),
            'origin' => $origin, 'lastPeriod' => $rl->now() >= $due['dueAt'] ? $due['key'] : '', 'lastSentAt' => null, 'createdAt' => $rl->now(),
        ]);
    }

    private static function mailError(callable $fn): MailError
    {
        try {
            $fn();
        } catch (MailError $e) {
            return $e;
        }
        self::fail('no MailError');
    }

    public function testReportsGoOutOncePerPeriodRetryAfterAFailureAndKeepKeysFromTheBrowser(): void
    {
        $now = gmmktime(15, 0, 0, 10, 8, 2026) * 1000;
        $rl = $this->runlight($now, ['site' => ['name' => 'Example', 'hostnames' => ['example.com'], 'timezone' => 'America/Toronto'], 'secret' => 's3cret']);
        $rl->init();

        $badFrom = self::mailError(fn () => $rl->saveMailSettings(['service' => 'resend', 'apiKey' => 're_live_key', 'from' => 'not an address']));
        self::assertSame('mail_from', $badFrom->code, 'a code the dashboard says in its own language');
        self::assertSame([], $badFrom->params);
        $noKey = self::mailError(fn () => $rl->saveMailSettings(['service' => 'resend', 'apiKey' => '', 'from' => 'reports@example.com']));
        self::assertSame(['mail_field', ['field' => 'apiKey']], [$noKey->code, $noKey->params]);
        self::assertSame('mail_service', self::mailError(fn () => $rl->saveMailSettings(['service' => 'pigeon']))->code);
        $rl->saveMailSettings(['service' => 'resend', 'apiKey' => 're_live_key', 'from' => 'reports@example.com', 'fromName' => 'Runlight']);
        $stored = (string) $rl->store->setting('mail');
        self::assertStringStartsWith('v1:', $stored);
        self::assertStringNotContainsString('re_live_key', $stored, 'the key is encrypted at rest');
        self::assertSame(['service' => 'resend', 'apiKey' => 're_live_key', 'from' => 'reports@example.com', 'fromName' => 'Runlight', 'source' => 'dashboard'], $rl->mailSettings());
        // Saving again with the key left blank keeps it.
        $rl->saveMailSettings(['service' => 'resend', 'apiKey' => '', 'from' => 'reports@example.com']);
        self::assertSame('re_live_key', $rl->mailSettings()['apiKey']);

        self::addReport($rl, 'jon@example.com', 'weekly', 'fr');
        self::assertSame(['sent' => 0, 'failed' => 0], $rl->sendReports(), 'a report added on a Wednesday waits for the next Monday');
        self::assertCount(0, $this->fetcher->requests);
        $now += 7 * 86_400_000;
        $this->status = 500;
        self::assertSame(['sent' => 0, 'failed' => 1], $rl->sendReports());
        $this->status = 200;
        $this->fetcher->requests = [];
        self::assertSame(['sent' => 1, 'failed' => 0], $rl->sendReports(), 'a failed send is tried again');
        $body = Json::decode($this->fetcher->requests[0]['body'], true);
        self::assertSame('https://api.resend.com/emails', $this->fetcher->requests[0]['url']);
        self::assertSame('jon@example.com', $body['to'][0]);
        self::assertSame('Example : 0 personne la semaine dernière', $body['subject']);
        self::assertStringContainsString('du 5 oct. au 11 oct. 2026', $body['html']);
        self::assertStringContainsString('0 personne a visité le site la semaine dernière.', $body['html'], 'French counts zero as one');
        self::assertMatchesRegularExpression('#^<https://stats\.example\.com/runlight/unsubscribe/[a-f0-9]{32}>$#', $body['headers']['List-Unsubscribe']);
        self::assertSame('List-Unsubscribe=One-Click', $body['headers']['List-Unsubscribe-Post']);
        self::assertStringContainsString('https://stats.example.com/runlight/?site=default', $body['text']);
        self::assertSame(['sent' => 0, 'failed' => 0], $rl->sendReports(), 'the same period never goes twice');
        $now += 7 * 86_400_000;
        self::assertSame(['sent' => 1, 'failed' => 0], $rl->sendReports(), 'the next week does');
        self::assertSame(['ok' => true, 'reports' => ['sent' => 0, 'failed' => 0]], $rl->check());
    }

    public function testAReportAddedBeforeMondays8amStillGetsLastWeeks(): void
    {
        // Monday 5 October 2026, 7:00 in Toronto: last week is over and not yet due.
        $now = gmmktime(11, 0, 0, 10, 5, 2026) * 1000;
        $rl = $this->runlight($now, ['site' => ['name' => 'Example', 'hostnames' => ['example.com'], 'timezone' => 'America/Toronto']]);
        $rl->saveMailSettings(['service' => 'resend', 'apiKey' => 're_1', 'from' => 'reports@example.com']);
        self::addReport($rl, 'jon@example.com', 'weekly');
        self::addReport($rl, 'jon@example.com', 'monthly');
        self::assertSame(['sent' => 0, 'failed' => 0], $rl->sendReports());
        $now += 2 * 3_600_000;
        self::assertSame(['sent' => 1, 'failed' => 0], $rl->sendReports());
        self::assertStringContainsString('last week', Json::decode($this->fetcher->requests[0]['body'], true)['subject']);
    }

    public function testNoMailServiceSendsNothingAndSayingSoIsAnError(): void
    {
        $now = gmmktime(15, 0, 0, 10, 12, 2026) * 1000;
        $rl = $this->runlight($now);
        $rl->init();
        self::addReport($rl, 'jon@example.com', 'weekly');
        $rl->store->db->run("UPDATE rl_reports SET last_period = ''");
        self::assertSame(['sent' => 0, 'failed' => 0], $rl->sendReports());
        self::assertSame('mail_unset', self::mailError(fn () => $rl->sendMail(['to' => 'a@b.co', 'subject' => 's', 'html' => 'h', 'text' => 't']))->code);
    }

    public function testAMailServiceInCodeIsShownAndCannotBeChanged(): void
    {
        $now = 0;
        $rl = $this->runlight($now, ['mail' => ['service' => 'resend', 'apiKey' => 're_code', 'from' => 'r@example.com']]);
        self::assertSame(['service' => 'resend', 'apiKey' => 're_code', 'from' => 'r@example.com', 'source' => 'code'], $rl->mailSettings());
        self::assertSame('mail_in_code', self::mailError(fn () => $rl->saveMailSettings(null))->code);
        $rl->sendMail(['to' => 'jon@example.com', 'subject' => 'Hi', 'html' => '<p>Hi</p>', 'text' => 'Hi']);
        self::assertSame('r@example.com', Json::decode($this->fetcher->requests[0]['body'], true)['from']);
    }

    public function testASavedSmtpPasswordIsKeptOnlyWhileTheServerItGoesToStaysTheSame(): void
    {
        $now = 0;
        $rl = $this->runlight($now, ['secret' => str_repeat('k', 32)]);
        $base = ['service' => 'smtp', 'host' => 'smtp.example.com', 'port' => '587', 'security' => 'starttls', 'username' => 'me', 'from' => 'r@example.com'];
        $rl->saveMailSettings([...$base, 'password' => 'hunter2-long']);
        $rl->saveMailSettings([...$base, 'password' => '', 'from' => 'reports@example.com']);
        self::assertSame('hunter2-long', $rl->mailSettings()['password'], 'same server, blank field: kept');
        $rl->saveMailSettings([...$base, 'host' => 'evil.example', 'password' => '', 'from' => 'reports@example.com']);
        self::assertSame('', $rl->mailSettings()['password'] ?? '', 'a new host needs the password typed again');
        $rl->saveMailSettings(null);
        self::assertNull($rl->mailSettings());
    }

    public function testAKeySealedWithAnotherSecretReadsAsNoMailService(): void
    {
        $store = Stores::sqlite(':memory:');
        $one = new Runlight(['store' => $store, 'secret' => 'one']);
        $one->saveMailSettings(['service' => 'resend', 'apiKey' => 're_1', 'from' => 'r@example.com']);
        $two = new Runlight(['store' => $store, 'secret' => 'two']);
        self::assertNull($two->mailSettings());
    }
}
