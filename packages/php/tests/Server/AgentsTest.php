<?php

declare(strict_types=1);

namespace Runlight\Tests\Server;

use PHPUnit\Framework\TestCase;
use Runlight\Http\Request;
use Runlight\Http\Response;
use Runlight\Json;
use Runlight\Runlight;
use Runlight\Server\Agents;
use Runlight\Server\Cli;
use Runlight\Store\Stores;
use Runlight\Tests\Fixture;
use Runlight\Tests\Support\FakeFetcher;

/** The port of the Node server's agents.test.ts: the access log reader that counts AI agents. */
final class AgentsTest extends TestCase
{
    private const GPTBOT = 'Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2; +https://openai.com/gptbot)';
    private const CLAUDE = 'Mozilla/5.0 (compatible; ClaudeBot/1.0; +claudebot@anthropic.com)';
    private const CHROME = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';

    private string $dir;

    protected function setUp(): void
    {
        $this->dir = sys_get_temp_dir() . '/runlight-agents-' . bin2hex(random_bytes(6));
        mkdir($this->dir);
    }

    protected function tearDown(): void
    {
        if (is_file("{$this->dir}/access.log")) {
            @chmod("{$this->dir}/access.log", 0644);
        }
        foreach (scandir($this->dir) ?: [] as $name) {
            if ($name !== '.' && $name !== '..') {
                unlink("{$this->dir}/$name");
            }
        }
        rmdir($this->dir);
    }

    private static function line(string $path, string $ua, int $status = 200, string $method = 'GET', string $time = '07/Oct/2026:13:55:36 -0400', string $vhost = ''): string
    {
        return ($vhost !== '' ? "$vhost " : '') . "203.0.113.9 - - [$time] \"$method $path HTTP/1.1\" $status 5120 \"-\" \"$ua\"";
    }

    private static function utc(int $y, int $m, int $d, int $h = 0, int $i = 0, int $s = 0): int
    {
        return gmmktime($h, $i, $s, $m, $d, $y) * 1000;
    }

    /** @return list<string> the files in the test's folder */
    private function files(): array
    {
        $names = array_values(array_diff(scandir($this->dir) ?: [], ['.', '..']));
        sort($names);
        return $names;
    }

    /** A Runlight that takes reports for example.com with the key rlo_site, and a Fetcher that reaches its routes. */
    private static function runlight(): array
    {
        $now = self::utc(2026, 10, 7, 18);
        $rl = new Runlight(['store' => Stores::sqlite(':memory:'), 'site' => ['hostnames' => ['example.com']], 'now' => static fn (): int => $now]);
        $rl->init();
        $rl->store->setSetting('observe-key:default', 'rlo_site');
        $routes = $rl->routes(['token' => 'owner']);
        $fetcher = new FakeFetcher(static fn (string $url, array $init): Response => $routes->handle(new Request($url, $init['method'] ?? 'GET', $init['headers'] ?? [], (string) ($init['body'] ?? ''))));
        return [$rl, $fetcher];
    }

    /**
     * A Fetcher like a small server that keeps each batch, answering with how many it took.
     *
     * @param \Closure(int, int): ?Response|null $answer an answer of its own for this post, given its number and size
     */
    private static function counter(int &$stored, int &$posts, ?\Closure $answer = null): FakeFetcher
    {
        return new FakeFetcher(static function (string $url, array $init) use (&$stored, &$posts, $answer): Response {
            $posts++;
            $n = count(Json::decode((string) $init['body'])->fetches);
            $own = $answer !== null ? $answer($posts, $n) : null;
            if ($own !== null) {
                return $own;
            }
            $stored += $n;
            return Response::json(['recorded' => $n]);
        });
    }

