<?php

declare(strict_types=1);

namespace Runlight\Craft;

use Craft;
use craft\base\Model;
use craft\base\Plugin as BasePlugin;
use craft\events\RegisterUrlRulesEvent;
use craft\web\UrlManager;
use craft\web\View;
use Runlight\Craft\models\Settings;
use yii\base\Event;
use yii\web\Response;

/**
 * Runlight for Craft CMS: the script on every front-end page, AI agents
 * reported to Runlight after the response has gone, and a Control Panel
 * item that opens the dashboard. The numbers live in your Runlight.
 *
 * @method Settings getSettings()
 */
final class Plugin extends BasePlugin
{
    public string $schemaVersion = '1.0.0';
    public bool $hasCpSettings = true;
    public bool $hasCpSection = true;

    public function init(): void
    {
        parent::init();
        Event::on(UrlManager::class, UrlManager::EVENT_REGISTER_CP_URL_RULES, function (RegisterUrlRulesEvent $event): void {
            $event->rules['runlight'] = 'runlight/dashboard/index';
        });

        $request = Craft::$app->getRequest();
        if ($request->getIsConsoleRequest() || !$request->getIsSiteRequest()) {
            return;
        }
        // The script goes in at the end of the body, which is still before Craft writes the head.
        Event::on(View::class, View::EVENT_END_BODY, function (): void {
            $this->registerScript();
        });
        Event::on(Response::class, Response::EVENT_AFTER_SEND, function (): void {
            $this->observe();
        });
    }

    public function getCpNavItem(): ?array
    {
        $item = parent::getCpNavItem();
        if ($item !== null) {
            $item['label'] = 'Runlight';
        }
        return $item;
    }

    protected function createSettingsModel(): ?Model
    {
        return new Settings();
    }

    protected function settingsHtml(): ?string
    {
        $settings = $this->getSettings();
        return Craft::$app->getView()->renderTemplate('runlight/_settings.twig', [
            'settings' => $settings,
            'status' => $settings->getAddress() !== '' ? self::check($settings->getAddress()) : null,
        ]);
    }

    /** Whether the address answers as a Runlight, and what to say about it. */
    public static function check(string $address): array
    {
        try {
            $response = Craft::createGuzzleClient(['timeout' => 5, 'http_errors' => false])->get($address . '/api');
            $body = json_decode((string) $response->getBody(), true);
            if ($response->getStatusCode() === 200 && is_array($body) && ($body['name'] ?? '') === 'runlight') {
                return ['ok' => true, 'message' => sprintf('Connected to Runlight %s.', (string) ($body['version'] ?? ''))];
            }
            return ['ok' => false, 'message' => 'Something answered, but not Runlight. Check the address ends where Runlight is mounted, such as /runlight.'];
        } catch (\Throwable $e) {
            return ['ok' => false, 'message' => 'Could not reach it: ' . $e->getMessage()];
        }
    }

    private function registerScript(): void
    {
        $settings = $this->getSettings();
        $address = $settings->getAddress();
        if ($address === '') {
            return;
        }
        $user = Craft::$app->getUser();
        if ($settings->skipAdmins && !$user->getIsGuest() && $user->checkPermission('accessCp')) {
            return;
        }
        $options = ['defer' => true, 'position' => View::POS_HEAD];
        if ($settings->site !== '') {
            $options['data-site'] = $settings->site;
        }
        if (!$settings->outbound) {
            $options['data-outbound'] = 'false';
        }
        if (!$settings->downloads) {
            $options['data-downloads'] = 'false';
        }
        if (Craft::$app->getResponse()->getStatusCode() === 404) {
            $options['data-404'] = true;
        }
        Craft::$app->getView()->registerJsFile($address . '/s.js', $options);
    }

    /**
     * Reports a page served to an AI agent. Agents run no JavaScript, so the
     * script never sees them. It runs once the response has been sent, and
     * only for known agents.
     */
    private function observe(): void
    {
        $settings = $this->getSettings();
        $request = Craft::$app->getRequest();
        $agent = (string) $request->getUserAgent();
        $key = $settings->getObserveKey();
        if ($settings->getAddress() === '' || $key === '' || !$request->getIsGet() || !Agents::isAgent($agent)) {
            return;
        }
        try {
            Craft::createGuzzleClient(['timeout' => 3])->post($settings->getAddress() . '/api/observe', [
                'headers' => ['Authorization' => 'Bearer ' . $key],
                'json' => ['url' => $request->getAbsoluteUrl(), 'userAgent' => $agent],
            ]);
        } catch (\Throwable $e) {
            // Analytics must never break the page it watches; note it and move on.
            Craft::warning('Could not report an AI agent fetch: ' . $e->getMessage(), 'runlight');
        }
    }
}
