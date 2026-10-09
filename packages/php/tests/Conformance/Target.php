<?php

declare(strict_types=1);

namespace Runlight\Tests\Conformance;

use Runlight\Http\Request;
use Runlight\Http\Response;

/** The entry points a scenario's steps go to: the PHP core (CoreTarget), or a fake that proves the runner. */
interface Target
{
    /** The routes' handler, $rl->routes([...])->handle(). */
    public function handle(Request $request): Response;

    /** The app's own short-link path, $rl->linkHandler(). */
    public function links(Request $request): Response;

    /** The link-domain middleware, $rl->linkDomainResponse(); null lets the request pass on to the app. */
    public function linkDomain(Request $request): ?Response;

    /** Finishes work a request started after answering (retention), as `await rl.idle()` does in TypeScript. */
    public function idle(): void;
}