    public function testLogLinesNginxAndApacheCombinedAVhostColumnAndCaddysJson(): void
    {
        self::assertSame(
            ['method' => 'GET', 'url' => 'https://example.com/blog/post?x=1', 'status' => 200, 'userAgent' => self::GPTBOT, 'at' => self::utc(2026, 10, 7, 17, 55, 36)],
            Agents::parseLine(self::line('/blog/post?x=1', self::GPTBOT), 'https://example.com'),
        );
        self::assertNull(Agents::parseLine(self::line('/', self::GPTBOT)), 'with no host anywhere there is no page to name');
        self::assertSame('https://blog.example.com/', Agents::parseLine(self::line('/', self::GPTBOT, 200, 'GET', '07/Oct/2026:13:55:36 -0400', 'blog.example.com:443'))['url']);
        $caddy = Json::encode(['ts' => 1791399336.5, 'status' => 200, 'request' => ['method' => 'GET', 'host' => 'example.com', 'uri' => '/docs/', 'tls' => Json::object(), 'headers' => ['User-Agent' => [self::CLAUDE]]]]);
        self::assertSame(['method' => 'GET', 'url' => 'https://example.com/docs/', 'status' => 200, 'userAgent' => self::CLAUDE, 'at' => 1791399336500], Agents::parseLine($caddy));
        self::assertNull(Agents::parseLine('not a log line'));
        // A target is a path and query on the site, never read as an address: a backslash cannot name another host.
        self::assertSame('https://example.com//evil.example/x?y=1', Agents::parseLine(self::line('/\\evil.example/x?y=1', self::GPTBOT), 'https://example.com')['url']);
        self::assertSame('https://example.com/evil.example/x', Agents::parseLine(self::line('//evil.example/x', self::GPTBOT), 'https://example.com')['url']);

        // Only successful GETs from AI agents are worth sending.
        self::assertNotNull(Agents::agentFetch(self::line('/', self::GPTBOT), 'https://example.com'));
        self::assertNull(Agents::agentFetch(self::line('/', self::CHROME), 'https://example.com'), "people are the tracker's job");
        self::assertNull(Agents::agentFetch(self::line('/', self::GPTBOT, 404), 'https://example.com'));
        self::assertNull(Agents::agentFetch(self::line('/', self::GPTBOT, 200, 'POST'), 'https://example.com'));
    }

    public function testLinesAreReadAsTheNodeCommandReadsThem(): void
    {
        $fixture = Fixture::load('agents');
        $now = static fn (): int => $fixture['now'];
        foreach ($fixture['cases'] as $case) {
            $parsed = Agents::parseLine($case['line'], $case['site'] ?? null);
            if ($parsed !== null && is_float($parsed['at']) && is_nan($parsed['at'])) {
                $parsed['at'] = 'NaN';
            }
            self::assertSame($case['parsed'], $parsed, Fixture::label($case));
            self::assertSame($case['fetched'], Agents::agentFetch($case['line'], $case['site'] ?? null, $now), Fixture::label($case));
        }
    }

