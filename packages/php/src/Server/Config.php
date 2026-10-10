<?php

declare(strict_types=1);

namespace Runlight\Server;

use Runlight\Accounts\Web;
use Runlight\Env;
use Runlight\Geo;
use Runlight\Store\SqlStore;
use Runlight\Store\Stores;

/**
 * The standalone server's settings, as the drop-in (standalone/index.php) and the command line (bin/runlight)
 * both read them: environment variables first, then a config.php in the project folder (the one holding
 * vendor/) that returns the same names as an array.
 *
 *   DATA_DIR              the SQLite file, the secret, the setup code, and location data (./runlight-data)
 *   DATABASE_URL          a postgres://, mysql://, or mariadb:// URL, to use that database instead of SQLite
 *   RUNLIGHT_SECRET       signs sessions and encrypts saved keys (made and kept in DATA_DIR if unset)
 *   RUNLIGHT_TOKEN        also accepted as a bearer token on the API, and makes the first account
 *   RUNLIGHT_URL          the dashboard's public address, which can never become a link domain
 *   TRUST_PROXY           "false" when no proxy sits in front, so forwarded addresses are ignored
 *   RUNLIGHT_GEO          city (the default), country, off, or the path to an MMDB file
 *   CRON_SECRET           lets a scheduler run the check over HTTP, at POST /api/check
 *   RUNLIGHT_OBSERVE_KEY  one key for every site's AI agent reports
 *
 * Relative paths are read from the project folder.
 */
final class Config
{
    /** @var array<string, mixed> */
    private array $file = [];
    private ?string $secret = null;
    private ?SqlStore $store = null;

    /**
     * @param string $root the project folder, which holds vendor/ and config.php
     * @param string|null $file a config.php elsewhere; RUNLIGHT_CONFIG names one too
     */
    public function __construct(public readonly string $root, ?string $file = null)
    {
        $file ??= Env::get('RUNLIGHT_CONFIG');
        $file = $file !== null ? $this->path($file) : "$root/config.php";
        if (is_file($file)) {
            $values = (static fn (string $path): mixed => require $path)($file);
            if (!is_array($values)) {
                throw new \RuntimeException("Runlight: $file must return an array of settings, such as return ['RUNLIGHT_URL' => 'https://stats.example.com'];");
            }
            $this->file = $values;
        } elseif ($file !== "$root/config.php") {
            throw new \RuntimeException("Runlight: there is no config file at $file");
        }
    }

    /** A setting: the environment's, else config.php's, trimmed, with nothing for an empty one. */
    public function get(string $name): ?string
    {
        $value = Env::get($name);
        if ($value !== null) {
            return $value;
        }
        $given = $this->file[$name] ?? null;
        if (is_bool($given)) {
            return $given ? 'true' : 'false';
        }
        if (!is_scalar($given)) {
            return null;
        }
        $given = trim((string) $given);
        return $given === '' ? null : $given;
    }

    /** A path from a setting, read from the project folder when it is relative. */
    private function path(string $value): string
    {
        return preg_match('#^(/|\\\\|[A-Za-z]:[\\\\/])#', $value) ? $value : "{$this->root}/$value";
    }

    /**
     * The data folder, made on first use and readable only by this user. An .htaccess in it turns Apache away
     * from it even without mod_rewrite, for when the drop-in's folder is also the project folder.
     */
    public function dataDir(): string
    {
        $dir = $this->dataPath();
        if (!is_dir($dir) && !@mkdir($dir, 0700, true) && !is_dir($dir)) {
            throw new \RuntimeException("Runlight: could not make the data folder $dir. Make it, writable by the web server, or set DATA_DIR.");
        }
        if (!is_file("$dir/.htaccess")) {
            @file_put_contents("$dir/.htaccess", "Require all denied\n");
        }
        return $dir;
    }

    private function dataPath(): string
    {
        return $this->path($this->get('DATA_DIR') ?? 'runlight-data');
    }

    /** Where the data lives, for messages. */
    public function where(): string
    {
        $url = $this->get('DATABASE_URL') ?? '';
        return match (true) {
            (bool) preg_match('#^postgres(ql)?://#i', $url) => 'Postgres',
            (bool) preg_match('#^mysql://#i', $url) => 'MySQL',
            (bool) preg_match('#^mariadb://#i', $url) => 'MariaDB',
            $url !== '' => $url,
            default => $this->dataPath() . '/runlight.db',
        };
    }

    public function store(): SqlStore
    {
        if ($this->store === null) {
            $url = $this->get('DATABASE_URL');
            $this->store = $url !== null ? Stores::url($url) : Stores::sqlite($this->dataDir() . '/runlight.db');
        }
        return $this->store;
    }

