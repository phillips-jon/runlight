<?php

declare(strict_types=1);

namespace Runlight\Tests;

use PHPUnit\Framework\TestCase;
use Runlight\Messages;

/** The translator against tests/fixtures/messages.json: Intl.PluralRules' forms and the TypeScript's words. */
final class MessagesTest extends TestCase
{
    public function testLanguages(): void
    {
        $this->assertSame(Fixtures::load('messages', true)['languages'], Messages::languages());
    }

    public function testPluralFormsMatchIntl(): void
    {
        $fixture = Fixtures::load('messages', true);
        // NaN and the infinities come as text, and so do whole numbers too long for a PHP int.
        $numbers = array_map(static fn ($n) => match (true) {
            $n === 'NaN' => NAN,
            $n === 'Infinity' => INF,
            $n === '-Infinity' => -INF,
            is_string($n) => (float) $n,
            default => $n,
        }, $fixture['numbers']);
        foreach ($fixture['plural'] as $lang => $forms) {
            foreach ($numbers as $i => $n) {
                $this->assertSame($forms[$i], Messages::plural($lang, $n), "$lang " . var_export($fixture['numbers'][$i], true));
            }
        }
    }

    public function testWordsMatch(): void
    {
        foreach (Fixtures::load('messages', true)['words'] as $set) {
            $words = Messages::translator($set['lang']);
            $this->assertSame($set['code'], $words['lang']);
            foreach ($set['t'] as $case) {
                $this->assertSame($case['text'], ($words['t'])($case['key'], $case['vars']), "{$set['lang']} {$case['key']}");
            }
            foreach ($set['tn'] as $case) {
                $this->assertSame($case['text'], ($words['tn'])($case['key'], $case['n'], ['n' => $case['n'], 'name' => 'x']), "{$set['lang']} {$case['key']} {$case['n']}");
            }
        }
    }

    public function testFrenchCountsZeroAsOne(): void
    {
        $this->assertSame('one', Messages::plural('fr', 0));
        $this->assertSame('one', Messages::plural('fr', 1.5));
        $this->assertSame('many', Messages::plural('fr', 1_000_000));
        $this->assertSame('other', Messages::plural('en', 0));
    }
}
