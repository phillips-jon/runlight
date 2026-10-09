<?php

declare(strict_types=1);

namespace Runlight\Tests\Conformance;

use Runlight\Http\Request;
use Runlight\Http\Response;
use Runlight\Runlight;

/** The PHP core, through the public API the port conventions name. */
final class CoreTarget implements Target
{
    private Runlight $rl;
    private object $routes;
    /** @var callable(Request): Response */
    private $links;

    /**
     * @param array<string, mixed> $runlightOptions for new Runlight([...])
     * @param array<string, mixed> $routesOptions for $rl->routes([...])
     */
    public function __construct(array $runlightOptions, array $routesOptions)
    {
        $this->rl = new Runlight($runlightOptions);
        $this->routes = $this->rl->routes($routesOptions);
        $this->links = $this->rl->linkHandler();
    }

    public static function available(): bool
    {
        return class_exists(Runlight::class);
    }

    public function handle(Request $request): Response
    {
        return $this->routes->handle($request);
    }

    public function links(Request $request): Response
    {
        return ($this->links)($request);
    }

    public function linkDomain(Request $request): ?Response
    {
        return $this->rl->linkDomainResponse($request);
    }

    /**
     * TypeScript deletes visits past a shorter retention after answering. If the PHP core does that work
     * inline, there is nothing to wait for; if it defers it, it gives Runlight an idle() that finishes it.
     */
    public function idle(): void
    {
        if (method_exists($this->rl, 'idle')) {
            $this->rl->idle();
        }
    }
}
