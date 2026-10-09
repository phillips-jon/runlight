<?php

declare(strict_types=1);

namespace Runlight\Tests;

use PHPUnit\Framework\TestCase;
use Runlight\FunnelError;
use Runlight\Funnels;
use Runlight\GoalError;
use Runlight\Goals;
use Runlight\Json;

/**
 * Goals and funnels checked from the dashboard, against tests/fixtures/goals.json (written from the TypeScript
 * SDK by scripts/php-fixtures-store.mts), and the checks goals.test.ts and funnels.test.ts make.
 */
final class GoalsTest extends TestCase
{
    /** The answer as the fixture writes it: the row with a new id as "<random>", or the error. */
    private static function outcome(callable $fn, bool $fresh): string
    {
        try {
            $value = $fn();
            if ($fresh && preg_match('/^[0-9a-f]{24}$/D', (string) $value['id'])) {
                $value['id'] = '<random>';
            }
            return Json::encode(['value' => $value]);
        } catch (GoalError|FunnelError $error) {
            return Json::encode(['error' => ['message' => $error->getMessage(), 'code' => $error->code, 'params' => Json::object($error->params)]]);
        }
    }

    public function testGoalsAreCheckedAsTheTypeScriptSdkChecksThem(): void
    {
        $fixture = Fixtures::load('goals');
        $existing = Fixtures::load('goals', true)['existing'];
        $this->assertGreaterThan(50, count($fixture->goals));
        foreach ($fixture->goals as $i => $case) {
            $id = $case->id;
            $this->assertSame(Json::encode($case->result), self::outcome(static fn () => Goals::goalFrom($case->input, 's', $existing, 1000, $id), $id === null), "#$i " . Json::encode($case->input));
        }
    }

    public function testFunnelsAreCheckedAsTheTypeScriptSdkChecksThem(): void
    {
        $fixture = Fixtures::load('goals');
        $existing = Fixtures::load('goals', true)['existingFunnels'];
        foreach ($fixture->funnels as $i => $case) {
            $id = $case->id;
            $this->assertSame(Json::encode($case->result), self::outcome(static fn () => Funnels::funnelFrom($case->input, 's', $existing, 1000, $id), $id === null), "#$i " . Json::encode($case->input));
        }
    }

    public function testPagePatternsAndClickRules(): void
    {
        $fixture = Fixtures::load('goals', true);
        foreach ($fixture['patterns'] as $case) {
            $this->assertSame($case['result'], Goals::pagePattern($case['input']), $case['input']);
        }
        $goal = static fn (string $id, array $g): array => ['id' => $id, 'site' => 's', 'name' => $id, 'kind' => 'event', 'match' => $id, 'clickBy' => '', 'valueMode' => 'none', 'value' => 0, 'valueProp' => '', 'currency' => 'USD', 'createdAt' => 5, ...$g];
        $rules = Goals::clickRules(
            [['id' => 's', 'name' => 'S', 'hostnames' => ['www.example.com', 'shop.example.com'], 'timezone' => 'UTC'], ['id' => 't', 'name' => 'T', 'hostnames' => [], 'timezone' => 'UTC'], ['id' => 'u', 'name' => 'U', 'hostnames' => ['u.example'], 'timezone' => 'UTC']],
            [$goal(str_repeat('c', 24), ['name' => 'Buy', 'kind' => 'click', 'match' => '.buy', 'clickBy' => 'selector']), $goal(str_repeat('d', 24), ['name' => 'Out', 'kind' => 'click', 'match' => 'https://x.example/*', 'clickBy' => 'link', 'site' => 't']), $goal(str_repeat('e', 24), ['name' => 'E', 'site' => 'u'])],
        );
        $this->assertSame(Json::encode(Fixtures::load('goals')->rules), Json::encode($rules));
    }

    public function testGoalChecksSayWhatIsWrong(): void
    {
        $made = Goals::goalFrom(['name' => 'X', 'kind' => 'event', 'match' => 'X'], 'default', [], 1);
        $codes = [];
        foreach ([
            [['name' => 'x', 'kind' => 'event', 'match' => 'Y'], [$made]],
            [['name' => 'Y', 'kind' => 'event', 'match' => 'Y', 'currency' => 'dollars'], []],
            [['name' => 'Z', 'kind' => 'event', 'match' => 'Z', 'valueMode' => 'fixed', 'value' => -1], []],
            [['name' => 'W', 'kind' => 'event', 'match' => 'W', 'valueMode' => 'prop', 'valueProp' => 'a b'], []],
            [['name' => 'P', 'kind' => 'page', 'match' => '/p', 'valueMode' => 'prop'], []],
        ] as [$input, $existing]) {
            try {
                Goals::goalFrom($input, 'default', $existing, 1);
                $codes[] = 'none';
            } catch (GoalError $error) {
                $codes[] = $error->code;
            }
        }
        $this->assertSame(['goal_exists', 'goal_currency', 'goal_amount', 'goal_prop_name', 'goal_prop_kind'], $codes);
        $renamed = Goals::goalFrom(['name' => 'Renamed', 'kind' => 'event', 'match' => 'X'], 'default', [$made], 99, $made['id']);
        $this->assertSame([$made['id'], 1], [$renamed['id'], $renamed['createdAt']], 'a goal changed keeps its id and when it was made');
    }
}
