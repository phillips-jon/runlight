<?php

declare(strict_types=1);

namespace Runlight\Tests\Core;

use PHPUnit\Framework\Attributes\DataProvider;
use Runlight\Http\Request;
use Runlight\Http\Response;
use Runlight\Json;
use Runlight\LinkError;
use Runlight\Runlight;
use Runlight\Store\Stores;

/** Short links, as links.test.ts tests them: made through Links, followed through linkHandler() and linkDomainResponse(). */
final class LinksTest extends CoreTestCase
{
    /** A link domain added as the routes add one. */
    private static function addDomain(Harness $t, string $domain, string $site = 'default'): void
    {
        $t->store()->addLinkDomain($domain, $site, $t->now);
        $t->rl->forgetLinkDomains();
    }

    private static function removeDomain(Harness $t, string $domain): void
    {
        $t->store()->removeLinkDomain($domain);
        $t->rl->forgetLinkDomains();
    }

    #[DataProvider('kinds')]
    public function testCreateFollowAndCountAShortLink(string $kind): void
    {
        $t = new Harness($kind);
        $link = $t->rl->links->create('default', ['url' => 'https://thedailypreset.com/presets/golden?ref=x']);
        self::assertMatchesRegularExpression('/^[a-z2-9]{6}$/', $link['slug']);
        self::assertSame('thedailypreset.com/presets/golden', $link['name']);

        $follow = $t->rl->linkHandler();
        $go = fn (string $path, array $headers = []): Response => $follow(new Request("https://example.com$path", 'GET', ['user-agent' => Harness::CHROME_MAC, 'x-forwarded-for' => '203.0.113.9', ...$headers]));
        $response = $go("/go/{$link['slug']}?utm_source=newsletter&utm_medium=email", ['referer' => 'https://mail.google.com/']);
        self::assertSame(302, $response->status);
        self::assertSame('https://thedailypreset.com/presets/golden?ref=x', $response->headers->get('location'));
        self::assertSame('no-store', $response->headers->get('cache-control'));
        self::assertSame('no-referrer-when-downgrade', $response->headers->get('referrer-policy'));
        $missing = $go('/go/nope');
        self::assertSame(404, $missing->status);
        self::assertSame('Not found', $missing->text());
        self::assertSame('text/plain; charset=utf-8', $missing->headers->get('content-type'));
        // Link previews and crawlers are sent on but not counted.
        self::assertSame(302, $go("/go/{$link['slug']}", ['user-agent' => 'facebookexternalhit/1.1'])->status);

        $today = $t->today();
        $list = $t->store()->links('default', $today['from'], $today['to']);
        self::assertSame(1, $list[0]['clicks']);
        self::assertSame(1, $list[0]['visitors']);
        self::assertEquals([['value' => 'Newsletter', 'visitors' => 1, 'events' => 1]], $t->store()->linkBreakdown('default', $link['id'], $today['from'], $today['to'], 'source', 10));

        // Clicks are not visits: the site's own numbers do not move.
        $site = $t->stats($today);
        self::assertSame(0, $site['visitors']);
        self::assertSame(0, $site['pageviews']);
    }

