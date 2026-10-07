<?php

declare(strict_types=1);

namespace Drupal\runlight\Controller;

use Drupal\Core\Controller\ControllerBase;
use Drupal\Core\Routing\TrustedRedirectResponse;
use Drupal\Core\Url;

/**
 * Reports, Runlight: opens the dashboard, which lives in your Runlight.
 */
final class DashboardController extends ControllerBase {

  public function open(): TrustedRedirectResponse|array {
    $address = (string) $this->config('runlight.settings')->get('address');
    if ($address === '') {
      return [
        '#markup' => $this->t('Set your Runlight address on the <a href=":url">settings page</a> first.', [':url' => Url::fromRoute('runlight.settings')->toString()]),
      ];
    }
    $response = new TrustedRedirectResponse($address . '/');
    $response->getCacheableMetadata()->addCacheTags(['config:runlight.settings']);
    return $response;
  }

}
