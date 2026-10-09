<?php

declare(strict_types=1);

namespace Runlight;

use Runlight\Http\Url;

/**
 * Email reports: the period each one covers, and the message itself, in the reader's language.
 *
 * A ReportPeriod is an array: `key` (w:<monday> or m:<yyyy-mm>, so each period is sent once), `fromDate`,
 * `toDate`, `previousFrom`, `previousTo`, and `dueAt` (reports go out from 8am the day after the period
 * ends, in the site's timezone).
 */
final class Reports
{
    /**
     * The last complete week (Monday to Sunday) or month before `now`, in a timezone.
     *
     * @return array{key: string, fromDate: string, toDate: string, previousFrom: string, previousTo: string, dueAt: int}
     */
    public static function lastPeriod(string $frequency, int $now, string $timezone): array
    {
        $today = Time::localDate($now, $timezone);
        if ($frequency === 'monthly') {
            $first = substr($today, 0, 8) . '01';
            $fromDate = Time::addMonths($first, -1);
            return [
                'key' => 'm:' . substr($fromDate, 0, 7),
                'fromDate' => $fromDate,
                'toDate' => Time::addDays($first, -1),
                'previousFrom' => Time::addMonths($fromDate, -1),
                'previousTo' => Time::addDays($fromDate, -1),
                'dueAt' => Time::startOf($first, $timezone, 8),
            ];
        }
        $weekday = (int) (new \DateTimeImmutable("{$today}T00:00:00Z"))->format('N') - 1;
        $monday = Time::addDays($today, -$weekday);
        $fromDate = Time::addDays($monday, -7);
        return [
            'key' => "w:$fromDate",
            'fromDate' => $fromDate,
            'toDate' => Time::addDays($monday, -1),
            'previousFrom' => Time::addDays($fromDate, -7),
            'previousTo' => Time::addDays($fromDate, -1),
            'dueAt' => Time::startOf($monday, $timezone, 8),
        ];
    }

    private static function esc(string $value): string
    {
        return strtr($value, ['&' => '&amp;', '<' => '&lt;', '>' => '&gt;', '"' => '&quot;', "'" => '&#39;']);
    }

    private static function duration(int|float $ms): string
    {
        $seconds = (int) Js::round($ms / 1000);
        if ($seconds < 60) {
            return "{$seconds}s";
        }
        $minutes = intdiv($seconds, 60);
        if ($minutes < 60) {
            return "{$minutes}m " . str_pad((string) ($seconds % 60), 2, '0', STR_PAD_LEFT) . 's';
        }
        return intdiv($minutes, 60) . 'h ' . str_pad((string) ($minutes % 60), 2, '0', STR_PAD_LEFT) . 'm';
    }