    #[DataProvider('kinds')]
    public function testSlugsAreCheckedUniquePerDomainAndFreedByDeleting(string $kind): void
    {
        $t = new Harness($kind);
        $links = $t->rl->links;
        $links->create('default', ['url' => 'https://a.com', 'slug' => 'launch']);
        try {
            $links->create('default', ['url' => 'https://b.com', 'slug' => 'launch']);
            self::fail('a taken slug');
        } catch (LinkError $e) {
            self::assertStringContainsString('taken', $e->getMessage());
            self::assertSame(['link_taken', ['slug' => 'launch']], [$e->code, $e->params], 'a code the dashboard can translate');
        }
        foreach ([[['url' => 'https://b.com', 'slug' => 'has space'], 'link_slug'], [['url' => 'javascript:alert(1)'], 'link_protocol'], [['url' => 'not a url'], 'link_url'], [['url' => 'https://b.com', 'domain' => 't.unknown.com'], 'link_domain']] as [$input, $code]) {
            try {
                $links->create('default', $input);
                self::fail($code);
            } catch (LinkError $e) {
                self::assertSame($code, $e->code);
            }
        }
        $id = $t->store()->links('default', 0, $t->now + 1)[0]['id'];
        $renamed = $links->update($id, ['slug' => 'launch-2', 'name' => 'Launch']);
        self::assertSame('launch-2', $renamed['slug']);
        self::assertSame('Launch', $renamed['name']);
        self::assertSame('https://a.com/', $renamed['url'], 'a key left out is left alone');
        $links->remove($id);
        $links->create('default', ['url' => 'https://c.com', 'slug' => 'launch-2']);
        self::assertCount(1, $t->store()->links('default', 0, $t->now + 1), "a deleted link's slug is free again");
        $this->expectException(\RangeException::class);
        $links->remove('nope');
    }

    #[DataProvider('kinds')]
    public function testCustomLinkDomainsAnswerAtTheirRootAndOnlyForTheirOwnLinks(string $kind): void
    {
        $t = new Harness($kind);
        $t->rl->init();
        self::addDomain($t, 't.thedailypreset.com');
        $t->rl->links->create('default', ['url' => 'https://thedailypreset.com/a', 'slug' => 'a', 'domain' => 't.thedailypreset.com']);
        $t->rl->links->create('default', ['url' => 'https://example.com/b', 'slug' => 'b']);

        $at = fn (string $host, string $path): ?Response => $t->rl->linkDomainResponse(new Request("https://$host$path", 'GET', ['host' => $host, 'user-agent' => Harness::CHROME_MAC]));
        self::assertSame('https://thedailypreset.com/a', $at('t.thedailypreset.com', '/a')?->headers->get('location'));
        self::assertSame(404, $at('t.thedailypreset.com', '/b')?->status, "the main site's links are not on the link domain");
        self::assertNull($at('example.com', '/a'), 'other hosts carry on as normal');
        self::assertNull($at('t.thedailypreset.com', '/runlight/api/sites'), "the dashboard's own paths are left alone");
        // The app's own link path answers for every link, as a fallback that never changes.
        self::assertSame(302, ($t->rl->linkHandler())(new Request('https://example.com/go/a', 'GET', ['user-agent' => Harness::CHROME_MAC]))->status);
        $check = $at('t.thedailypreset.com', Runlight::LINK_DOMAIN_CHECK);
        self::assertSame('{"runlight":true,"domain":"t.thedailypreset.com"}', $check?->text());
        self::assertSame('application/json', $check?->headers->get('content-type'));

        // Removing the domain keeps its links: they fall back to the app's own path.
        self::removeDomain($t, 't.thedailypreset.com');
        self::assertNull($at('t.thedailypreset.com', '/a'), 'the removed domain is no longer answered');
        self::assertSame('https://thedailypreset.com/a', ($t->rl->linkHandler())(new Request('https://example.com/go/a', 'GET', ['user-agent' => Harness::CHROME_MAC]))->headers->get('location'));
        $a = array_values(array_filter($t->store()->links('default', 0, $t->now + 1), static fn (array $l): bool => $l['slug'] === 'a'))[0];
        self::assertSame('t.thedailypreset.com', $a['domain'], 'the link remembers its domain');

        // Adding it back brings the links home again.
        self::addDomain($t, 't.thedailypreset.com');
        self::assertSame('https://thedailypreset.com/a', $at('t.thedailypreset.com', '/a')?->headers->get('location'));
    }

