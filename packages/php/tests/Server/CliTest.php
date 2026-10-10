<?php

declare(strict_types=1);

namespace Runlight\Tests\Server;

use PHPUnit\Framework\TestCase;
use Runlight\Http\Request;
use Runlight\Server\Cli;
use Runlight\Server\Config;
use Runlight\Server\DbIp;
use Runlight\Tests\Fixture;

/** The drop-in's settings, its command line, and DB-IP's monthly download, in a project folder of their own. */
final class CliTest extends TestCase
{
    private string $root;

    protected function setUp(): void
    {
        $this->root = sys_get_temp_dir() . '/runlight-cli-' . bin2hex(random_bytes(6));
        mkdir($this->root);
    }

    protected function tearDown(): void
    {
        $remove = static function (string $path) use (&$remove): void {
            if (is_dir($path) && !is_link($path)) {
                foreach (scandir($path) ?: [] as $name) {
                    if ($name !== '.' && $name !== '..') {
                        $remove("$path/$name");
                    }
                }
                rmdir($path);
            } elseif (file_exists($path)) {
                unlink($path);
            }
        };
        $remove($this->root);
    }

    /** @param array<string, string> $settings */
    private function configure(array $settings): void
    {
        file_put_contents("{$this->root}/config.php", '<?php return ' . var_export($settings, true) . ';');
    }

    /** @return array{int, string, string} the exit code, what it printed, and what it complained */
    private function cli(string ...$args): array
    {
        $out = fopen('php://memory', 'w+');
        $err = fopen('php://memory', 'w+');
        $code = Cli::run($args, $this->root, $out, $err, static fn (): int => 1_791_374_400_000);
        rewind($out);
        rewind($err);
        return [$code, (string) stream_get_contents($out), (string) stream_get_contents($err)];
    }

    public function testSettingsComeFromConfigPhpWithPathsFromTheProjectFolder(): void
    {
        $this->configure(['RUNLIGHT_URL' => 'https://stats.example.com', 'TRUST_PROXY' => 'cf-connecting-ip', 'RUNLIGHT_GEO' => 'off']);
        $config = new Config($this->root);
        $this->assertSame('https://stats.example.com', $config->url());
        $this->assertSame('cf-connecting-ip', $config->trustProxy());
        $this->assertSame("{$this->root}/runlight-data", $config->dataDir());
        $this->assertSame(0700, fileperms($config->dataDir()) & 0777, 'the data folder is private');
        $this->assertSame("Require all denied\n", file_get_contents("{$this->root}/runlight-data/.htaccess"), 'Apache turns it away without mod_rewrite');
        $this->assertNull($config->geo());
        $this->assertNull($config->dbIp());

        $secret = $config->secret();
        $this->assertMatchesRegularExpression('/^[0-9a-f]{64}$/', $secret);
        $this->assertSame($secret, (new Config($this->root))->secret(), 'the secret is made once and kept');
        $this->assertSame(0600, fileperms("{$this->root}/runlight-data/secret") & 0777);

        $this->configure(['RUNLIGHT_URL' => 'https://stats.example.com/dashboard']);
        $this->expectExceptionMessage("set RUNLIGHT_URL to the dashboard's address only");
        (new Config($this->root))->url();
    }

    public function testTheSetupCodeIsWrittenDownOnceAndUnlocksTheFirstAccount(): void
    {
        $this->configure(['RUNLIGHT_URL' => 'https://stats.example.com', 'RUNLIGHT_GEO' => 'off']);
        $config = new Config($this->root);
        $server = $config->standalone();
        $text = (string) file_get_contents($config->setupFile());
        $this->assertMatchesRegularExpression('#^Open this link to create the first Runlight account\. It works only while Runlight has no account\.\nhttps://stats\.example\.com/setup\?code=[A-Za-z0-9_-]{12}\n$#', $text);
        $this->assertSame($config->setupCode(), (new Config($this->root))->setupCode(), 'every request reads the same code');
        $page = $server->handle(new Request('https://stats.example.com/'));
        $this->assertSame(403, $page->status);
        $this->assertStringContainsString('in the file setup.txt', $page->text());
        $this->assertSame(200, $server->handle(new Request('https://stats.example.com/setup?code=' . $config->setupCode()))->status);

        [$code, $out] = $this->cli('setup');
        $this->assertSame(0, $code);
        $this->assertSame($text, $out);
    }