    public function testALogIsReadOnceCarriesOnWhereItStoppedAndStartsOverAfterRotation(): void
    {
        [$rl, $fetcher] = self::runlight();
        $to = 'http://127.0.0.1:9/runlight';
        $log = "{$this->dir}/access.log";
        $state = "{$this->dir}/state.json";
        $fetches = static fn (): array => $rl->store->db->all("SELECT path, name, ts FROM rl_events WHERE kind = 'fetch' ORDER BY ts, path");
        $run = static fn (): int|float => Agents::run(['log' => $log, 'to' => $to, 'key' => 'rlo_site', 'site' => 'https://example.com', 'state' => $state, 'fetcher' => $fetcher, 'out' => static function (): void {
        }]);

        file_put_contents($log, implode("\n", [self::line('/a', self::GPTBOT), self::line('/b', self::CHROME), self::line('/c', self::CLAUDE, 200, 'GET', '07/Oct/2026:13:56:00 -0400'), self::line('/style.css', self::GPTBOT), '']));
        self::assertSame(2, $run(), 'two pages count; the stylesheet and the person do not');
        $first = $fetches();
        self::assertSame([['/a', 'GPTBot'], ['/c', 'ClaudeBot']], array_map(static fn (array $f): array => [$f['path'], $f['name']], $first), 'Runlight keeps pages, not their assets');
        self::assertSame(self::utc(2026, 10, 7, 17, 55, 36), (int) $first[0]['ts'], 'counted when the page was served');
        self::assertSame('Bearer rlo_site', $fetcher->requests[0]['headers']['authorization']);
        self::assertSame('http://127.0.0.1:9/runlight/api/observe', $fetcher->requests[0]['url']);

        self::assertSame(0, $run(), 'nothing new, nothing sent');
        file_put_contents($log, self::line('/d', self::GPTBOT) . "\n", FILE_APPEND);
        self::assertSame(1, $run());

        rename($log, "$log.1");
        file_put_contents($log, self::line('/e', self::CLAUDE) . "\n");
        self::assertSame(1, $run(), 'a rotated log is read from the top');
        $paths = array_column($fetches(), 'path');
        sort($paths);
        self::assertSame(['/a', '/c', '/d', '/e'], $paths);
        unlink("$log.1");

        try {
            Agents::run(['log' => $log, 'to' => $to, 'key' => 'rlo_wrong', 'site' => 'https://example.com', 'fetcher' => $fetcher, 'out' => static function (): void {
            }]);
            self::fail('a wrong key is refused');
        } catch (\RuntimeException $error) {
            self::assertStringContainsString('refused the key', $error->getMessage());
        }

        // Lines for another host, a // path, an absolute target, an old line, and a bad byte: none stops the rest.
        $before = count($fetches());
        file_put_contents($log, implode('', [
            self::line('/f', self::GPTBOT, 200, 'GET', '07/Oct/2026:13:57:00 -0400', 'other.example:443') . "\n",
            self::line('//g', self::GPTBOT) . "\n",
            self::line('http://evil.example/h', self::GPTBOT) . "\n",
            self::line('/old', self::GPTBOT, 200, 'GET', '01/Sep/2026:10:00:00 -0400') . "\n",
            "\xff\xfe\n",
            self::line('/i', self::CLAUDE) . "\n",
        ]));
        self::assertSame(2, $run(), '/g and /i count; the other host, the absolute target, and the old line do not');
        $paths = array_column($fetches(), 'path');
        self::assertCount($before + 2, $paths);
        self::assertContains('/g', $paths);
        self::assertContains('/i', $paths);
        self::assertNotContains('/f', $paths);
        self::assertNotContains('/h', $paths);
        self::assertNotContains('/old', $paths);
        self::assertSame(0, $run(), 'the offset after a bad byte lands on the next line, so nothing is sent twice');

        // Rotated by copying and truncating: the same file, a new start, already longer than the old place.
        file_put_contents($log, self::line('/one', self::GPTBOT) . "\n");
        self::assertSame(1, $run());
        file_put_contents($log, self::line('/two', self::CLAUDE) . "\n" . self::line('/three', self::GPTBOT) . "\n");
        self::assertSame(2, $run(), 'both lines of the new log, none skipped');
    }

    public function testFollowingALogReadsWhatWasWrittenJustBeforeARotationThenTheNewLog(): void
    {
        [$rl, $fetcher] = self::runlight();
        $log = "{$this->dir}/access.log";
        file_put_contents($log, '');
        $polls = 0;
        // Each look at the log waits first; the steps run in that wait, as another process writing the log would.
        $sleep = static function () use (&$polls, $log): void {
            $polls++;
            if ($polls === 2) {
                file_put_contents($log, self::line('/before', self::GPTBOT) . "\n", FILE_APPEND);
                // Rotated before the reader looks again: the last line is in the renamed file only.
                file_put_contents($log, self::line('/last-old', self::CLAUDE) . "\n", FILE_APPEND);
                rename($log, "$log.1");
                file_put_contents($log, self::line('/new', self::GPTBOT) . "\n");
            }
        };
        $said = [];
        Agents::run(['log' => $log, 'to' => 'http://127.0.0.1:9/runlight', 'key' => 'rlo_site', 'site' => 'https://example.com', 'follow' => true, 'fetcher' => $fetcher, 'sleep' => $sleep, 'stop' => static function () use (&$polls): bool {
            return $polls >= 6;
        }, 'out' => static function (string $line) use (&$said): void {
            $said[] = $line;
        }]);
        $paths = array_column($rl->store->db->all("SELECT path FROM rl_events WHERE kind = 'fetch' ORDER BY path"), 'path');
        self::assertSame(['/before', '/last-old', '/new'], $paths);
        self::assertSame("Following $log. AI agent fetches go to http://127.0.0.1:9/runlight as they happen.", $said[0]);
        self::assertSame(['Sent 2 AI agent fetches.', 'Sent 1 AI agent fetches.'], array_slice($said, 1));
    }

