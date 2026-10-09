<?php

declare(strict_types=1);

namespace Runlight\Tests\Store;

use PHPUnit\Framework\Attributes\DataProvider;
use Runlight\Store\SqlStore;

/**
 * d1-limits.test.ts at the store: no statement binds more than 100 values, as Cloudflare D1 requires, over a
 * year of data, on SQLite as D1 runs it and on MySQL, whose statements for the same reports are written
 * differently.
 */
final class ParameterLimitTest extends StoreTestCase
{
    /** @return array<string, array{0: string}> */
    public static function limited(): array
    {
        return array_filter(Databases::kinds(), static fn (string $kind): bool => $kind !== 'postgres', ARRAY_FILTER_USE_KEY);
    }

    #[DataProvider('limited')]
    public function testNoStatementBindsMoreThan100Parameters(string $kind): void
    {
        $store = $this->store($kind);
        // A visit every third day for a year, so a year of days can be built.
        $store->transaction(function (SqlStore $tx): void {
            for ($d = 0; $d < 365; $d += 3) {
                $t = self::NOW - 365 * self::DAY + $d * self::DAY;
                Seed::visit($tx, "y$d", "v$d", $t, ['country' => 'GB'], [['pageview', '/p' . ($d % 40), $t, "y$d"], ['event', 'Goal' . ($d % 30), $t + 1, ['amount' => $d]]]);
            }
        });
        Seed::buildDays($store, 'default', self::NOW - 366 * self::DAY, self::NOW - self::DAY);
        for ($g = 0; $g < 30; $g++) {
            $store->saveGoal(self::goal(str_pad(dechex($g), 24, '0', STR_PAD_LEFT), ['name' => "Goal $g", 'match' => "Goal$g", 'valueMode' => $g % 2 ? 'prop' : 'fixed', 'value' => 5, 'valueProp' => 'amount']));
        }
        $funnel = ['id' => str_repeat('f', 24), 'site' => 'default', 'name' => 'Funnel', 'steps' => [['kind' => 'page', 'match' => '/p1'], ['kind' => 'event', 'match' => 'Goal1']], 'createdAt' => 0];
        $store->saveFunnel($funnel);
        // Days not built, scattered through the last month, as late engagement or an import leaves them.
        for ($d = 2; $d < 30; $d += 3) {
            $store->clearRollups('default', ['from' => self::NOW - $d * self::DAY, 'to' => self::NOW - $d * self::DAY + 1]);
        }

        // Every statement from here on is checked.
        $watched = new WatchedDb($store->db);
        $most = 0;
        $watched->before = function (string $sql, array $params) use (&$most): void {
            $most = max($most, count($params));
            if (count($params) > 100) {
                throw new \RuntimeException('a statement bound ' . count($params) . ' parameters');
            }
        };
        $view = new SqlStore($watched);
        $goals = $view->goals('default');
        $days = static function (int $from, int $to, int $size): array {
            $out = [];
            for ($at = $from; $at < $to; $at += $size) {
                $out[] = ['start' => $at, 'end' => min($at + $size, $to)];
            }
            return $out;
        };
        $f = static fn (string $d, string $op, string $v): array => ['dimension' => $d, 'op' => $op, 'value' => $v];
        // As many filters as a query takes, each of the kind that binds the most.
        $many = [$f('page', 'contains', '/P'), $f('page', 'contains', 'é'), $f('event', 'contains', 'goal'), $f('hostname', 'contains', 'example'), $f('page', 'not', '/x'), $f('country', 'not', 'XX')];
        // Path filters in mixed case are tried in several forms, each a value of its own.
        $paths = [$f('page', 'contains', '/pÉ'), $f('page', 'contains', '/Pé'), $f('page', 'contains', '/xÜ'), $f('page', 'contains', '/üX'), $f('page', 'contains', '/ÉtÉ'), $f('hostname', 'contains', 'eXa')];
        $ranges = [
            '12mo' => [self::NOW - 365 * self::DAY, self::NOW + self::DAY, self::DAY],
            'all' => [self::NOW - 400 * self::DAY, self::NOW + self::DAY, 30 * self::DAY],
            '90d' => [self::NOW - 90 * self::DAY, self::NOW + self::DAY, self::DAY],
            '30d' => [self::NOW - 30 * self::DAY, self::NOW + self::DAY, self::DAY],
            '7d hourly' => [self::NOW - 7 * self::DAY, self::NOW + self::DAY, self::HOUR],
        ];
        foreach ($ranges as [$from, $to, $size]) {
            foreach ([[], [$f('page', 'contains', '/p')], [$f('country', 'not', 'XX')], $many, $paths] as $filters) {
                $query = ['site' => 'default', 'from' => $from, 'to' => $to, 'filters' => $filters];
                $view->stats($query);
                $view->series($query, $days($from, $to, $size));
                $view->hourly($query);
                $view->breakdown($query, 'page', 1000, 0);
                $view->breakdown($query, 'source', 1000, 0);
                $view->breakdown($query, 'event', 1000, 0);
                $this->assertCount(30, $view->goalTotalsAll($query, $goals));
                foreach ([$goals[1], $goals[2]] as $goal) {
                    $view->goalTotals($query, $goal);
                    $view->goalSeries($query, $goal, $days($from, $to, $size));
                    $view->goalBreakdown($query, $goal, 'path');
                }
                $view->funnelCounts($query, $funnel);
                $view->journeyPages($query, 5);
                $view->eventPropKeys($query, 'Goal1');
                $view->eventPropValues($query, 'Goal1', 'amount', 10);
            }
        }
        $this->assertLessThanOrEqual(100, $most);
        $this->assertGreaterThan(50, $most, 'the reads came close');
    }
}
