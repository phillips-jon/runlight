<?php

declare(strict_types=1);

namespace Runlight\Tests;

use PHPUnit\Framework\TestCase;
use Runlight\Query;

/** Replays the query fixture written from the TypeScript SDK. */
final class QueryTest extends TestCase
{
    public function testDimensionLists(): void
    {
        $fixture = Fixture::load('query');
        $this->assertSame($fixture['eventDimensions'], Query::EVENT_DIMENSIONS);
        $this->assertSame($fixture['sessionDimensions'], Query::SESSION_DIMENSIONS);
        $this->assertSame($fixture['dimensions'], Query::DIMENSIONS);
        $this->assertSame([...array_keys(Query::EVENT_DIMENSIONS), ...array_keys(Query::SESSION_DIMENSIONS), ...Query::FETCH_DIMENSIONS], Query::DIMENSIONS);
        $this->assertSame($fixture['maxFilters'], Query::MAX_FILTERS);
    }

    public function testDimensionTests(): void
    {
        foreach (Fixture::load('query')['dimensionTests'] as $case) {
            $this->assertSame(
                [$case['isDimension'], $case['isSessionDimension'], $case['isEventDimension']],
                [Query::isDimension($case['value']), Query::isSessionDimension($case['value']), Query::isEventDimension($case['value'])],
                $case['value'],
            );
        }
    }

    public function testParseFilter(): void
    {
        foreach (Fixture::load('query')['filters'] as $case) {
            $this->assertSame($case['filter'], Query::parseFilter($case['text']), Fixture::label($case['text']));
        }
    }
}