    public function testPasswordMakesTheOwnerThenGivesANewPasswordAndTurnsOffTwoFactor(): void
    {
        $this->configure(['RUNLIGHT_GEO' => 'off']);
        [$code, $out] = $this->cli('password', 'Jon@Example.com');
        $this->assertSame(0, $code);
        $this->assertMatchesRegularExpression('/^Account made, as the owner, for jon@example\.com: \S{16}\nSign in, and change it by running this again whenever you like\.\n$/', $out);
        $this->assertFileDoesNotExist("{$this->root}/runlight-data/setup.txt", 'no setup link is made for a server that has an account');

        $server = (new Config($this->root))->standalone([], false);
        $user = $server->accounts->byEmail('jon@example.com');
        $server->runlight->store->db->run('UPDATE rl_users SET totp_secret = ? WHERE id = ?', ['sealed', $user['id']]);
        $this->assertTrue($server->accounts->byEmail('jon@example.com')['twoFactor']);

        [$code, $out] = $this->cli('password', 'jon@example.com');
        $this->assertSame(0, $code);
        preg_match('/: (\S+)\n/', $out, $found);
        $this->assertStringStartsWith('New password for jon@example.com: ', $out);
        $this->assertStringContainsString("Two-factor sign-in is now off for this account; turn it on again under Account.\n", $out);
        $this->assertFalse($server->accounts->byEmail('jon@example.com')['twoFactor']);
        $this->assertNotNull($server->accounts->signIn('jon@example.com', $found[1]), 'the printed password signs in');

        [$code, $out] = $this->cli('setup');
        $this->assertSame("Runlight already has an account. To get into one, run vendor/bin/runlight password <email>.\n", $out);

        [$code, , $err] = $this->cli('password');
        $this->assertSame(1, $code);
        $this->assertStringContainsString('name the account', $err);
    }

    public function testMigrateCronAndUnknownCommands(): void
    {
        $this->configure(['RUNLIGHT_GEO' => 'off']);
        [$code, $out] = $this->cli('migrate');
        $this->assertSame(0, $code);
        $this->assertSame("Runlight's tables are up to date in {$this->root}/runlight-data/runlight.db.\n", $out);
        $this->assertFileExists("{$this->root}/runlight-data/runlight.db");

        // A setup link written before the first account goes at the next check.
        (new Config($this->root))->setupCode();
        $this->cli('password', 'jon@example.com');
        [$code, $out, $err] = $this->cli('cron');
        $this->assertSame([0, '', ''], [$code, $out, $err], 'cron is quiet when all is well');
        $this->assertFileDoesNotExist("{$this->root}/runlight-data/setup.txt");

        [$code, , $err] = $this->cli('nonsense');
        $this->assertSame(1, $code);
        $this->assertStringContainsString('unknown command "nonsense"', $err);

        [$code, , $err] = $this->cli('cron', '--config', "{$this->root}/missing.php");
        $this->assertSame(1, $code);
        $this->assertStringContainsString('there is no config file at', $err);
    }

    public function testASqliteFileGetsItsFolder(): void
    {
        \Runlight\Store\Stores::sqlite("{$this->root}/data/deeper/runlight.db")->migrate();
        $this->assertFileExists("{$this->root}/data/deeper/runlight.db");
    }

    public function testDbIpDownloadsThisMonthOrLastAndKeepsOnlyTheNewest(): void
    {
        $db = base64_decode(Fixture::load('geo')['databases'][0]['base64']);
        $dir = "{$this->root}/geo";
        $asked = [];
        $logged = [];
        $published = ['2026-09'];
        $download = static function (string $url, string $file) use (&$asked, &$published, $db): bool {
            $asked[] = $url;
            preg_match('/lite-(\d{4}-\d{2})\.mmdb\.gz$/', $url, $m);
            if (!in_array($m[1], $published, true)) {
                return false;
            }
            file_put_contents($file, gzencode($db));
            return true;
        };
        $geo = new DbIp($dir, 'city', $download, static function (string $line) use (&$logged): void {
            $logged[] = $line;
        });
        $this->assertNull($geo->lookup(), 'nothing to look up before the first download');

        $october = 1_791_374_400_000; // 2026-10-07
        $geo->refresh($october);
        $this->assertSame(['https://download.db-ip.com/free/dbip-city-lite-2026-10.mmdb.gz', 'https://download.db-ip.com/free/dbip-city-lite-2026-09.mmdb.gz'], $asked, "a month's file appears a day or so in, so last month's stands in");
        $this->assertSame(['Runlight: location data from DB-IP (2026-09) is ready.'], $logged);
        $this->assertSame("$dir/dbip-city-lite-2026-09.mmdb", $geo->newest());
        $this->assertNotNull($geo->lookup());

        $published[] = '2026-10';
        $asked = [];
        $geo->refresh($october);
        $this->assertSame(['https://download.db-ip.com/free/dbip-city-lite-2026-10.mmdb.gz'], $asked);
        $this->assertSame(["$dir/dbip-city-lite-2026-10.mmdb"], glob("$dir/*"), 'older releases go');
        $asked = [];
        $geo->refresh($october);
        $this->assertSame([], $asked, 'once this month is there, nothing is fetched');

        // January's fallback is December of the year before, and a broken file is never kept.
        $broken = new DbIp($dir, 'country', static fn (string $url, string $file): bool => (bool) file_put_contents($file, gzencode('not a database')), static function (string $line) use (&$logged): void {
            $logged[] = $line;
        });
        $broken->refresh(1_798_761_600_000 + 86_400_000); // 2027-01-02
        $this->assertStringContainsString('dbip-country-lite-2026-12.mmdb.gz', end($logged));
        $this->assertNull($broken->newest());
    }
}
