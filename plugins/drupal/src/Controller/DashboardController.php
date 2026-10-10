<?php

declare(strict_types=1);

namespace Drupal\runlight\Controller;

use Drupal\Core\Controller\ControllerBase;
use Drupal\Core\Url;

/**
 * Reports, Runlight: this site's dashboard, framed from your Runlight with a
 * ticket the module asks for on every visit to the page.
 */
final class DashboardController extends ControllerBase {

  public function open(): array {
    $config = $this->config('runlight.settings');
    $address = (string) $config->get('address');
    $key = (string) $config->get('dashboard_key');
    $settings = Url::fromRoute('runlight.settings')->toString();
    // Each ticket works once, so the page is never cached.
    $build = ['#cache' => ['max-age' => 0]];
    if ($address === '') {
      $build['setup'] = [
        '#markup' => '<p>' . $this->t('Enter your Runlight’s address and a dashboard key on the <a href=":url">settings page</a> to see this site’s numbers here.', [':url' => $settings]) . '</p>',
      ];
      return $build;
    }
    $ticket = $key === '' ? NULL : $this->ticket($address, $key);
    $site = is_array($ticket) && $ticket['site'] !== '' ? $ticket['site'] : (string) $config->get('site');
    $build['open'] = [
      '#type' => 'link',
      '#title' => $this->t('Open in Runlight'),
      '#url' => Url::fromUri($address . '/', $site !== '' ? ['query' => ['site' => $site]] : []),
      '#attributes' => ['class' => ['button', 'button--small'], 'target' => '_blank', 'rel' => 'noopener'],
    ];
    if ($ticket === NULL) {
      $build['setup'] = [
        '#markup' => '<p>' . $this->t('To see this site’s numbers here, make a dashboard key in your Runlight under Settings, Install, Key for the dashboard in your CMS, and enter it on the <a href=":url">settings page</a>.', [':url' => $settings]) . '</p>',
      ];
      return $build;
    }
    if (is_string($ticket)) {
      $build['error'] = [
        '#theme' => 'status_messages',
        '#message_list' => ['error' => [$ticket]],
        '#status_headings' => ['error' => $this->t('Error message')],
      ];
      $build['settings'] = [
        '#markup' => '<p>' . $this->t('<a href=":url">Check the settings</a>.', [':url' => $settings]) . '</p>',
      ];
      return $build;
    }
    $build['frame'] = [
      '#type' => 'html_tag',
      '#tag' => 'iframe',
      '#value' => '',
      '#attributes' => [
        'id' => 'runlight-embed',
        'src' => $ticket['url'],
        'data-runlight-origin' => self::originOf($address),
        'title' => $this->t('Runlight dashboard'),
        'referrerpolicy' => 'no-referrer',
        'sandbox' => 'allow-scripts allow-same-origin allow-popups allow-popups-to-escape-sandbox allow-downloads',
        'style' => 'display:block;width:100%;height:calc(100vh - 200px);min-height:600px;margin-top:12px;border:0;border-radius:8px;background:transparent',
      ],
      '#attached' => ['library' => ['runlight/embed']],
    ];
    return $build;
  }

  /** The scheme, host, and port of an address, as a browser writes its origin. */
  private static function originOf(string $address): string {
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
   * Whether the admin around the frame is dark: Gin's own setting when Gin is
   * the admin theme, else light, as Claro is.
   */
  private function theme(): string {
    if ((string) $this->config('system.theme')->get('admin') !== 'gin') {
      return 'light';
    }
    $dark = (string) $this->config('gin.settings')->get('enable_darkmode');
    return $dark === '1' ? 'dark' : ($dark === 'auto' ? '' : 'light');
  }

  /**
   * Asks the Runlight for a ticket that opens the dashboard once, framed by
   * this admin. Each ticket works for a few minutes and only once, so one is
   * asked for on every visit to the page and never kept.
   *
   * @return array{url: string, site: string}|string
   *   The page to frame and its site, or why there is none.
   */
  private function ticket(string $address, string $key): array|string {
    try {
      $response = \Drupal::httpClient()->request('POST', $address . '/api/embed', [
        'timeout' => 5,
        'http_errors' => FALSE,
        'allow_redirects' => FALSE,
        'headers' => ['Authorization' => 'Bearer ' . $key],
        'json' => ['origin' => \Drupal::request()->getSchemeAndHttpHost()],
      ]);
    }
    catch (\Throwable $e) {
      return (string) $this->t('Could not reach your Runlight: @message', ['@message' => $e->getMessage()]);
    }
    $body = json_decode((string) $response->getBody(), TRUE);
    $code = $response->getStatusCode();
    if ($code !== 201 || !is_array($body) || !is_string($body['ticket'] ?? NULL)) {
      if ($code === 401) {
        return (string) $this->t('Your Runlight does not know this dashboard key. Make a new one in Runlight’s Settings, Install, and enter it in the settings.');
      }
      $reason = is_array($body) && is_string($body['error'] ?? NULL) ? $body['error'] : (string) $this->t('It answered @code.', ['@code' => $code]);
      return (string) $this->t('Your Runlight would not open the dashboard here: @reason', ['@reason' => $reason]);
    }
    $theme = $this->theme();
    return [
      'url' => $address . '/embed?ticket=' . rawurlencode($body['ticket']) . ($theme !== '' ? '&theme=' . $theme : ''),
      'site' => is_string($body['site'] ?? NULL) ? $body['site'] : '',
    ];
  }

}
