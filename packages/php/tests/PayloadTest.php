<?php

declare(strict_types=1);

namespace Runlight\Tests;

use PHPUnit\Framework\TestCase;
use Runlight\Json;
use Runlight\Payload;

/** Replays tracker bodies through parsePayload, as the TypeScript SDK read them. */
final class PayloadTest extends TestCase
{
    public function testFixture(): void
    {
        $fixture = Fixture::load('payload');
        $this->assertSame($fixture['maxBody'], Payload::MAX_BODY);
        foreach ($fixture['cases'] as $case) {
            $payload = Payload::parsePayload($case['text']);
            if ($payload !== null) {
                $payload['url'] = $payload['url']->href();
                $payload['props'] = $payload['props'] === null ? null : Json::encode(Json::object($payload['props']));
            }
            $this->assertSame($case['payload'], $payload, Fixture::label($case['text']));
        }
    }

    public function testPropsWithIndexKeysStayAnObject(): void
    {
        $payload = Payload::parsePayload('{"k":"event","u":"https://example.com/","n":"x","p":{"1":"b","0":"a"}}');
        $this->assertSame('{"0":"a","1":"b"}', Json::encode(Json::object($payload['props'])));
    }
}