    /**
     * One site's report for a period, in a language. `links` are absolute: the
     * dashboard and the recipient's unsubscribe page.
     *
     * @param array{id: string, name: string, hostnames: list<string>, timezone: string} $site
     * @param array{key: string, fromDate: string, toDate: string, previousFrom: string, previousTo: string, dueAt: int} $period
     * @param array{dashboard: string, unsubscribe: string} $links
     * @return array{subject: string, html: string, text: string}
     */
    public static function buildReport(Runlight $runlight, array $site, string $frequency, array $period, string $lang, array $links): array
    {
        ['t' => $t, 'tn' => $tn, 'lang' => $code] = Messages::translator($lang);
        $tz = $site['timezone'];
        $range = static fn (string $from, string $to): array => ['site' => $site['id'], 'from' => Time::startOf($from, $tz), 'to' => Time::startOf(Time::addDays($to, 1), $tz), 'filters' => []];
        $query = $range($period['fromDate'], $period['toDate']);
        $before = $range($period['previousFrom'], $period['previousTo']);
        $store = $runlight->store;
        $now = $store->stats($query);
        $prev = $store->stats($before);
        $pages = $store->breakdown($query, 'page', 5, 0);
        $sources = $store->breakdown($query, 'source', 5, 0);
        $countries = $store->breakdown($query, 'country', 5, 0);
        $goals = $store->goals($site['id']);
        $totals = $store->goalTotalsAll($query, $goals);

        $number = static fn (int|float $n): string => Intl::number($code, $n);
        $percent = static fn (int|float $n): string => Intl::percent($code, $n);
        $decimal = static fn (int|float $n): string => Intl::number($code, $n, 1, 1);
        $money = static fn (int|float $n, string $currency): string => Intl::currency($code, $n, $currency, is_int($n) || floor($n) === $n ? 0 : 2);
        $monthName = static fn (string $d): string => Intl::monthYear($code, $d);
        // Each end formatted on its own, joined in the reader's language (never with a dash).
        $span = static function (string $from, string $to) use ($t, $code): string {
            $sameYear = substr($from, 0, 4) === substr($to, 0, 4);
            return $t('email.range', ['from' => Intl::shortDay($code, $from, !$sameYear), 'to' => Intl::shortDay($code, $to, true)]);
        };
        $country = static fn (string $code2): string => Intl::region($code, $code2);

        $monthly = $frequency === 'monthly';
        $when = $monthly ? $t('email.when.month', ['month' => $monthName($period['fromDate'])]) : $t('email.when.week');
        $against = $monthly ? $monthName($period['previousFrom']) : $t('email.before.week');
        $who = $tn('headline.who', $now['visitors'], ['n' => $number($now['visitors'])]);
        $verb = $tn('headline.visited', $now['visitors']);
        $change = $prev['visitors'] ? ($now['visitors'] - $prev['visitors']) / $prev['visitors'] : null;
        if ($prev['visitors'] == 0 && $now['visitors'] > 0) {
            $headline = $t('headline.fromNone', ['who' => $who, 'verb' => $verb, 'when' => $when, 'against' => $against]);
        } elseif ($change === null) {
            $headline = $t('headline.plain', ['who' => $who, 'verb' => $verb, 'when' => $when]);
        } else {
            $headline = $t(abs($change) < 0.005 ? 'headline.same' : ($change > 0 ? 'headline.up' : 'headline.down'), [
                'who' => $who,
                'verb' => $verb,
                'when' => $when,
                'against' => $against,
                'change' => $t($change > 0 ? 'headline.more' : 'headline.fewer', ['pct' => (int) abs(Js::round($change * 100))]),
            ]);
        }
        $subject = $t($monthly ? 'email.subject.month' : 'email.subject.week', ['site' => $site['name'], 'who' => $who, 'month' => $monthName($period['fromDate'])]);
        $dates = $span($period['fromDate'], $period['toDate']);

        $metrics = [
            ['key' => 'visitors', 'format' => $number, 'lowerIsBetter' => false],
            ['key' => 'visits', 'format' => $number, 'lowerIsBetter' => false],
            ['key' => 'pageviews', 'format' => $number, 'lowerIsBetter' => false],
            ['key' => 'viewsPerVisit', 'format' => $decimal, 'lowerIsBetter' => false],
            ['key' => 'bounceRate', 'format' => $percent, 'lowerIsBetter' => true],
            ['key' => 'visitDuration', 'format' => self::duration(...), 'lowerIsBetter' => false],
        ];
        $delta = static function (string $key, bool $lowerIsBetter) use ($now, $prev, $percent): array {
            $b = $prev[$key];
            if (!$b) {
                return ['text' => '', 'color' => '#6b7280', 'tone' => 'flat'];
            }
            $c = ($now[$key] - $b) / $b;
            if (abs($c) < 0.005) {
                return ['text' => '0%', 'color' => '#6b7280', 'tone' => 'flat'];
            }
            $good = $lowerIsBetter ? $c < 0 : $c > 0;
            return ['text' => ($c > 0 ? '↑' : '↓') . ' ' . $percent(abs($c)), 'color' => $good ? '#15803d' : '#b91c1c', 'tone' => $good ? 'up' : 'down'];
        };

        $lists = [
            ['title' => $t('email.pages'), 'rows' => array_map(static fn (array $r): array => [Js::truthy($r['value']) ? (string) $r['value'] : '/', $number($r['visitors'])], $pages)],
            ['title' => $t('email.sources'), 'rows' => array_map(static fn (array $r): array => [Js::truthy($r['value']) ? (string) $r['value'] : $t('goals.unknown'), $number($r['visitors'])], $sources)],
            ['title' => $t('email.countries'), 'rows' => array_map(static fn (array $r): array => [$country((string) $r['value']), $number($r['visitors'])], $countries)],
        ];
        if ($goals !== []) {
            $goalRows = array_map(static fn (array $g): array => ['goal' => $g, 'totals' => $totals[$g['id']]], $goals);
            usort($goalRows, static fn (array $a, array $b): int => $b['totals']['conversions'] <=> $a['totals']['conversions']);
            $lists[] = [
                'title' => $t('email.conversions'),
                'rows' => array_map(static fn (array $row): array => [
                    $row['goal']['valueMode'] !== 'none' && Js::truthy($row['totals']['revenue']) ? "{$row['goal']['name']} (" . $money($row['totals']['revenue'], $row['goal']['currency']) . ')' : $row['goal']['name'],
                    $number($row['totals']['conversions']),
                ], $goalRows),
            ];
        }

        $font = "-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif";
        $cell = static function (array $m) use ($delta, $now, $t): string {
            $d = $delta($m['key'], $m['lowerIsBetter']);
            $label = self::esc($t("metric.{$m['key']}"));
            $value = self::esc(($m['format'])($now[$m['key']]));
            $text = self::esc($d['text']);
            return <<<HTML
<td width="33%" class="rl-line" style="padding:12px 14px;border:1px solid #e5e7eb;border-radius:10px;vertical-align:top">
<div class="rl-muted" style="font-size:11px;letter-spacing:.04em;text-transform:uppercase;color:#6b7280">{$label}</div>
<div class="rl-ink" style="font-size:24px;font-weight:600;color:#111827;margin-top:4px">{$value}</div>
<div class="rl-{$d['tone']}" style="font-size:12px;color:{$d['color']};margin-top:2px;min-height:16px">{$text}</div></td>
HTML;
        };
        $table = static function (array $l) use ($t): string {
            $title = self::esc($l['title']);
            $rows = $l['rows']
                ? implode('', array_map(static fn (array $r): string => '<tr><td class="rl-row rl-body-text" style="padding:7px 0;border-top:1px solid #f0f0f0;color:#374151;word-break:break-all">' . self::esc($r[0]) . '</td><td align="right" class="rl-row rl-ink" style="padding:7px 0 7px 12px;border-top:1px solid #f0f0f0;color:#111827;font-weight:600;white-space:nowrap">' . self::esc($r[1]) . '</td></tr>', $l['rows']))
                : '<tr><td class="rl-muted" style="padding:7px 0;color:#6b7280">' . self::esc($t('panel.empty')) . '</td></tr>';
            return <<<HTML
<h3 class="rl-ink" style="font-size:14px;color:#111827;margin:28px 0 8px">{$title}</h3>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;font-size:14px">{$rows}</table>
HTML;
        };

        // Where the dashboard lives, without the scheme or the site query, so a reader
        // with several installs can tell which one sent this.
        $u = Url::parse($links['dashboard']);
        $where = $u !== null ? $u->host() . preg_replace('#/$#D', '', $u->pathname) : $links['dashboard'];
        $at = $t('email.at', ['where' => $where]);
        // The Runlight mark in table cells: mail apps block SVG and most inline images.
        $mark = <<<HTML
<table role="presentation" cellpadding="0" cellspacing="0" style="border-collapse:collapse"><tr>
<td class="rl-mark" width="24" height="24" align="center" style="width:24px;height:24px;background:#111827;border-radius:7px;color:#ffffff;font-size:15px;font-weight:700;line-height:24px;text-align:center;font-family:{$font}">R</td>
<td class="rl-ink" style="padding-left:8px;font-size:15px;font-weight:700;color:#111827;font-family:{$font}">Runlight</td></tr></table>
HTML;

        $footer = $t('email.footer', ['frequency' => $t($monthly ? 'email.monthly' : 'email.weekly'), 'site' => $site['name']]);
        $atLine = self::esc($t('email.at', ['where' => "\0"]));
        $hole = strpos($atLine, "\0");
        if ($hole !== false) {
            $atLine = substr_replace($atLine, '<a href="' . self::esc($links['dashboard']) . '" class="rl-muted" style="color:#6b7280">' . self::esc($where) . '</a>', $hole, 1);
        }
        $e = self::esc(...);
        $cells1 = implode('', array_map($cell, array_slice($metrics, 0, 3)));
        $cells2 = implode('', array_map($cell, array_slice($metrics, 3)));
        $tables = implode('', array_map($table, $lists));
        $html = <<<HTML
<!doctype html><html lang="{$code}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark"><meta name="supported-color-schemes" content="light dark"><title>{$e($subject)}</title>
<style>
@media (prefers-color-scheme: dark) {
  .rl-page { background: #09090b !important; }
  .rl-card { background: #141417 !important; border-color: #27272a !important; }
  .rl-line { border-color: #27272a !important; }
  .rl-row { border-top-color: #1f1f23 !important; }
  .rl-ink { color: #ffffff !important; }
  .rl-body-text { color: #d4d4d8 !important; }
  .rl-muted, .rl-flat { color: #a1a1aa !important; }
  .rl-up { color: #4ade80 !important; }
  .rl-down { color: #f87171 !important; }
  .rl-button { background: #ffffff !important; color: #000000 !important; }
  .rl-mark { background: #ffffff !important; color: #000000 !important; }
  .rl-foot, .rl-foot a { color: #a1a1aa !important; }
}
</style></head>
<body class="rl-page" style="margin:0;padding:0;background:#f4f4f5;font-family:{$font}">
<div style="display:none;max-height:0;overflow:hidden">{$e($headline)}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" class="rl-page" style="background:#f4f4f5"><tr><td align="center" style="padding:32px 16px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" class="rl-card" style="max-width:600px;background:#ffffff;border-radius:14px;border:1px solid #e5e7eb"><tr><td style="padding:32px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;margin:0 0 24px"><tr>
<td style="vertical-align:middle">{$mark}</td>
<td align="right" class="rl-muted" style="vertical-align:middle;font-size:12px;color:#6b7280">{$atLine}</td>
</tr></table>
<div class="rl-muted" style="font-size:12px;letter-spacing:.04em;text-transform:uppercase;color:#6b7280">{$e($site['name'])} · {$e($dates)}</div>
<h1 class="rl-ink" style="font-size:24px;line-height:1.3;color:#111827;margin:10px 0 24px;font-weight:600">{$e($headline)}</h1>
<table role="presentation" width="100%" cellpadding="0" cellspacing="6" style="border-collapse:separate;margin:0 -6px">
<tr>{$cells1}</tr><tr>{$cells2}</tr></table>
{$tables}
<p style="margin:32px 0 0"><a href="{$e($links['dashboard'])}" class="rl-button" style="display:inline-block;background:#111827;color:#ffffff;text-decoration:none;padding:11px 18px;border-radius:8px;font-size:14px;font-weight:600">{$e($t('email.open'))}</a></p>
</td></tr></table>
<p class="rl-foot" style="max-width:600px;font-size:12px;line-height:1.5;color:#6b7280;margin:16px auto 0">{$e($footer)} <a href="{$e($links['unsubscribe'])}" style="color:#6b7280">{$e($t('email.unsubscribe'))}</a></p>
</td></tr></table></body></html>
HTML;

        // French sets a space before a colon, as its subject line does.
        $colon = $code === 'fr' ? "\u{a0}:" : ':';
        $lines = ["Runlight · $at", '', "{$site['name']} · $dates", '', $headline, ''];
        foreach ($metrics as $m) {
            $d = $delta($m['key'], $m['lowerIsBetter'])['text'];
            $lines[] = $t("metric.{$m['key']}") . "$colon " . ($m['format'])($now[$m['key']]) . ($d !== '' ? " ($d)" : '');
        }
        foreach ($lists as $l) {
            $lines[] = '';
            $lines[] = $l['title'];
            if ($l['rows']) {
                foreach ($l['rows'] as [$a, $b]) {
                    $lines[] = "  $a$colon $b";
                }
            } else {
                $lines[] = '  ' . $t('panel.empty');
            }
        }
        array_push($lines, '', $t('email.open') . "$colon {$links['dashboard']}", '', "$footer " . $t('email.unsubscribe') . "$colon {$links['unsubscribe']}");

        return ['subject' => $subject, 'html' => $html, 'text' => implode("\n", $lines)];
    }
}