    public function testAFailedBatchSendsNoneOfTheEarlierOnesAgainAndABadStateFileStartsOverWithAWord(): void
    {
        $stored = 0;
        $posts = 0;
        $failAt = 0;
        $fetcher = self::counter($stored, $posts, static function (int $post) use (&$failAt): ?Response {
            return $post === $failAt ? new Response('busy', 503) : null;
        });
        $log = "{$this->dir}/access.log";
        $state = "{$this->dir}/state.json";
        $quiet = static function (): void {
        };
        file_put_contents($log, implode('', array_map(static fn (int $i): string => self::line("/p$i", self::GPTBOT) . "\n", range(0, 1199))));
        $failAt = 2;
        try {
            Agents::run(['log' => $log, 'to' => 'http://127.0.0.1:9', 'key' => 'k', 'site' => 'https://example.com', 'state' => $state, 'fetcher' => $fetcher, 'out' => $quiet]);
            self::fail('the second batch fails');
        } catch (\RuntimeException $error) {
            self::assertSame('Runlight answered 503: busy', $error->getMessage());
        }
        self::assertSame(500, $stored, 'the first batch went');
        Agents::run(['log' => $log, 'to' => 'http://127.0.0.1:9', 'key' => 'k', 'site' => 'https://example.com', 'state' => $state, 'fetcher' => $fetcher, 'out' => $quiet]);
        self::assertSame(1200, $stored, 'each line once');

        file_put_contents($state, '{ not json');
        $said = [];
        $stored = 0;
        Agents::run(['log' => $log, 'to' => 'http://127.0.0.1:9', 'key' => 'k', 'site' => 'https://example.com', 'state' => $state, 'fetcher' => $fetcher, 'out' => static function (string $line) use (&$said): void {
            $said[] = $line;
        }]);
        self::assertMatchesRegularExpression('/^Could not read .*state\.json/', $said[0]);
        self::assertSame('Sent 1200 AI agent fetches from 1200 new lines.', $said[1]);
        self::assertSame(1200, $stored, 'read from the top');
        self::assertSame(filesize($log), Json::decode((string) file_get_contents($state))->offset);
    }

    public function testLinesWithNoHostAndNoSiteAreMentionedOnce(): void
    {
        $stored = 0;
        $posts = 0;
        $log = "{$this->dir}/access.log";
        file_put_contents($log, self::line('/a', self::GPTBOT) . "\n" . self::line('/b', self::GPTBOT) . "\n");
        $said = [];
        $sent = Agents::run(['log' => $log, 'to' => 'http://127.0.0.1:9', 'key' => 'k', 'fetcher' => self::counter($stored, $posts), 'out' => static function (string $line) use (&$said): void {
            $said[] = $line;
        }]);
        self::assertSame(0, $sent);
        self::assertSame(['Some lines have no host in them. Add --site https://your-site.example so they can be counted.', 'Sent 0 AI agent fetches from 2 new lines.'], $said);
        self::assertSame(0, $posts);
    }

