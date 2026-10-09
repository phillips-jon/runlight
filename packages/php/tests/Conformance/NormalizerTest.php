<?php

declare(strict_types=1);

namespace Runlight\Tests\Conformance;

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Runlight\Tests\Fixtures;

/** The normalizer against cases run through normalize() in http-conformance.ts (tests/fixtures/conformance-normalize.json). */
final class NormalizerTest extends TestCase
{
    /** @return iterable<string, array{mixed, mixed}> */
    public static function cases(): iterable
    {
        foreach (Fixtures::load('conformance-normalize') as $i => $case) {
            yield 'case ' . ($i + 1) => [$case->input, $case->output];
        }
    }

    #[DataProvider('cases')]
    public function testNormalizesAsTypeScriptDoes(mixed $input, mixed $output): void
    {
        $this->assertSame(Normalizer::canonical($output), Normalizer::canonical(Normalizer::normalize($input)));
    }

    public function testKeepsObjectsAndArraysApart(): void
    {
        $this->assertSame('{"a":{},"b":[]}', \Runlight\Json::encode(Normalizer::normalize((object) ['a' => new \stdClass(), 'b' => []])));
    }

    public function testCookieShape(): void
    {
        $this->assertSame('rl_session=<value>; Path=/; HttpOnly', Normalizer::cookieShape('rl_session=abc123; Path=/; HttpOnly'));
        $this->assertSame('rl_session=; Path=/; Max-Age=0', Normalizer::cookieShape('rl_session=; Path=/; Max-Age=0'));
        $this->assertSame('a=<value>', Normalizer::cookieShape('a=b=c'));
        $this->assertSame('no value here', Normalizer::cookieShape('no value here'));
        $this->assertSame('=x; Path=/', Normalizer::cookieShape('=x; Path=/'));
    }

    public function testCanonicalIgnoresKeyOrderAndNumberForm(): void
    {
        $this->assertSame(
            Normalizer::canonical(\Runlight\Json::decode('{"b":1,"a":[{"y":2.0,"x":null}]}')),
            Normalizer::canonical(\Runlight\Json::decode('{"a":[{"x":null,"y":2}],"b":1.0}')),
        );
        $this->assertNotSame(Normalizer::canonical(\Runlight\Json::decode('{"a":{}}')), Normalizer::canonical(\Runlight\Json::decode('{"a":[]}')));
        $this->assertNotSame(Normalizer::canonical(\Runlight\Json::decode('[1,2]')), Normalizer::canonical(\Runlight\Json::decode('[2,1]')));
    }
}
