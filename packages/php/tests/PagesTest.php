<?php

declare(strict_types=1);

namespace Runlight\Tests;

use PHPUnit\Framework\TestCase;
use Runlight\Accounts\Pages;

/** The account pages against tests/fixtures/pages.json, the TypeScript's HTML for the same inputs. */
final class PagesTest extends TestCase
{
    public function testStylesAndScriptMatch(): void
    {
        $fixture = Fixtures::load('pages', true);
        $this->assertSame($fixture['css'], Pages::AUTH_CSS);
        $this->assertSame($fixture['js'], Pages::AUTH_JS);
    }

    public function testPagesMatch(): void
    {
        $fixture = Fixtures::load('pages', true);
        foreach ($fixture['pages'] as $case) {
            $html = $case['opts'] === null
                ? Pages::{$case['fn']}($case['base'])
                : Pages::{$case['fn']}($case['base'], $case['opts']);
            $this->assertSame($case['html'], $html, "{$case['fn']} at \"{$case['base']}\"");
        }
        foreach ($fixture['roles'] as $case) {
            $this->assertSame($case['text'], Pages::roleText($case['role']));
        }
    }

    public function testSetupAsksForTheTokenWhenTold(): void
    {
        $page = Pages::setupPage('/runlight', ['code' => '', 'askCode' => true]);
        $this->assertMatchesRegularExpression('/RUNLIGHT_TOKEN/', $page);
        $this->assertMatchesRegularExpression('/action="\/runlight\/setup"/', $page);
        $this->assertMatchesRegularExpression('/href="\/runlight\/auth\.css"/', $page);
        $this->assertStringContainsString('as a member', Pages::invitePage('', ['code' => 'c', 'email' => 'a@b.c', 'role' => 'member', 'host' => 'x']));
    }
}
