<?php

declare(strict_types=1);

namespace Runlight\Tests\Conformance\Fake;

use Runlight\Http\Request;
use Runlight\Http\Response;
use Runlight\Tests\Conformance\Target;

/** A target that hands each request to the next closure in a script, for tests that look at exactly what the runner sends. */
final class ScriptedTarget implements Target
{
    /** @var list<array{string, Request}> */
    public array $seen = [];
    public int $idled = 0;

    /** @param list<\Closure(Request, string): ?Response> $script */
    public function __construct(private array $script)
    {
    }

    public function handle(Request $request): Response
    {
        return $this->next('routes', $request) ?? new Response('', 404);
    }

    public function links(Request $request): Response
    {
        return $this->next('links', $request) ?? new Response('', 404);
    }

    public function linkDomain(Request $request): ?Response
    {
        return $this->next('linkDomain', $request);
    }

    public function idle(): void
    {
        $this->idled++;
    }

    private function next(string $to, Request $request): ?Response
    {
        $this->seen[] = [$to, $request];
        $step = array_shift($this->script) ?? throw new \LogicException('The script ran out');
        return $step($request, $to);
    }
}
