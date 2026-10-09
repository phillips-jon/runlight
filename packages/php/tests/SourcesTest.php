<?php

declare(strict_types=1);

namespace Runlight\Tests;

use PHPUnit\Framework\TestCase;
use Runlight\Http\Url;
use Runlight\Json;
use Runlight\Sources;

/** The TypeScript SDK's sources tests, then the fixture written from it. */
final class SourcesTest extends TestCase
{
    private static function visit(string $url, string $referrer = '', array $internal = []): array
    {
        return Sources::attribute(Sources::parsePage(new Url($url)), $referrer, $internal);
    }

    public function testNoReferrerAndNoTagsIsDirect(): void
    {
        $this->assertSame(['referrerHost' => '', 'referrerPath' => '', 'source' => '', 'channel' => 'Direct'], self::visit('https://example.com/'));
    }

    public function testSearchEnginesAreOrganicSearchByTheMostSpecificHost(): void
    {
        $this->assertSame('Organic Search', self::visit('https://example.com/', 'https://www.google.co.uk/')['channel']);
        $this->assertSame('Google', self::visit('https://example.com/', 'https://www.google.co.uk/')['source']);
        $this->assertSame('Gmail', Sources::sourceForHost('mail.google.com')['name']);
        $this->assertSame('Gemini', Sources::sourceForHost('gemini.google.com')['name']);
    }

    public function testAClickIdOnASearchReferrerIsPaidSearch(): void
    {
        $this->assertSame('Paid Search', self::visit('https://example.com/?gclid=abc', 'https://www.google.com/')['channel']);
        $this->assertSame('Paid Search', self::visit('https://example.com/?utm_source=google&utm_medium=cpc')['channel']);
    }

    public function testAiAssistantsAreTheAiChannelByReferrerOrByTag(): void
    {
        $this->assertSame(
            ['referrerHost' => 'chatgpt.com', 'referrerPath' => '/', 'source' => 'ChatGPT', 'channel' => 'AI'],
            self::visit('https://example.com/post', 'https://chatgpt.com/'),
        );
        $tagged = self::visit('https://example.com/post?utm_source=chatgpt.com');
        $this->assertSame('ChatGPT', $tagged['source']);
        $this->assertSame('AI', $tagged['channel']);
        $this->assertSame('Perplexity', self::visit('https://example.com/', 'https://www.perplexity.ai/search/x')['source']);
        $this->assertSame('AI', self::visit('https://example.com/', 'https://claude.ai/')['channel']);
    }

    public function testSocialEmailCampaignsAndReferrals(): void
    {
        $this->assertSame('Hacker News', self::visit('https://example.com/', 'https://news.ycombinator.com/item?id=1')['source']);
        $this->assertSame('Social', self::visit('https://example.com/', 'https://t.co/abc')['channel']);
        $this->assertSame('Email', self::visit('https://example.com/?utm_source=weekly&utm_medium=email')['channel']);
        $this->assertSame('Email', self::visit('https://example.com/?utm_source=newsletter')['channel']);
        $this->assertSame('Campaign', self::visit('https://example.com/?utm_source=partner&utm_campaign=launch')['channel']);
        $this->assertSame('partner', self::visit('https://example.com/?utm_source=partner&utm_campaign=launch')['source']);
        $this->assertSame('Referral', self::visit('https://example.com/', 'https://someblog.net/post')['channel']);
        $this->assertSame('someblog.net', self::visit('https://example.com/', 'https://someblog.net/post')['source']);
        $this->assertSame('Product Hunt', self::visit('https://example.com/?ref=producthunt')['source']);
    }

    public function testTheSitesOwnHostsAreNotAReferrer(): void
    {
        $this->assertSame('Direct', self::visit('https://example.com/b', 'https://www.example.com/a')['channel']);
        $this->assertSame('', self::visit('https://example.com/b', 'https://shop.example.com/a', ['shop.example.com'])['referrerHost']);
        $this->assertSame('Direct', self::visit('https://example.com/b', 'not a url')['channel']);
    }

