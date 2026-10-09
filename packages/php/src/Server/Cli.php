<?php

declare(strict_types=1);

namespace Runlight\Server;

use Runlight\Accounts\Crypto;
use Runlight\Version;

/**
 * The commands behind vendor/bin/runlight, the PHP counterpart of `npx runlight.sh`'s: the scheduled check for a
 * crontab, a new password for someone locked out, the tables, and the setup link.
 */
final class Cli
{
    public const HELP = <<<'TEXT'
        Runlight %s, privacy friendly web analytics for any number of sites.

        Usage:
          vendor/bin/runlight cron              Run the scheduled check, and fetch this month's location data
          vendor/bin/runlight password <email>  Make an account, or give one a new password
          vendor/bin/runlight setup             Print the link that makes the first account
          vendor/bin/runlight migrate           Create or update Runlight's tables
          vendor/bin/runlight --version         Print the version

        Add --config <file> to read settings from a config.php other than the
        project folder's. Settings are the standalone drop-in's, read from the
        environment first and then config.php: DATA_DIR, DATABASE_URL,
        RUNLIGHT_SECRET, RUNLIGHT_TOKEN, RUNLIGHT_URL, TRUST_PROXY, RUNLIGHT_GEO,
        CRON_SECRET, and RUNLIGHT_OBSERVE_KEY.

        Run the check every five minutes from cron:
          */5 * * * * cd /path/to/project && vendor/bin/runlight cron

        Docs: https://runlight.sh/docs/php/

        TEXT;

    /**
     * Runs one command and returns the exit code.
     *
     * @param list<string> $args the arguments after the program's name
     * @param string $root the project folder, which holds vendor/
     * @param resource|null $out
     * @param resource|null $err
     */
    public static function run(array $args, string $root, $out = null, $err = null, ?callable $now = null): int
    {
        $out ??= STDOUT;
        $err ??= STDERR;
        $now ??= static fn (): int => (int) floor(microtime(true) * 1000);
        $file = null;
        $at = array_search('--config', $args, true);
        if ($at !== false) {
            $file = $args[$at + 1] ?? null;
            if ($file === null) {
                fwrite($err, "Runlight: name the file after --config.\n");
                return 1;
            }
            array_splice($args, $at, 2);
            $file = realpath($file) ?: $file;
        }
        $command = $args[0] ?? 'help';
        try {
            switch ($command) {
                case 'help':
                case '--help':
                case '-h':
                    fwrite($out, sprintf(self::HELP, Version::version()));
                    return 0;
                case '--version':
                case '-v':
                    fwrite($out, Version::version() . "\n");
                    return 0;
                case 'cron':
                    return self::cron(new Config($root, $file), $err, $now);
                case 'password':
                    return self::password(new Config($root, $file), $args[1] ?? null, $out, $err, $now);
                case 'setup':
                    return self::setup(new Config($root, $file), $out);
                case 'migrate':
                    $config = new Config($root, $file);
                    $config->standalone(['now' => $now], false)->runlight->init();
                    fwrite($out, "Runlight's tables are up to date in {$config->where()}.\n");
                    return 0;
                default:
                    fwrite($err, "Runlight: unknown command \"$command\". Run vendor/bin/runlight --help.\n");
                    return 1;
            }
        } catch (\Throwable $error) {
            fwrite($err, 'Runlight: ' . $error->getMessage() . "\n");
            return 1;
        }
    }

    /**
     * The scheduled check (salts, email reports, retention, and rollups), then this month's location data. Quiet
     * when all is well, as cron likes. A run that starts while another is still going leaves it to that one.
     *
     * @param resource $err
     */
    private static function cron(Config $config, $err, callable $now): int
    {
        $lock = @fopen($config->dataDir() . '/cron.lock', 'c');
        if ($lock !== false && !flock($lock, LOCK_EX | LOCK_NB)) {
            return 0;
        }
        try {
            $server = $config->standalone(['now' => $now], false);
            $result = $server->check();
            // The setup link is no use once someone has an account.
            if (is_file($config->setupFile()) && $server->accounts->count() > 0) {
                @unlink($config->setupFile());
            }
            $failed = $result['reports']['failed'];
            if ($failed > 0) {
                fwrite($err, "Runlight: $failed email " . ($failed === 1 ? 'report' : 'reports') . " could not be sent. The dashboard's Settings, Email reports, says why.\n");
            }
            $config->dbIp()?->refresh($now());
            return $failed > 0 ? 1 : 0;
        } finally {
            if ($lock !== false) {
                flock($lock, LOCK_UN);
                fclose($lock);
            }
        }
    }

    /**
     * A new password for someone locked out, which also turns off their two-factor sign-in, since someone at
     * the server is who they say. It makes the account when there is none: the owner on a server with nobody
     * yet, and an admin otherwise.
     *
     * @param resource $out
     * @param resource $err
     */
    private static function password(Config $config, ?string $email, $out, $err, callable $now): int
    {
        if ($email === null || trim($email) === '') {
            fwrite($err, "Runlight: name the account, as in vendor/bin/runlight password you@example.com\n");
            return 1;
        }
        $server = $config->standalone(['now' => $now], false);
        $server->runlight->init();
        $password = Crypto::base64url(random_bytes(12));
        $existed = $server->accounts->byEmail($email) !== null;
        $user = $server->accounts->setPassword($email, $password, $now());
        $reset = (bool) ($user['twoFactor'] ?? false);
        if ($reset) {
            $server->accounts->disableTwoFactor($user['id']);
        }
        $who = mb_strtolower(trim($email));
        fwrite($out, ($existed ? 'New password' : 'Account made, as ' . ($user['role'] === 'owner' ? 'the owner' : 'an admin') . ',') . " for $who: $password\n"
            . ($reset ? "Two-factor sign-in is now off for this account; turn it on again under Account.\n" : '')
            . "Sign in, and change it by running this again whenever you like.\n");
        return 0;
    }

    /** @param resource $out */
    private static function setup(Config $config, $out): int
    {
        $server = $config->standalone([], false);
        $server->runlight->init();
        if ($server->accounts->count() > 0) {
            fwrite($out, "Runlight already has an account. To get into one, run vendor/bin/runlight password <email>.\n");
            return 0;
        }
        if ($config->get('RUNLIGHT_TOKEN') !== null) {
            fwrite($out, "Open /setup at your Runlight's address and enter RUNLIGHT_TOKEN to create the first account.\n");
            return 0;
        }
        $config->setupCode();
        fwrite($out, (string) file_get_contents($config->setupFile()));
        if ($config->url() === null) {
            fwrite($out, "Put your Runlight's own address in place of https://your-runlight-address, or set RUNLIGHT_URL.\n");
        }
        return 0;
    }
}
