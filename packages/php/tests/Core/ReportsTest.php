<?php

declare(strict_types=1);

namespace Runlight\Tests\Core;

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Runlight\Http\Request;
use Runlight\Intl;
use Runlight\Json;
use Runlight\Reports;
use Runlight\Runlight;
use Runlight\Store\Stores;
use Runlight\Tests\Fixture;

/** Email reports and their periods, replayed from what scripts/php-fixtures-core2.mts had the TypeScript SDK write. */
final class ReportsTest extends TestCase
{
    private const AGENT = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36';

    /** @return iterable<string, array{string}> */
    public static function languages(): iterable
    {
        foreach (Fixture::load('reports')['intl'] as $set) {
            yield $set['lang'] => [$set['lang']];
        }
    }

    private static function set(string $lang): array
    {
        return array_values(array_filter(Fixture::load('reports')['intl'], static fn (array $s): bool => $s['lang'] === $lang))[0];
    }

    #[DataProvider('languages')]
    public function testNumbersPercentsAndDatesAreWrittenAsIntlWritesThem(string $lang): void
    {
        $set = self::set($lang);
        foreach ($set['number'] as [$n, $text]) {
            self::assertSame($text, Intl::number($lang, $n), "$lang number $n");
        }
        foreach ($set['decimal'] as [$n, $text]) {
            self::assertSame($text, Intl::number($lang, $n, 1, 1), "$lang decimal $n");
        }
        foreach ($set['percent'] as [$n, $text]) {
            self::assertSame($text, Intl::percent($lang, $n), "$lang percent $n");
        }
        foreach ($set['monthYear'] as [$day, $text]) {
            self::assertSame($text, Intl::monthYear($lang, $day), "$lang $day");
        }
        foreach ($set['shortDay'] as [$day, $short, $long]) {
            self::assertSame($short, Intl::shortDay($lang, $day, false), "$lang $day");
            self::assertSame($long, Intl::shortDay($lang, $day, true), "$lang $day");
        }
    }

    #[DataProvider('languages')]
    public function testCurrenciesAndRegionNamesAreIcusWhenItIsAtHand(string $lang): void
    {
        if (!class_exists(\Locale::class)) {
            self::markTestSkipped('ext-intl is not loaded, so regions stay codes');
        }
        $set = self::set($lang);
        foreach ($set['currency'] as [$n, $currency, $text]) {
            self::assertSame($text, Intl::currency($lang, $n, $currency, is_int($n) ? 0 : 2), "$lang $n $currency");
        }
        // Region names change between ICU releases; the fixture's are ICU 78's, as Node 24 has it.
        if ((int) INTL_ICU_VERSION !== 78) {
            self::markTestSkipped('ICU ' . INTL_ICU_VERSION . ' names regions in its own words; the fixture holds ICU 78\'s');
        }
        $differ = [];
        foreach ($set['region'] as [$code, $name]) {
            if (Intl::region($lang, $code) !== $name) {
                $differ[] = "$code: " . Intl::region($lang, $code) . " (Node: $name)";
            }
        }
        self::assertSame([], $differ, "$lang region names");
    }

    public function testReportPeriodsMatchForEveryZoneAndFrequency(): void
    {
        foreach (Fixture::load('reports')['periods'] as $case) {
            self::assertSame($case['period'], Reports::lastPeriod($case['frequency'], $case['now'], $case['zone']), Fixture::label($case));
        }
    }

    public function testReportPeriodsAreLastMondayToSundayOrLastMonthDueFrom8amTheDayAfterInTheSitesZone(): void
    {
        // Wednesday 8 October 2026, 15:00 UTC (11:00 in Toronto).
        $now = gmmktime(15, 0, 0, 10, 8, 2026) * 1000;
        $week = Reports::lastPeriod('weekly', $now, 'America/Toronto');
        self::assertSame(['w:2026-09-28', '2026-09-28', '2026-10-04', '2026-09-21'], [$week['key'], $week['fromDate'], $week['toDate'], $week['previousFrom']]);
        self::assertSame(gmmktime(12, 0, 0, 10, 5, 2026) * 1000, $week['dueAt'], 'Monday 5 October, 8am Toronto');
        $month = Reports::lastPeriod('monthly', $now, 'America/Toronto');
        self::assertSame(['m:2026-09', '2026-09-01', '2026-09-30', '2026-08-01', '2026-08-31'], [$month['key'], $month['fromDate'], $month['toDate'], $month['previousFrom'], $month['previousTo']]);
        $early = Reports::lastPeriod('weekly', gmmktime(7, 0, 0, 10, 5, 2026) * 1000, 'America/Toronto');
        self::assertLessThan($early['dueAt'], gmmktime(7, 0, 0, 10, 5, 2026) * 1000);
    }

    /** @return iterable<string, array{string}> */
    public static function cases(): iterable
    {
        foreach (Fixture::load('reports')['cases'] as $case) {
            yield $case['name'] => [$case['name']];
        }
    }

    #[DataProvider('cases')]
    public function testReportsRenderAsTheTypeScriptSdkRendersThemInEveryLanguage(string $name): void
    {
        if (!class_exists(\Locale::class)) {
            self::markTestSkipped('ext-intl is not loaded, so country names and currencies differ from Node');
        }
        $case = array_values(array_filter(Fixture::load('reports')['cases'], static fn (array $c): bool => $c['name'] === $name))[0];
        $now = 0;
        $rl = new Runlight([
            'store' => Stores::sqlite(':memory:'),
            'site' => ['name' => 'Example & Co', 'hostnames' => ['example.com'], 'timezone' => $case['timezone']],
            'now' => static function () use (&$now): int {
                return $now;
            },
        ]);
        $rl->init();
        foreach ($case['goals'] as $goal) {
            $rl->store->saveGoal($goal);
        }
        foreach ($case['hits'] as $hit) {
            $now = $hit['at'];
            $headers = ['user-agent' => self::AGENT, 'x-forwarded-for' => $hit['ip']];
            if ($hit['country'] !== '') {
                $headers['x-vercel-ip-country'] = $hit['country'];
            }
            $rl->collect(new Request('https://example.com/runlight/e', 'POST', $headers, Json::encode($hit['body'])));
        }
        $now = $case['at'];
        $site = $rl->site('default');
        foreach ($case['reports'] as $expected) {
            $label = "{$case['name']}, {$expected['lang']} {$expected['frequency']}";
            self::assertSame($expected['period'], Reports::lastPeriod($expected['frequency'], $now, $case['timezone']), $label);
            $report = Reports::buildReport($rl, $site, $expected['frequency'], $expected['period'], $expected['lang'], $expected['links']);
            self::assertSame($expected['subject'], $report['subject'], $label);
            self::assertSame($expected['text'], $report['text'], $label);
            self::assertSame($expected['html'], $report['html'], $label);
        }
    }
}