    public function testOnlyThePathAndCampaignParametersAreKeptFromAUrl(): void
    {
        $page = Sources::parsePage(new Url('https://www.example.com/a/b?email=x@y.z&utm_campaign=spring&fbclid=123#top'));
        $this->assertSame('example.com', $page['hostname']);
        $this->assertSame('/a/b#top', $page['path']);
        $this->assertSame('spring', $page['utm']['campaign']);
        $this->assertTrue($page['paid']);
        $this->assertStringNotContainsString('x@y.z', Json::encode($page));
        $this->assertStringNotContainsString('123', Json::encode($page));
    }

    public function testAppReferrersEmailClickTrackersAndWebmailAreNamed(): void
    {
        $this->assertSame('Gmail', Sources::sourceForHost('com.google.android.gm')['name']);
        $this->assertSame('Gmail', self::visit('https://example.com/', 'android-app://com.google.android.gm/')['source']);
        $this->assertSame('Email', self::visit('https://example.com/', 'https://com.google.android.gm/')['channel']);
        $this->assertSame('Kit', self::visit('https://example.com/', 'https://15a992bb.click.convertkit-mail4.com/x')['source']);
        $this->assertSame('Email', self::visit('https://example.com/', 'https://15a992bb.click.convertkit-mail4.com/x')['channel']);
        $this->assertSame('mail01.orange.fr', self::visit('https://example.com/', 'https://mail01.orange.fr/')['source']);
        $this->assertSame('Email', self::visit('https://example.com/', 'https://mail01.orange.fr/')['channel']);
        $this->assertSame('Email', self::visit('https://example.com/', 'https://mail.aol.com/')['channel']);
        $this->assertSame('Referral', self::visit('https://example.com/', 'https://mailbox.org/')['channel'], 'only mail. or webmail. prefixes count');
    }

    public function testHostsAndAliases(): void
    {
        $fixture = Fixture::load('sources');
        foreach ($fixture['hosts'] as $case) {
            $this->assertSame($case['source'], Sources::sourceForHost($case['host']), Fixture::label($case['host']));
        }
        foreach ($fixture['aliases'] as $case) {
            $this->assertSame($case['source'], Sources::sourceForAlias($case['alias']), Fixture::label($case['alias']));
        }
        foreach ($fixture['stripWww'] as $case) {
            $this->assertSame($case['host'], Sources::stripWww($case['input']), Fixture::label($case['input']));
        }
    }

    public function testPages(): void
    {
        foreach (Fixture::load('sources')['pages'] as $case) {
            $url = Url::parse($case['url']);
            $this->assertSame($case['page'], $url === null ? null : Sources::parsePage($url), Fixture::label($case['url']));
        }
    }

    public function testVisits(): void
    {
        $cases = Fixture::load('sources')['visits'];
        $failures = [];
        foreach ($cases as $case) {
            $got = Sources::attribute(Sources::parsePage(new Url($case['url'])), $case['referrer'], $case['internal']);
            if ($got !== $case['attribution']) {
                $failures[] = Fixture::label([$case['url'], $case['referrer'], $case['internal']]) . ' gave ' . Fixture::label($got) . ' not ' . Fixture::label($case['attribution']);
            }
        }
        $this->assertGreaterThan(300, count($cases));
        $this->assertSame([], array_slice($failures, 0, 20));
    }

    public function testRecordedAndReadablePaths(): void
    {
        $fixture = Fixture::load('sources');
        foreach ($fixture['recordedPaths'] as $case) {
            $this->assertSame($case['path'], Sources::recordedPath($case['input']), Fixture::label($case['input']));
        }
        foreach ($fixture['readablePaths'] as $case) {
            $this->assertSame($case['path'], Sources::readablePath($case['input']), Fixture::label($case['input']));
        }
    }
}
