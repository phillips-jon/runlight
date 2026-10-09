<?php

declare(strict_types=1);

namespace Runlight\Tests\Routes;

use PHPUnit\Framework\TestCase;
use Runlight\Http\Fetcher;
use Runlight\Http\Response;
use Runlight\Tests\Conformance\Player;

/** The route-level part of hardening.test.ts: a link domain's check. The rest belongs to the core, safefetch, and the stores. */
final class HardeningTest extends TestCase
{
    public function testALinkDomainsCheckSaysWhereTheDomainShouldPointForItsSetupSteps(): void
    {
        $saved = Player::clearEnv();
        try {
            $answers404 = new class () implements Fetcher {
                public function fetch(string $url, array $init = []): Response
                {
                    return new Response('no', 404);
                }
            };
            $rl = Make::runlight(['site' => ['hostnames' => ['example.com']], 'fetcher' => $answers404]);
            $rl->init();
            $rl->store->addLinkDomain('go.example.net', 'default', 0);
            $check = Make::body($rl->routes(['token' => 'secret'])->handle(Make::owner('/runlight/api/link-domains/go.example.net/check')));
            $this->assertSame('example.com', $check['target']['host'], "this dashboard's own name, for a CNAME");
            $this->assertIsArray($check['target']['addresses']);
            $this->assertFalse($check['working']);
        } finally {
            Player::restoreEnv($saved);
        }
    }
}
