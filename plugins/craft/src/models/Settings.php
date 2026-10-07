<?php

declare(strict_types=1);

namespace Runlight\Craft\models;

use craft\base\Model;
use craft\helpers\App;

/**
 * Where the site's Runlight is, and what it sends. Every string may name an
 * environment variable ("$RUNLIGHT_OBSERVE_KEY"), so the key need not be in
 * project config; config/runlight.php wins over the form, as every plugin's
 * config file does.
 */
final class Settings extends Model
{
    /** Where Runlight is mounted, such as https://stats.example.com/runlight. */
    public string $address = '';

    /** Only needed when that Runlight counts several sites and cannot tell this one by hostname. */
    public string $site = '';

    /** With the Runlight's RUNLIGHT_OBSERVE_KEY, AI agents reading pages are reported. */
    public string $observeKey = '';

    public bool $skipAdmins = true;
    public bool $outbound = true;
    public bool $downloads = true;

    /** The address with any environment variable read, tidied: no trailing slash, and the script's own address works too. */
    public function getAddress(): string
    {
        $value = trim((string) App::parseEnv($this->address));
        $value = (string) preg_replace('#/s\.js$#', '', $value);
        return rtrim($value, '/');
    }

    public function getObserveKey(): string
    {
        return trim((string) App::parseEnv($this->observeKey));
    }

    protected function defineRules(): array
    {
        return [
            [['address', 'site', 'observeKey'], 'string'],
            [['site'], 'match', 'pattern' => '/^[a-z0-9._-]*$/i'],
            [['skipAdmins', 'outbound', 'downloads'], 'boolean'],
        ];
    }
}
