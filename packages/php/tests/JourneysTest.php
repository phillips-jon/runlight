<?php

declare(strict_types=1);

namespace Runlight\Tests;

use PHPUnit\Framework\TestCase;
use Runlight\Journeys;
use Runlight\Json;

/** Journeys, as journeys.test.ts tests them, and against tests/fixtures/journeys.json. */
final class JourneysTest extends TestCase
{
    /** @param array<string, list<string>> $visits */
    private static function rows(array $visits): array
    {
        $rows = [];
        foreach ($visits as $session => $pages) {
            foreach ($pages as $path) {
                $rows[] = ['session' => (string) $session, 'path' => $path];
            }
        }
        return $rows;
    }

    public function testJourneysLinePathsUpByStepWithFlowsAndFollowAStartAnEndAndOnePage(): void
    {
        $data = self::rows([
            'a' => ['/', '/pricing', '/signup'],
            'b' => ['/', '/pricing', '/pricing', '/docs'],
            'c' => ['/', '/blog'],
            'd' => ['/blog', '/', '/pricing'],
            'e' => ['/docs'],
        ]);
        $all = Journeys::journeys($data, ['steps' => 3]);
        $this->assertSame(5, $all['visits']);
        $this->assertSame(['items' => [['value' => '/', 'visits' => 3], ['value' => '/blog', 'visits' => 1], ['value' => '/docs', 'visits' => 1]], 'visits' => 5, 'left' => 1], $all['columns'][0]);
        $this->assertSame(['value' => '/pricing', 'visits' => 2], $all['columns'][1]['items'][0], 'a refresh counts once');
        $fromHome = array_values(array_filter($all['links'], fn ($l) => $l['step'] === 0 && $l['from'] === '/'));
        $this->assertSame([['/pricing', 2], ['/blog', 1]], array_map(fn ($l) => [$l['to'], $l['visits']], $fromHome));
        $this->assertCount(5, $all['paths']);
        // With two steps, visits a, b, and d go on to a third page, so only c went no further than step two.
        $two = Journeys::journeys($data, ['steps' => 2]);
        $this->assertSame([4, 1], [$two['columns'][1]['visits'], $two['columns'][1]['left']], 'the last step counts only visits that ended there');
        $this->assertSame(['pages' => ['/', '/blog'], 'visits' => 1], $all['paths'][0], 'ties in a fixed order');

        $fromPricing = Journeys::journeys($data, ['steps' => 3, 'start' => '/pricing']);
        $this->assertSame(3, $fromPricing['visits'], 'visits that reached /pricing, from there on');
        $this->assertSame([['value' => '/pricing', 'visits' => 3]], $fromPricing['columns'][0]['items']);

        $toSignup = Journeys::journeys($data, ['steps' => 4, 'end' => '/signup']);
        $this->assertSame([['pages' => ['/', '/pricing', '/signup'], 'visits' => 1]], $toSignup['paths']);

        $through = Journeys::journeys($data, ['steps' => 3, 'through' => ['step' => 1, 'value' => '/blog']]);
        $this->assertSame(1, $through['visits']);
    }

    public function testFixturesMatch(): void
    {
        $fixture = Fixtures::load('journeys', true);
        foreach ($fixture['runs'] as $run) {
            $options = $run['options'];
            if ($options['steps'] === 'NaN') {
                $options['steps'] = NAN;
            }
            $result = Journeys::journeys($fixture['datasets'][$run['dataset']], $options);
            $this->assertSame(Json::encode($run['result']), Json::encode($result), "dataset {$run['dataset']} with " . json_encode($run['options']));
        }
    }
}
