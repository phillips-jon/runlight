<?php

declare(strict_types=1);

namespace Runlight\Tests\Routes;

use Runlight\Env;
use Runlight\Http\Fetcher;
use Runlight\Http\Request;
use Runlight\Http\Response;
use Runlight\Json;
use Runlight\Mail\MailError;
use Runlight\Mail\Secret;
use Runlight\Mail\Transports;
use Runlight\Routes;
use Runlight\Sources;
use Runlight\Store\SqlStore;
use Runlight\Store\Stores;
use Runlight\Tests\Conformance\Target;

/**
 * A small stand-in for Runlight\Runlight, with the members the routes call that need only the store: sites set in
 * code, settings, mail and assistant settings, and nothing that counts a visit. It lets the routes, accounts, and
 * OAuth be tested, and conformance scenarios that only use those be replayed, before the core class exists.
 * Anything it does not do throws, so a scenario that needs it fails loudly rather than passing by accident.
 */
final class StandIn implements Target
{
    public readonly SqlStore $store;
    public readonly bool $managedSites;
    public readonly ?string $secret;
    public readonly string $linkPath;
    public readonly Fetcher $fetcher;
    public readonly mixed $links;
    /** @var list<string> */
    public array $routeBases = [];
    /** @var \Closure(): int */
    private \Closure $clock;
    /** @var list<array<string, mixed>> */
    private array $configured;
    private bool $ready = false;
    private ?Routes $routes = null;

    /** @param array<string, mixed> $options as new Runlight([...]) takes them */
    public function __construct(array $options)
    {
        $this->store = $options['store'] ?? Stores::sqlite(':memory:');
        if (!empty($options['managedSites'])) {
            throw new \LogicException('The stand-in has no managed sites');
        }
        $this->managedSites = false;
        $sites = $options['sites'] ?? [$options['site'] ?? []];
        $this->configured = array_map(static fn (array $s, int $i) => [
            'id' => $s['id'] ?? ($i === 0 ? 'default' : ''),
            'name' => $s['name'] ?? ($s['hostnames'][0] ?? 'My site'),
            'hostnames' => array_map(Sources::stripWww(...), $s['hostnames'] ?? []),
            'timezone' => $s['timezone'] ?? 'UTC',
        ], $sites, array_keys($sites));
        $this->secret = $options['secret'] ?? Env::get('RUNLIGHT_SECRET') ?? Env::get('RUNLIGHT_TOKEN');
        $this->clock = \Closure::fromCallable($options['now'] ?? static fn (): int => (int) floor(microtime(true) * 1000));
        $this->fetcher = $options['fetcher'] ?? new \Runlight\Http\CurlFetcher();
        $this->linkPath = '/go';
        $this->links = null;
    }

    public function now(): int
    {
        return ($this->clock)();
    }

    public function init(): void
    {
        if ($this->ready) {
            return;
        }
        $this->store->migrate();
        foreach ($this->configured as $site) {
            $this->store->upsertSite($site, $this->now());
        }
        $this->ready = true;
    }

    /** @param array<string, mixed> $options */
    public function routes(array $options = []): Routes
    {
        return new Routes($this, $options);
    }

    /** @return list<array<string, mixed>> */
    public function sites(): array
    {
        $overrides = $this->ready ? $this->store->siteOverrides() : [];
        return array_map(static fn (array $s) => array_merge($s, $overrides[$s['id']] ?? []), $this->configured);
    }

    public function site(?string $id): ?array
    {
        $sites = $this->sites();
        if ($id === null || $id === '') {
            return $sites[0] ?? null;
        }
        foreach ($sites as $site) {
            if ($site['id'] === $id) {
                return $site;
            }
        }
        return null;
    }

    public function siteFor(string $hostname, ?string $id = null): ?array
    {
        $host = Sources::stripWww($hostname);
        foreach ($this->sites() as $site) {
            if (($id === null || $site['id'] === $id) && ($site['hostnames'] === [] || in_array($host, $site['hostnames'], true))) {
                return $site;
            }
        }
        return null;
    }

    public function remote(string $id): ?array
    {
        return null;
    }

    public function retention(string $site): ?int
    {
        $value = (int) $this->store->setting("retention:$site");
        return in_array($value, [6, 12, 24, 36, 60], true) ? $value : null;
    }

    public function forgetLinkDomains(): void
    {
    }

    public function clientIp(Request $request, array $context = []): string
    {
        $forwarded = $request->headers->get('x-forwarded-for');
        if ($forwarded !== null) {
            $parts = array_values(array_filter(array_map('trim', explode(',', $forwarded))));
            if ($parts) {
                return $parts[count($parts) - 1];
            }
        }
        return $request->headers->get('x-real-ip') ?? $request->headers->get('cf-connecting-ip') ?? ($context['ip'] ?? $request->remoteAddress);
    }

    public function mailSettings(): ?array
    {
        $this->init();
        $sealed = $this->store->setting('mail');
        $opened = $sealed ? Secret::unseal($sealed, $this->secret) : null;
        return $opened ? Json::decode($opened, true) + ['source' => 'dashboard'] : null;
    }

