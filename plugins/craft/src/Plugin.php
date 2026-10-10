<?php

declare(strict_types=1);

namespace Runlight\Craft;

use Craft;
use craft\base\Model;
use craft\base\Plugin as BasePlugin;
use craft\events\RegisterUrlRulesEvent;
use craft\services\ProjectConfig;
use craft\web\UrlManager;
use craft\web\View;
use Runlight\Craft\models\Settings;
use yii\base\Event;
use yii\web\Response;

/**
 * Runlight for Craft CMS: the script on every front-end page, AI agents
 * reported to Runlight after the response has gone, and a Control Panel
 * item that shows the dashboard. The numbers live in your Runlight.
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

        // The request is only looked at once Craft has finished starting up, as Craft asks of plugins.
        Craft::$app->onInit(function (): void {
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
        // The address is checked by the page once it has loaded (DashboardController::actionCheck), so a
        // slow or missing Runlight never holds up the settings page.
        return Craft::$app->getView()->renderTemplate('runlight/_settings.twig', [
            'settings' => $this->getSettings(),
        ]);
    }

    /**
     * A key saved for one Runlight is never sent to another: when the address changes and a key was
     * left as it was, the key is cleared, as the WordPress and Drupal plugins do.
     */
    public function beforeSaveSettings(): bool
    {
        $before = Craft::$app->getProjectConfig()->get(ProjectConfig::PATH_PLUGINS . '.' . $this->handle . '.settings');
        $this->getSettings()->forgetKeysIfMoved(is_array($before) ? $before : []);
        return parent::beforeSaveSettings();
    }

    /** Whether the address answers as a Runlight, and what to say about it. */
    public static function check(string $address): array
    {
        try {
            $response = Craft::createGuzzleClient(['timeout' => 5, 'http_errors' => false])->get($address . '/api');
            $body = json_decode((string) $response->getBody(), true);
            if ($response->getStatusCode() === 200 && is_array($body) && ($body['name'] ?? '') === 'runlight') {
                return ['ok' => true, 'message' => Craft::t('runlight', 'Connected to Runlight {version}.', ['version' => (string) ($body['version'] ?? '')])];
            }
            return ['ok' => false, 'message' => Craft::t('runlight', 'Something answered, but not Runlight. Check that this is the address Runlight answers at, such as https://example.com/runlight for an app with Runlight mounted, or https://stats.example.com for the standalone server.')];
        } catch (\Throwable $e) {
            return ['ok' => false, 'message' => Craft::t('runlight', 'Could not reach it: {error}', ['error' => $e->getMessage()])];
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
            self::keepOutOfCaches();
            return;
        }
        $options = ['defer' => true, 'position' => View::POS_HEAD];
        if ($settings->getSite() !== '') {
            $options['data-site'] = $settings->getSite();
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
     * A page left without the script for a Control Panel user must never be cached and served to
     * everyone else, or their visits would go uncounted. Blitz is told not to cache it, and any other
     * cache in front of Craft is told by the headers.
     */
    private static function keepOutOfCaches(): void
    {
        if (class_exists('putyourlightson\\blitz\\Blitz') && isset(\putyourlightson\blitz\Blitz::$plugin)) {
            \putyourlightson\blitz\Blitz::$plugin->generateCache->options->cachingEnabled = false;
        }
        Craft::$app->getResponse()->setNoCacheHeaders();
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
        // The page has been sent, but under PHP-FPM or LiteSpeed the agent still waits until PHP
        // finishes. Closing the connection first means the report never keeps it waiting.
        if (session_status() === PHP_SESSION_ACTIVE) {
            session_write_close();
        }
        if (function_exists('fastcgi_finish_request')) {
            fastcgi_finish_request();
        } elseif (function_exists('litespeed_finish_request')) {
            litespeed_finish_request();
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
