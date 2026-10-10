<?php

declare(strict_types=1);

namespace Runlight\Craft\models;

use Craft;
use craft\base\Model;
use craft\helpers\App;

/**
 * Where the site's Runlight is, and what it sends. Every string may name an
 * environment variable ("$RUNLIGHT_OBSERVE_KEY"), so the keys need not be in
 * project config; config/runlight.php wins over the form, as every plugin's
 * config file does.
 */
final class Settings extends Model
{
    /** The address Runlight answers at, such as https://example.com/runlight in an app or https://stats.example.com for the standalone server. */
    public string $address = '';

    /** Only needed when that Runlight counts several sites and cannot tell this one by hostname. */
    public string $site = '';

    /** With the Runlight's RUNLIGHT_OBSERVE_KEY, AI agents reading pages are reported. */
    public string $observeKey = '';

    /** With a key from the Runlight's Settings, Install, Key for the dashboard in your CMS, the Control Panel shows the site's numbers. */
    public string $dashboardKey = '';

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

    /** The site id with any environment variable read. */
    public function getSite(): string
    {
        return trim((string) App::parseEnv($this->site));
    }

    public function getObserveKey(): string
    {
        return trim((string) App::parseEnv($this->observeKey));
    }

    public function getDashboardKey(): string
    {
        return trim((string) App::parseEnv($this->dashboardKey));
    }

    /**
     * Clears each key that was left as it was when the address now leads somewhere else, so a key
     * meant for one Runlight is never sent to another, such as one at a mistyped address.
     *
     * @param array<string,mixed> $before The settings as they were saved before.
     */
    public function forgetKeysIfMoved(array $before): void
    {
        $previous = new self();
        $previous->address = is_string($before['address'] ?? null) ? $before['address'] : '';
        if ($previous->getAddress() === '' || $previous->getAddress() === $this->getAddress()) {
            return;
        }
        if ($this->observeKey === ($before['observeKey'] ?? null)) {
            $this->observeKey = '';
        }
        if ($this->dashboardKey === ($before['dashboardKey'] ?? null)) {
            $this->dashboardKey = '';
        }
    }

    protected function defineRules(): array
    {
        return [
            [['address', 'site', 'observeKey', 'dashboardKey'], 'string'],
            [['address'], 'validateAddress'],
            [['site'], 'validateSite'],
            [['skipAdmins', 'outbound', 'downloads'], 'boolean'],
        ];
    }

    /** The address, once any environment variable is read, must be a web address: it is put in links and fetched. */
    public function validateAddress(string $attribute): void
    {
        $address = $this->getAddress();
        if ($address === '') {
            return;
        }
        $parts = parse_url($address);
        $scheme = is_array($parts) ? strtolower((string) ($parts['scheme'] ?? '')) : '';
        if (!in_array($scheme, ['http', 'https'], true) || empty($parts['host'])) {
            $this->addError($attribute, Craft::t('runlight', 'Enter a web address starting with https://, such as https://stats.example.com.'));
        }
    }

    public function validateSite(string $attribute): void
    {
        if (!preg_match('/^[a-z0-9._-]*$/i', $this->getSite())) {
            $this->addError($attribute, Craft::t('runlight', 'A site id has only letters, numbers, dots, dashes, and underscores.'));
        }
    }
}
