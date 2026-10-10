<?php

declare(strict_types=1);

namespace Runlight\Craft\controllers;

use Craft;
use craft\web\Controller;
use Runlight\Craft\Plugin;
use yii\web\Response;

/**
 * The Control Panel's Runlight item: this site's dashboard, framed from your
 * Runlight with a ticket the plugin asks for on every visit to the page.
 */
final class DashboardController extends Controller
{
    public function actionIndex(): Response
    {
        $this->requirePermission('accessPlugin-runlight');
        $settings = Plugin::getInstance()->getSettings();
        $address = $settings->getAddress();
        $key = $settings->getDashboardKey();
        $ticket = $address !== '' && $key !== '' ? self::ticket($address, $key) : null;
        $site = is_array($ticket) && $ticket['site'] !== '' ? $ticket['site'] : $settings->site;
        return $this->renderTemplate('runlight/_dashboard.twig', [
            'address' => $address,
            'hasKey' => $key !== '',
            'frame' => is_array($ticket) ? $ticket['url'] : null,
            'error' => is_string($ticket) ? $ticket : null,
            'origin' => self::originOf($address),
            'full' => $address !== '' ? $address . '/' . ($site !== '' ? '?site=' . rawurlencode($site) : '') : '',
            'settingsUrl' => 'settings/plugins/runlight',
        ]);
    }

    /** The scheme, host, and port of an address, as a browser writes its origin. */
    private static function originOf(string $address): string
    {
        $parts = parse_url($address);
        if (!is_array($parts) || empty($parts['scheme']) || empty($parts['host'])) {
            return '';
        }
        $scheme = strtolower($parts['scheme']);
        $port = (int) ($parts['port'] ?? 0);
        $default = ($scheme === 'https' && $port === 443) || ($scheme === 'http' && $port === 80);
        return $scheme . '://' . strtolower($parts['host']) . ($port && !$default ? ':' . $port : '');
    }

    /**
     * Asks the Runlight for a ticket that opens the dashboard once, framed by
     * this Control Panel. Each ticket works for a few minutes and only once, so
     * one is asked for on every visit to the page and never kept.
     *
     * @return array{url: string, site: string}|string The page to frame and its site, or why there is none.
     */
    private static function ticket(string $address, string $key): array|string
    {
        try {
            $response = Craft::createGuzzleClient(['timeout' => 5, 'http_errors' => false, 'allow_redirects' => false])->post($address . '/api/embed', [
                'headers' => ['Authorization' => 'Bearer ' . $key],
                'json' => ['origin' => self::originOf(Craft::$app->getRequest()->getHostInfo())],
            ]);
        } catch (\Throwable $e) {
            return 'Could not reach your Runlight: ' . $e->getMessage();
        }
        $body = json_decode((string) $response->getBody(), true);
        $code = $response->getStatusCode();
        if ($code !== 201 || !is_array($body) || !is_string($body['ticket'] ?? null)) {
            if ($code === 401) {
                return 'Your Runlight does not know this dashboard key. Make a new one in Runlight’s Settings, Install, and enter it in the settings.';
            }
            $reason = is_array($body) && is_string($body['error'] ?? null) ? $body['error'] : "It answered $code.";
            return 'Your Runlight would not open the dashboard here: ' . $reason;
        }
        return [
            'url' => $address . '/embed?ticket=' . rawurlencode($body['ticket']) . '&theme=light',
            'site' => is_string($body['site'] ?? null) ? $body['site'] : '',
        ];
    }
}