    public function testOneRunAtATimeUsesAStateFileACrashedRunsLockIsTakenOverAndTheStateIsWrittenWhole(): void
    {
        $stored = 0;
        $posts = 0;
        $log = "{$this->dir}/access.log";
        $state = "{$this->dir}/state.json";
        $quiet = static function (): void {
        };
        $second = null;
        $run = null;
        // While the first run sends its first batch, a second one starts on the same state file.
        $fetcher = self::counter($stored, $posts, static function (int $post) use (&$second, &$run): ?Response {
            if ($post === 1) {
                try {
                    $run();
                    $second = 'ran';
                } catch (\RuntimeException $error) {
                    $second = $error->getMessage();
                }
            }
            return null;
        });
        $run = static fn (): int|float => Agents::run(['log' => $log, 'to' => 'http://127.0.0.1:9', 'key' => 'k', 'site' => 'https://example.com', 'state' => $state, 'fetcher' => $fetcher, 'out' => $quiet]);
        file_put_contents($log, implode('', array_map(static fn (int $i): string => self::line("/p$i", self::GPTBOT) . "\n", range(0, 1499))));
        self::assertSame(1500, $run());
        self::assertMatchesRegularExpression('/^Another run is using .*state\.json \(process \d+\)\. Wait for it to finish, or delete .*state\.json\.lock if none is running\.$/', (string) $second);
        self::assertSame(1500, $stored, 'each line once');
        self::assertSame(['access.log', 'state.json'], $this->files(), 'the lock is released and no temporary file is left');

        // A lock from a process that has ended is stale.
        $child = proc_open([PHP_BINARY, '-r', ''], [], $pipes);
        $ended = proc_get_status($child)['pid'];
        proc_close($child);
        file_put_contents("$state.lock", (string) $ended);
        file_put_contents($log, self::line('/late', self::GPTBOT) . "\n", FILE_APPEND);
        self::assertSame(1, $run());
        self::assertSame(1501, $stored);
        self::assertSame(['access.log', 'state.json'], $this->files());

        // A lock held by a running process is left alone.
        file_put_contents("$state.lock", (string) getmypid());
        try {
            $run();
            self::fail('the lock is held');
        } catch (\RuntimeException $error) {
            self::assertStringContainsString('(process ' . getmypid() . ')', $error->getMessage());
        }
        self::assertSame((string) getmypid(), file_get_contents("$state.lock"));
        unlink("$state.lock");
    }

    public function testFollowingALogThatCannotBeReadWaitsAndSaysSoAndARestartReadsALogRotatedMeanwhileFromItsStart(): void
    {
        if (function_exists('posix_getuid') && posix_getuid() === 0) {
            self::markTestSkipped('root reads every file');
        }
        $stored = 0;
        $posts = 0;
        $fetcher = self::counter($stored, $posts);
        $log = "{$this->dir}/access.log";
        $state = "{$this->dir}/state.json";
        file_put_contents($log, '');
        $polls = 0;
        $steps = [
            2 => static fn () => file_put_contents($log, self::line('/a', self::GPTBOT) . "\n", FILE_APPEND),
            4 => static fn () => chmod($log, 0),
            8 => static function () use ($log): void {
                chmod($log, 0644);
                file_put_contents($log, self::line('/b', self::GPTBOT) . "\n", FILE_APPEND);
            },
        ];
        $said = [];
        Agents::run(['log' => $log, 'to' => 'http://127.0.0.1:9', 'key' => 'k', 'site' => 'https://example.com', 'state' => $state, 'follow' => true, 'fetcher' => $fetcher, 'sleep' => static function () use (&$polls, $steps): void {
            $polls++;
            if (isset($steps[$polls])) {
                $steps[$polls]();
            }
        }, 'stop' => static function () use (&$polls): bool {
            return $polls >= 10;
        }, 'out' => static function (string $line) use (&$said): void {
            $said[] = $line;
        }]);
        self::assertSame(2, $stored, 'it carried on once the log could be read again');
        self::assertCount(1, array_filter($said, static fn (string $l): bool => str_starts_with($l, 'Could not read')), 'said once, not every poll');
        self::assertCount(0, array_filter($said, static fn (string $l): bool => str_starts_with($l, 'Could not send')));

        // Stopped, then the log was rotated: everything in the new log is unread.
        rename($log, "$log.1");
        file_put_contents($log, self::line('/c', self::GPTBOT) . "\n" . self::line('/d', self::GPTBOT) . "\n");
        $polls = 0;
        Agents::run(['log' => $log, 'to' => 'http://127.0.0.1:9', 'key' => 'k', 'site' => 'https://example.com', 'state' => $state, 'follow' => true, 'fetcher' => $fetcher, 'sleep' => static function () use (&$polls): void {
            $polls++;
        }, 'stop' => static function () use (&$polls): bool {
            return $polls >= 3;
        }, 'out' => static function (): void {
        }]);
        self::assertSame(4, $stored);
        self::assertSame(['access.log', 'access.log.1', 'state.json'], $this->files());
    }