    /** RUNLIGHT_SECRET, or one made on first use and kept beside the data, readable only by this user. */
    public function secret(): string
    {
        if ($this->secret !== null) {
            return $this->secret;
        }
        $given = $this->get('RUNLIGHT_SECRET');
        if ($given !== null) {
            return $this->secret = $given;
        }
        $file = $this->dataDir() . '/secret';
        $saved = is_file($file) ? trim((string) file_get_contents($file)) : '';
        if ($saved !== '') {
            return $this->secret = $saved;
        }
        $made = bin2hex(random_bytes(32));
        // Made once: whoever writes the file first wins, and everyone else reads theirs.
        $handle = @fopen($file, 'x');
        if ($handle === false) {
            usleep(50_000);
            $saved = is_file($file) ? trim((string) file_get_contents($file)) : '';
            if ($saved === '') {
                throw new \RuntimeException("Runlight: could not write $file. Make the data folder writable, or set RUNLIGHT_SECRET.");
            }
            return $this->secret = $saved;
        }
        // Readable by this user alone before the secret is in it.
        @chmod($file, 0600);
        fwrite($handle, "$made\n");
        fclose($handle);
        return $this->secret = $made;
    }

    /** The dashboard's public address, such as https://stats.example.com, or null. */
    public function url(): ?string
    {
        $url = $this->get('RUNLIGHT_URL');
        if ($url !== null && !preg_match('#^https?://[^/?\#]+/?$#D', $url)) {
            throw new \RuntimeException("Runlight: set RUNLIGHT_URL to the dashboard's address only, such as https://stats.example.com");
        }
        return $url;
    }

    /** "false" with nothing in front, or the one header your proxy sets, such as cf-connecting-ip behind Cloudflare. */
    public function trustProxy(): bool|string
    {
        $value = strtolower($this->get('TRUST_PROXY') ?? '');
        return $value === 'false' ? false : (in_array($value, ['x-forwarded-for', 'x-real-ip', 'cf-connecting-ip'], true) ? $value : true);
    }

    /** DB-IP's monthly download, for RUNLIGHT_GEO city (the default) or country, or null. */
    public function dbIp(): ?DbIp
    {
        $mode = strtolower($this->get('RUNLIGHT_GEO') ?? 'city');
        return $mode === 'city' || $mode === 'country' ? new DbIp($this->dataPath() . '/geo', $mode) : null;
    }

    /** @return (callable(string): ?array)|null */
    public function geo(): ?callable
    {
        $setting = $this->get('RUNLIGHT_GEO') ?? 'city';
        $dbIp = $this->dbIp();
        if ($dbIp !== null) {
            return $dbIp->lookup();
        }
        if (strtolower($setting) === 'off') {
            return null;
        }
        $file = $this->path($setting);
        $lookup = null;
        return static function (string $ip) use ($file, &$lookup): ?array {
            $lookup ??= Geo::fileLookup($file);
            return $lookup($ip);
        };
    }

    /** The file that holds the setup link while there is no account. */
    public function setupFile(): string
    {
        return $this->dataDir() . '/setup.txt';
    }

    /**
     * The one-time code that unlocks /setup, made the first time it is asked for and written to setup.txt in the
     * data folder with the link that carries it. With RUNLIGHT_TOKEN set there is none: setup asks for the token.
     */
    public function setupCode(): ?string
    {
        if ($this->get('RUNLIGHT_TOKEN') !== null) {
            return null;
        }
        $file = $this->setupFile();
        $text = is_file($file) ? (string) file_get_contents($file) : '';
        if (preg_match('#/setup\?code=([A-Za-z0-9_-]+)#', $text, $found)) {
            return $found[1];
        }
        $code = Web::setupCode();
        $link = ($this->url() !== null ? rtrim($this->url(), '/') : 'https://your-runlight-address') . "/setup?code=$code";
        $handle = @fopen($file, 'x');
        if ($handle === false) {
            // Someone else wrote it first.
            usleep(50_000);
            $text = is_file($file) ? (string) file_get_contents($file) : '';
            if (preg_match('#/setup\?code=([A-Za-z0-9_-]+)#', $text, $found)) {
                return $found[1];
            }
            throw new \RuntimeException("Runlight: could not write $file. Make the data folder writable, or set RUNLIGHT_TOKEN.");
        }
        fwrite($handle, "Open this link to create the first Runlight account. It works only while Runlight has no account.\n$link\n");
        fclose($handle);
        @chmod($file, 0600);
        return $code;
    }

    /**
     * The standalone server these settings describe.
     *
     * @param array<string, mixed> $options more of Standalone's options, such as now or fetcher, for tests
     * @param bool $setup whether to make the setup code when there is none, as the web pages need
     */
    public function standalone(array $options = [], bool $setup = true): Standalone
    {
        $dbIp = $this->dbIp();
        $geo = $this->geo();
        $code = $setup ? $this->setupCode() : null;
        $settings = [
            'store' => $this->store(),
            'secret' => $this->secret(),
            'token' => $this->get('RUNLIGHT_TOKEN'),
            'url' => $this->url(),
            'trustProxy' => $this->trustProxy(),
            'geoCredit' => $dbIp !== null,
            'cronSecret' => $this->get('CRON_SECRET'),
            'observeKey' => $this->get('RUNLIGHT_OBSERVE_KEY'),
        ];
        if ($geo !== null) {
            $settings['geo'] = $geo;
        }
        if ($code !== null) {
            $settings['setupCode'] = $code;
            $settings['setupWhere'] = "in the file setup.txt in Runlight's data folder (<code>vendor/bin/runlight setup</code> prints it too)";
        }
        return new Standalone([...$settings, ...$options]);
    }
}