    #[DataProvider('kinds')]
    public function testASlugIsUniqueAcrossEveryDomain(string $kind): void
    {
        $t = new Harness($kind);
        $t->rl->init();
        self::addDomain($t, 't.a.com');
        $t->rl->links->create('default', ['url' => 'https://a.com/sale', 'slug' => 'sale', 'domain' => 't.a.com']);
        $this->expectException(LinkError::class);
        $t->rl->links->create('default', ['url' => 'https://b.com/sale', 'slug' => 'sale']);
    }

    #[DataProvider('kinds')]
    public function testCsvRowsInTheUmamiForksFormatImportAndBadRowsSayWhy(string $kind): void
    {
        $t = new Harness($kind);
        $t->rl->init();
        self::addDomain($t, 't.thedailypreset.com');
        $result = $t->rl->links->import('default', [
            ['link_name' => 'Golden hour', 'destination_url' => 'https://thedailypreset.com/golden', 'link_slug' => 'golden', 'tracking_domain' => 't.thedailypreset.com'],
            ['name' => 'Plain', 'url' => 'https://example.com/plain'],
            ['name' => 'Broken', 'url' => 'not a url'],
            ['name' => 'Duplicate', 'url' => 'https://example.com/x', 'slug' => 'golden', 'domain' => 't.thedailypreset.com'],
        ]);
        self::assertSame(2, $result['created']);
        self::assertSame([3, 4], array_column($result['failed'], 'row'));
        self::assertSame('{"row":3,"reason":"The destination must be a full URL, starting with https://","code":"link_url","params":{}}', Json::encode($result['failed'][0]));
        $links = $t->store()->links('default', 0, $t->now + 1);
        self::assertCount(2, $links);
        self::assertNotEmpty(array_filter($links, static fn (array $l): bool => $l['domain'] === 't.thedailypreset.com' && $l['slug'] === 'golden'));
    }

    public function testALinkOnAnotherSitesDomainIsRefused(): void
    {
        $rl = new Runlight(['store' => Stores::sqlite(':memory:'), 'sites' => [['id' => 'a', 'hostnames' => ['a.com']], ['id' => 'b', 'hostnames' => ['b.com']]]]);
        $rl->init();
        $rl->store->addLinkDomain('go.a.com', 'a', 0);
        self::assertSame('go.a.com', $rl->links->create('a', ['url' => 'https://a.com/x', 'domain' => 'go.a.com'])['domain']);
        $this->expectException(LinkError::class);
        $rl->links->create('b', ['url' => 'https://b.com/x', 'domain' => 'go.a.com']);
    }

    public function testAClickIsCountedAsAClickWithItsSourceAndNeverWithAnAddress(): void
    {
        $t = new Harness('sqlite');
        $link = $t->rl->links->create('default', ['url' => 'https://a.com/', 'slug' => 'x']);
        ($t->rl->linkHandler())(new Request('https://example.com/go/x', 'GET', ['user-agent' => Harness::CHROME_MAC, 'x-forwarded-for' => '192.0.2.77', 'accept-language' => 'fr-CA,fr;q=0.9', 'host' => 'example.com:8080']));
        $event = $t->store()->db->all("SELECT kind, name, link, path, hostname FROM rl_events")[0];
        self::assertSame(['kind' => 'click', 'name' => 'x', 'link' => $link['id'], 'path' => '/go/x', 'hostname' => 'example.com'], array_map('strval', $event));
        $session = $t->store()->db->all('SELECT language, pageviews FROM rl_sessions')[0];
        self::assertSame('fr-CA', $session['language']);
        self::assertStringNotContainsString('192.0.2.77', Json::encode($t->store()->db->all('SELECT * FROM rl_sessions')));
        // A HEAD request, as a link checker sends, is answered and not counted.
        ($t->rl->linkHandler())(new Request('https://example.com/go/x', 'HEAD', ['user-agent' => Harness::CHROME_MAC]));
        self::assertSame(1, $t->count('SELECT COUNT(*) AS n FROM rl_events'));
    }
}