    public function testASendThatCannotReachRunlightIsTriedAgainOnTheNextLook(): void
    {
        $stored = 0;
        $posts = 0;
        $fetcher = self::counter($stored, $posts, static function (int $post): ?Response {
            if ($post <= 2) {
                throw new \Runlight\Http\FetchError('Could not connect');
            }
            return null;
        });
        $log = "{$this->dir}/access.log";
        file_put_contents($log, '');
        $polls = 0;
        $said = [];
        Agents::run(['log' => $log, 'to' => 'http://127.0.0.1:9', 'key' => 'k', 'site' => 'https://example.com', 'follow' => true, 'fetcher' => $fetcher, 'sleep' => static function () use (&$polls, $log): void {
            if (++$polls === 1) {
                file_put_contents($log, self::line('/a', self::GPTBOT) . "\n");
            }
        }, 'stop' => static function () use (&$polls): bool {
            return $polls >= 4;
        }, 'out' => static function (string $line) use (&$said): void {
            $said[] = $line;
        }]);
        self::assertSame(1, $stored);
        self::assertSame(['Could not send, trying again shortly: Could not connect', 'Sent 1 AI agent fetches.'], array_slice($said, 1));
    }

    public function testTheCommandLine(): void
    {
        $run = function (string ...$args): array {
            $out = fopen('php://memory', 'w+');
            $err = fopen('php://memory', 'w+');
            $stored = 0;
            $posts = 0;
            $fetcher = self::counter($stored, $posts);
            $code = Cli::run($args, $this->dir, $out, $err, static fn (): int => 1_791_374_400_000, $fetcher);
            rewind($out);
            rewind($err);
            return [$code, (string) stream_get_contents($out), (string) stream_get_contents($err), $fetcher];
        };
        [$code, $out] = $run('agents', '--help');
        self::assertSame(0, $code);
        self::assertSame(Cli::AGENTS_HELP, $out);
        [$code, , $err] = $run('agents', '--log', 'access.log');
        self::assertSame(1, $code, 'no address and no key');
        self::assertSame(Cli::AGENTS_HELP, $err);
        [, $help] = $run('--help');
        self::assertStringContainsString("vendor/bin/runlight agents --log <file>  Count AI agents from a web server's access log", $help);

        $log = "{$this->dir}/access.log";
        file_put_contents($log, self::line('/a', self::GPTBOT) . "\n");
        [$code, , $err] = $run('agents', '--log', "{$this->dir}/missing.log", '--to', 'https://stats.example.com', '--key', 'k');
        self::assertSame(1, $code);
        self::assertSame("Runlight: No log at {$this->dir}/missing.log\n", $err);

        // --to and --key come from config.php when they are not given.
        file_put_contents("{$this->dir}/config.php", "<?php return ['RUNLIGHT_URL' => 'https://stats.example.com/', 'RUNLIGHT_OBSERVE_KEY' => 'rlo_all'];");
        [$code, $out, $err, $fetcher] = $run('agents', '--log', "{$this->dir}/./access.log", '--site', 'https://example.com', '--state', "{$this->dir}/state.json");
        self::assertSame([0, "Sent 1 AI agent fetches from 1 new lines.\n", ''], [$code, $out, $err]);
        self::assertSame('https://stats.example.com/api/observe', $fetcher->requests[0]['url']);
        self::assertSame('Bearer rlo_all', $fetcher->requests[0]['headers']['authorization']);
        self::assertSame(['fetches' => [['url' => 'https://example.com/a', 'userAgent' => self::GPTBOT, 'at' => self::utc(2026, 10, 7, 17, 55, 36)]]], Json::decode($fetcher->requests[0]['body'], true));
        $saved = Json::decode((string) file_get_contents("{$this->dir}/state.json"), true);
        self::assertSame(['ino', 'offset', 'head', 'length'], array_keys($saved));
        self::assertSame(filesize($log), $saved['offset']);
        unlink("{$this->dir}/config.php");
    }
}
