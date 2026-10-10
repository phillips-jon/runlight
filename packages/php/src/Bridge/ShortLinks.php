<?php

declare(strict_types=1);

namespace Runlight\Bridge;

use Runlight\Runlight;
use Symfony\Component\HttpFoundation\Request;

/**
 * Short links before the app's own routes, as HttpFoundation::shortLink() answers them: link domains added in
 * Settings, and `{linkPath}/{slug}` when the link exists. Laravel takes it as global middleware, which its
 * container builds with the app's Runlight singleton.
 *
 *   ->withMiddleware(function (Middleware $middleware) {
 *       $middleware->prepend(\Runlight\Bridge\ShortLinks::class);
 *   })
 *
 * Symfony calls onKernelRequest() from a kernel.request listener that runs before the router.
 */
final class ShortLinks
{
    public function __construct(private readonly Runlight $rl)
    {
    }

    /** Laravel's middleware signature. */
    public function handle(Request $request, \Closure $next): mixed
    {
        return HttpFoundation::shortLink($this->rl, $request) ?? $next($request);
    }

    /**
     * Symfony's kernel.request event, typed loosely so that Runlight needs no symfony/http-kernel. It takes
     * anything with getRequest() and setResponse(), as RequestEvent has, and leaves sub-requests alone.
     */
    public function onKernelRequest(object $event): void
    {
        if (method_exists($event, 'isMainRequest') && !$event->isMainRequest()) {
            return;
        }
        $answer = HttpFoundation::shortLink($this->rl, $event->getRequest());
        if ($answer !== null) {
            $event->setResponse($answer);
        }
    }
}
