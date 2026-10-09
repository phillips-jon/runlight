<?php

declare(strict_types=1);

namespace Runlight\Tests\Conformance;

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

/**
 * Replays conformance/http.json against the PHP core on every store, as
 * http-conformance.test.ts does against the TypeScript one: each step's answer
 * must equal the one the file holds.
 */
final class ConformanceTest extends TestCase
{
    private ?TestStores $stores = null;

    /** @return iterable<string, array{string, string, string}> */
    public static function scenarios(): iterable
    {
        foreach (TestStores::kinds() as $kind => $url) {
            foreach (Scenarios::all() as $scenario) {
                yield "$kind: {$scenario->name}" => [$kind, $url, $scenario->name];
            }
        }
    }

    #[DataProvider('scenarios')]
    public function testScenario(string $kind, string $url, string $name): void
    {
        if (!CoreTarget::available()) {
            $this->markTestSkipped('The PHP core is not here yet (no Runlight\Runlight or Runlight\Routes class), so there is nothing to replay the scenarios against.');
        }
        if (!class_exists(\Runlight\Store\Stores::class) || !method_exists(\Runlight\Store\Stores::class, 'fromDb')) {
            $this->markTestSkipped('Runlight\Store\Stores::fromDb(Db $db) is not here yet, so the runner cannot hand the core a fresh store.');
        }
        $scenario = Scenarios::named($name);
        $this->stores = new TestStores();
        $store = $this->stores->store($kind, $url);
        $answers = (new Player())->play($scenario, fn (array $runlight, array $routes) => new CoreTarget($runlight, $routes), $store);
        self::assertAnswers($scenario, $answers, $kind);
    }

    protected function tearDown(): void
    {
        $this->stores?->cleanup();
        $this->stores = null;
    }

    /**
     * Compares answer by answer and fails on the first that differs, with a diff of the two and the
     * scenario, step, method, and path it belongs to.
     *
     * @param list<\stdClass> $answers
     */
    public static function assertAnswers(\stdClass $scenario, array $answers, string $kind = 'fake'): void
    {
        $differ = [];
        foreach ($scenario->steps as $i => $step) {
            if (Normalizer::canonical($step->expect) !== Normalizer::canonical($answers[$i] ?? null)) {
                $differ[] = $i;
            }
        }
        self::assertCount(count($scenario->steps), $answers, "$scenario->name ($kind): one answer for each step");
        if ($differ === []) {
            self::assertTrue(true);
            return;
        }
        $i = $differ[0];
        $step = $scenario->steps[$i];
        $others = count($differ) > 1 ? ' Steps ' . implode(', ', array_map(fn ($n) => $n + 1, array_slice($differ, 1))) . ' differ too.' : '';
        self::assertSame(
            Normalizer::canonical($step->expect),
            Normalizer::canonical($answers[$i]),
            sprintf('%s (%s): step %d, %s %s answered differently.%s', $scenario->name, $kind, $i + 1, $step->method, $step->path, $others),
        );
    }
}
