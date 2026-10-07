<?php

declare(strict_types=1);

namespace Drupal\runlight\StackMiddleware;

use Drupal\Core\Config\ConfigFactoryInterface;
use Drupal\runlight\Agents;
use GuzzleHttp\ClientInterface;
use Psr\Log\LoggerInterface;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\HttpKernelInterface;

/**
 * Reports a page served to an AI agent. Agents run no JavaScript, so the
 * script never sees them.
 *
 * It is middleware ahead of the page cache because most pages an agent
 * fetches are cached ones, and a cache hit never reaches the kernel's
 * events: Drupal does not even run terminate() for it. The report is sent
 * from a shutdown function, which PHP runs once the response is out (under
 * PHP-FPM, Symfony closes the connection first), so the page is never
 * slowed down. Only known agents' requests are reported.
 */
final class AgentObserver implements HttpKernelInterface {

  public function __construct(
    private readonly HttpKernelInterface $app,
    private readonly ConfigFactoryInterface $configFactory,
    private readonly ClientInterface $httpClient,
    private readonly LoggerInterface $logger,
  ) {}

  public function handle(Request $request, int $type = self::MAIN_REQUEST, bool $catch = TRUE): Response {
    $response = $this->app->handle($request, $type, $catch);
    if ($type === self::MAIN_REQUEST && $request->isMethod('GET')) {
      $agent = (string) $request->headers->get('User-Agent', '');
      if (Agents::isAgent($agent)) {
        $url = $request->getUri();
        register_shutdown_function(fn () => $this->report($url, $agent));
      }
    }
    return $response;
  }

  private function report(string $url, string $agent): void {
    $config = $this->configFactory->get('runlight.settings');
    $address = (string) $config->get('address');
    $key = (string) $config->get('observe_key');
    if ($address === '' || $key === '') {
      return;
    }
    try {
      $this->httpClient->request('POST', $address . '/api/observe', [
        'timeout' => 3,
        'headers' => ['Authorization' => 'Bearer ' . $key],
        'json' => ['url' => $url, 'userAgent' => $agent],
      ]);
    }
    catch (\Throwable $e) {
      // Analytics must never break the page it watches; note it and move on.
      $this->logger->notice('Could not report an AI agent fetch: @message', ['@message' => $e->getMessage()]);
    }
  }

}