    public function sendMail(array $message): void
    {
        $settings = $this->mailSettings();
        if ($settings === null) {
            throw new MailError('Set up a mail service first', 'mail_unset', []);
        }
        Transports::send($settings, $message + ['from' => $settings['from'], 'fromName' => $settings['fromName'] ?? ''], $this->fetcher, $this->now());
    }

    /** As runlight.ts saves the mail service, without mail set in code. */
    public function saveMailSettings(?array $input): void
    {
        if ($input === null) {
            $this->store->setSetting('mail', null);
            return;
        }
        $before = $this->mailSettings();
        $service = null;
        foreach (Transports::SERVICES as $s) {
            if ($s['id'] === ($input['service'] ?? null)) {
                $service = $s;
            }
        }
        if ($service === null) {
            throw new MailError('Pick a mail service', 'mail_service', []);
        }
        $settings = ['service' => $service['id']];
        foreach ($service['fields'] as $f) {
            if (empty($f['secret'])) {
                $settings[$f['name']] = trim((string) ($input[$f['name']] ?? ''));
            }
        }
        $same = ($before['service'] ?? null) === $service['id'];
        foreach ($service['fields'] as $f) {
            $same = $same && (!empty($f['secret']) || (string) ($before[$f['name']] ?? '') === $settings[$f['name']]);
        }
        foreach ($service['fields'] as $f) {
            if (!empty($f['secret'])) {
                $given = trim((string) ($input[$f['name']] ?? ''));
                $settings[$f['name']] = $given === '' && $same ? (string) ($before[$f['name']] ?? '') : $given;
            }
        }
        $from = trim((string) ($input['from'] ?? ''));
        if (!preg_match('/^[^\s@<>"]+@[^\s@<>"]+\.[^\s@<>"]+\z/', $from)) {
            throw new MailError('Enter the address reports come from, like reports@example.com', 'mail_from', []);
        }
        $fromName = mb_substr(trim((string) ($input['fromName'] ?? '')), 0, 80);
        $config = $settings + ['from' => $from] + ($fromName !== '' ? ['fromName' => $fromName] : []);
        Transports::checkConfig($config);
        $this->store->setSetting('mail', Secret::seal(Json::encode($config), $this->secret));
    }

    public function assistantSettings(): ?array
    {
        $stored = $this->store->setting('assistant');
        $opened = $stored ? Secret::unseal($stored, $this->secret) : null;
        return $opened ? Json::decode($opened, true) : null;
    }

    /** As runlight.ts saves the assistant's settings. */
    public function saveAssistantSettings(?array $input): void
    {
        if (!$input) {
            $this->store->setSetting('assistant', null);
            return;
        }
        $provider = null;
        foreach (\Runlight\Assistant::PROVIDERS as $p) {
            if ($p['id'] === ($input['provider'] ?? null)) {
                $provider = $p;
            }
        }
        if ($provider === null) {
            throw new SettingsError('Choose a provider', 'assistant_provider');
        }
        $baseUrl = (string) preg_replace('#/+\z#', '', trim((string) ($input['baseUrl'] ?? '')));
        if ($baseUrl !== '') {
            $parsed = \Runlight\Http\Url::parse($baseUrl);
            if ($parsed === null || ($parsed->protocol !== 'https:' && $parsed->protocol !== 'http:')) {
                throw new SettingsError("Enter the service's address, starting with https://", 'assistant_address_bad');
            }
        }
        if ($baseUrl === '' && $provider['baseUrl'] === '') {
            throw new SettingsError("Enter the service's address", 'assistant_address');
        }
        $model = mb_substr(trim((string) ($input['model'] ?? '')), 0, 200);
        if ($model === '' && $provider['model'] === '') {
            throw new SettingsError('Enter the model to use', 'assistant_model');
        }
        $before = $this->assistantSettings();
        $key = trim((string) ($input['key'] ?? ''));
        $at = static fn (string $b): string => $b !== '' ? $b : $provider['baseUrl'];
        if ($key === '' && ($before['provider'] ?? null) === $provider['id'] && $at((string) $before['baseUrl']) === $at($baseUrl)) {
            $key = $before['key'];
        }
        if ($key === '' && $provider['key'] === 'yes') {
            throw new SettingsError("Enter your {$provider['name']} key", 'assistant_key', ['provider' => $provider['name']]);
        }
        $settings = ['provider' => $provider['id'], 'model' => $model, 'baseUrl' => $baseUrl, 'key' => $key];
        $this->store->setSetting('assistant', Secret::seal(Json::encode($settings), $this->secret));
    }

    public function check(): array
    {
        return ['ok' => true, 'reports' => ['sent' => 0, 'failed' => 0]];
    }

    public function __call(string $name, array $arguments): never
    {
        throw new \LogicException("The stand-in Runlight has no $name()");
    }

    // As a conformance target.

    /** @param array<string, mixed> $routes */
    public static function target(array $runlight, array $routes): self
    {
        $standIn = new self($runlight);
        $standIn->routes = $standIn->routes($routes);
        return $standIn;
    }

    public function handle(Request $request): Response
    {
        return $this->routes->handle($request);
    }

    public function links(Request $request): Response
    {
        throw new \LogicException('The stand-in has no links');
    }

    public function linkDomain(Request $request): ?Response
    {
        return null;
    }

    public function idle(): void
    {
    }
}
