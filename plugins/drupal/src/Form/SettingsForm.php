<?php

declare(strict_types=1);

namespace Drupal\runlight\Form;

use Drupal\Core\Form\ConfigFormBase;
use Drupal\Core\Form\FormStateInterface;

/**
 * Configuration, System, Runlight: where the site's Runlight is, and what it sends.
 */
final class SettingsForm extends ConfigFormBase {

  public function getFormId(): string {
    return 'runlight_settings';
  }

  protected function getEditableConfigNames(): array {
    return ['runlight.settings'];
  }

  /** The address as typed, tidied: no trailing slash, and the script's own address works too. */
  public static function tidy(string $value): string {
    $value = trim($value);
    $value = (string) preg_replace('#/s\.js$#', '', $value);
    return rtrim($value, '/');
  }

  public function buildForm(array $form, FormStateInterface $form_state): array {
    $config = $this->config('runlight.settings');
    $address = (string) $config->get('address');
    $form['intro'] = [
      '#markup' => '<p>' . $this->t('Runlight counts visitors without cookies and keeps the numbers in your own database. This module adds its script to every page and reports AI agents that read your pages. The numbers live in your Runlight, wherever you run it.') . '</p>',
    ];
    if ($address !== '') {
      $form['status'] = ['#markup' => '<p>' . $this->check($address) . '</p>'];
    }
    $form['address'] = [
      '#type' => 'url',
      '#title' => $this->t('Runlight address'),
      '#default_value' => $address,
      '#placeholder' => 'https://example.com/runlight or https://stats.example.com',
      '#description' => $this->t('The address Runlight answers at, where its dashboard opens. That Runlight must count this site, or its visits are ignored.'),
    ];
    $form['site'] = [
      '#type' => 'textfield',
      '#title' => $this->t('Site id'),
      '#default_value' => $config->get('site'),
      '#description' => $this->t('Optional. Only needed when that Runlight counts several sites and cannot tell this one by its hostname.'),
    ];
    $form['observe_key'] = [
      '#type' => 'password',
      '#title' => $this->t('Observe key'),
      '#attributes' => ['placeholder' => (string) $config->get('observe_key') !== '' ? $this->t('Saved. Leave blank to keep it for this address.') : ''],
      '#description' => $this->t('Optional. With this site’s key from Runlight’s Settings, Install, Key for CMS plugins, the module reports AI agents such as ChatGPT and Claude reading your pages. They run no JavaScript, so the script cannot see them. The key can report fetches for this site and nothing else.'),
    ];
    $form['dashboard_key'] = [
      '#type' => 'password',
      '#title' => $this->t('Dashboard key'),
      '#attributes' => ['placeholder' => (string) $config->get('dashboard_key') !== '' ? $this->t('Saved. Leave blank to keep it for this address.') : ''],
      '#description' => $this->t('Optional. With this site’s key from Runlight’s Settings, Install, Key for the dashboard in your CMS, Reports, Runlight shows this site’s numbers right here. The key opens the same read-only view a share link shows, framed only by this admin, and cannot read anything itself.'),
    ];
    $form['skip_admins'] = [
      '#type' => 'checkbox',
      '#title' => $this->t('Leave out the visits of people who can administer Runlight'),
      '#default_value' => $config->get('skip_admins'),
    ];
    $form['outbound'] = [
      '#type' => 'checkbox',
      '#title' => $this->t('Count clicks on links to other sites'),
      '#default_value' => $config->get('outbound'),
    ];
    $form['downloads'] = [
      '#type' => 'checkbox',
      '#title' => $this->t('Count file downloads'),
      '#default_value' => $config->get('downloads'),
    ];
    return parent::buildForm($form, $form_state);
  }

  /** Whether the address answers as a Runlight, in words. */
  private function check(string $address): string {
    try {
      $response = \Drupal::httpClient()->request('GET', $address . '/api', ['timeout' => 5, 'http_errors' => FALSE]);
      $body = json_decode((string) $response->getBody(), TRUE);
      if ($response->getStatusCode() === 200 && is_array($body) && ($body['name'] ?? '') === 'runlight') {
        return (string) $this->t('Connected to Runlight @version. <a href=":url" target="_blank" rel="noopener">Open the dashboard</a>.', ['@version' => (string) ($body['version'] ?? ''), ':url' => $address . '/']);
      }
      return (string) $this->t('Something answered, but not Runlight. Check that this is the address Runlight answers at, such as https://example.com/runlight for an app with Runlight mounted, or https://stats.example.com for the standalone server.');
    }
    catch (\Throwable $e) {
      return (string) $this->t('Could not reach it: @message', ['@message' => $e->getMessage()]);
    }
  }

  public function submitForm(array &$form, FormStateInterface $form_state): void {
    $config = $this->config('runlight.settings');
    $key = trim((string) $form_state->getValue('observe_key'));
    $dashboard = trim((string) $form_state->getValue('dashboard_key'));
    $address = self::tidy((string) $form_state->getValue('address'));
    // Left blank, a saved key stays, so it never has to be shown again, but only for the same
    // address: pointed somewhere else, the module must never send that Runlight's key there.
    $same = $address === (string) $config->get('address');
    $kept = $same ? (string) $config->get('observe_key') : '';
    $keptDashboard = $same ? (string) $config->get('dashboard_key') : '';
    $config
      ->set('address', $address)
      ->set('site', (string) preg_replace('/[^a-z0-9._-]/i', '', (string) $form_state->getValue('site')))
      ->set('observe_key', $key === '' ? $kept : $key)
      ->set('dashboard_key', $dashboard === '' ? $keptDashboard : $dashboard)
      ->set('skip_admins', (bool) $form_state->getValue('skip_admins'))
      ->set('outbound', (bool) $form_state->getValue('outbound'))
      ->set('downloads', (bool) $form_state->getValue('downloads'))
      ->save();
    parent::submitForm($form, $form_state);
  }

}
