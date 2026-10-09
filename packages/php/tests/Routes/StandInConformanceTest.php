<?php

declare(strict_types=1);

namespace Runlight\Tests\Routes;

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Runlight\Tests\Conformance\Normalizer;
use Runlight\Tests\Conformance\Player;
use Runlight\Tests\Conformance\Scenarios;

/**
 * Until the PHP core is here, replays conformance/http.json's scenarios that lean mostly on the routes, accounts,
 * and OAuth against the stand-in, and requires every step but those that need the core (counted visits, links,
 * reports, and the like) to answer exactly as the TypeScript did. Once Runlight\Runlight exists the full runner
 * (tests/Conformance) replays every step against it, and this skips.
 */
final class StandInConformanceTest extends TestCase
{
    /** Each scenario played here, with the steps (counted from 1) whose answers need the core. */
    private const SCENARIOS = [
        'who may do what' => [],
        'an install with no token' => [],
        'an install left open on purpose' => [2],
        'refusals, their codes, and tickets' => [16, 17, 18, 21],
        'share links' => [13, 14, 15, 16, 17, 18, 24],
        'API tokens, manage tokens, and what each may do' => [12, 13, 20, 21, 28, 29, 39, 40, 65],
        'the MCP server and every tool' => [7, 22, 23, 24, 25, 26, 28, 29, 30, 31, 32, 33, 34, 35, 36, 41, 43],
        'OAuth: discovery, registration, consent, and tokens' => [46, 48],
        'accounts: setup, signing in, people, roles, and two-factor' => [],
        'accounts: the first account on an install with no token' => [],
        'accounts: the first account on an install left open' => [],
        'mail settings, email reports, and unsubscribing' => [25, 26, 27, 28, 30, 31, 32, 34, 35, 36, 37, 39, 42, 44, 45, 46, 48, 49],
        'goals, funnels, and links' => [9, 10, 12, 13, 14, 15, 16, 18],
        "goals of every kind, revenue, funnels, and the tracker's click rules" => [42, 43, 44, 45, 46, 47, 56, 59, 62, 63, 66],
        'a site with no hostnames counts any host' => [3, 5],
        'AI agent reports, observe keys, scheduled checks, and the picker' => [3, 4, 5, 9, 10, 16, 18, 20, 21, 22],
        'the assistant: settings, limits, models, and questions' => [33],
    ];

    /** @return iterable<string, array{string}> */
    public static function scenarios(): iterable
    {
        foreach (array_keys(self::SCENARIOS) as $name) {
            yield $name => [$name];
        }
    }

    #[DataProvider('scenarios')]
    public function testTheRoutesAnswerAsTheTypeScriptDid(string $name): void
    {
        if (Make::core()) {
            $this->markTestSkipped('The PHP core is here, so tests/Conformance replays every step against it.');
        }
        $scenario = Scenarios::named($name);
        $log = ini_set('error_log', '/dev/null');
        try {
            $answers = (new Player())->play($scenario, fn (array $runlight, array $routes) => StandIn::target($runlight, $routes));
        } finally {
            ini_set('error_log', (string) $log);
        }
        $skipped = self::SCENARIOS[$name];
        $checked = 0;
        foreach ($scenario->steps as $i => $step) {
            if (in_array($i + 1, $skipped, true)) {
                continue;
            }
            $this->assertSame(Normalizer::canonical($step->expect), Normalizer::canonical($answers[$i] ?? null), sprintf('%s: step %d, %s %s', $name, $i + 1, $step->method, $step->path));
            $checked++;
        }
        $this->assertGreaterThan(0, $checked);
    }
}
