<?php

declare(strict_types=1);

namespace Runlight\Tests\Conformance\Fake;

use Runlight\Env;
use Runlight\Http\BodyTooLong;
use Runlight\Http\Fetcher;
use Runlight\Http\FetchError;
use Runlight\Http\Request;
use Runlight\Http\Response;
use Runlight\Http\SearchParams;
use Runlight\Http\Url;
use Runlight\Json;
use Runlight\Tests\Conformance\Player;
use Runlight\Tests\Conformance\Target;
use Runlight\Tests\Conformance\Zip;

/**
 * A stand-in for the PHP core that answers each step, deliberately, with the
 * answer http.json expects of it: placeholders filled with fresh values, ZIP
 * files zipped, the requests to other servers made through the runner's
 * fetcher, and Set-Cookie lines with values for the jars. Replaying every
 * scenario through it proves the runner itself (normalizing, captures, jars,
 * templates, ZIP reading, and the fetched record) before the core exists.
 *
 * It also checks what it is sent: the entry point, method, and URL each step
 * names, no template left unfilled, and nothing read from the environment.
 */
final class ReplayTarget implements Target
{
    private int $at = 0;
    public int $idled = 0;
    /** @var list<Request> */
    public array $requests = [];
    private readonly Fetcher $fetcher;
    private readonly \Closure $now;

    /**
     * @param array<string, mixed> $runlightOptions
     * @param array<string, mixed> $routesOptions
     */
    public function __construct(
        private readonly \stdClass $scenario,
        public readonly array $runlightOptions,
        public readonly array $routesOptions,
        private readonly Denormalizer $values = new Denormalizer(),
    ) {
        if (!array_key_exists('token', $routesOptions)) {
            throw new \LogicException('routes() must be given the token, null included');
        }
        $this->fetcher = $runlightOptions['fetcher'];
        $this->now = $runlightOptions['now'];
    }

    public function handle(Request $request): Response
    {
        return $this->answer('routes', $request) ?? throw new \LogicException('The routes always answer');
    }

    public function links(Request $request): Response
    {
        return $this->answer('links', $request) ?? throw new \LogicException('The link handler always answers');
    }

    public function linkDomain(Request $request): ?Response
    {
        return $this->answer('linkDomain', $request);
    }

    public function idle(): void
    {
        $this->idled++;
    }

    private function answer(string $to, Request $request): ?Response
    {
        $step = $this->scenario->steps[$this->at] ?? throw new \LogicException('More requests than steps');
        $this->at++;
        $this->requests[] = $request;
        $this->check($step, $to, $request);
        $expect = $step->expect;

        foreach ($expect->fetched ?? [] as $fetched) {
            $this->fetch($fetched);
        }
        if (!empty($expect->pass)) {
            return null;
        }
        $headers = [];
        foreach (get_object_vars($expect->headers ?? new \stdClass()) as $name => $value) {
            if ($name === 'set-cookie') {
                $headers[$name] = array_map(fn ($line) => $this->values->cookie((string) $line), $value);
            } elseif ($name === 'content-type') {
                $headers[$name] = $value;
            } else {
                $headers[$name] = $this->values->text((string) $value);
            }
        }
        if (isset($expect->files)) {
            $files = array_map(fn (\stdClass $f) => ['name' => $f->name, 'text' => $this->values->text($f->text)], $expect->files);
            // Every other ZIP is stored rather than deflated, so both are read.
            $body = Zip::zip($files, $this->at % 2 === 0);
        } elseif (property_exists($expect, 'body')) {
            $body = Json::encode($this->values->value($expect->body));
        } elseif (isset($expect->text)) {
            $body = $this->values->text($expect->text);
        } elseif (isset($expect->found)) {
            // A page that holds the look strings found and none of the others, and is not JSON.
            $body = "<!-- a page -->\n" . implode("\n", array_filter(array_map(fn ($s, $f) => $f ? $s : null, $step->look, $expect->found), fn ($s) => $s !== null));
        } else {
            $body = '';
        }
        return new Response($body, (int) $expect->status, $headers);
    }

    private function check(\stdClass $step, string $to, Request $request): void
    {
        $where = sprintf('step %d (%s %s)', $this->at, $step->method, $step->path);
        if (($step->to ?? 'routes') !== $to) {
            throw new \LogicException("$where went to $to");
        }
        if ($request->method !== strtoupper($step->method)) {
            throw new \LogicException("$where was sent as $request->method");
        }
        if (!str_contains($step->path, '{{')) {
            $prefix = $to === 'routes' && empty($step->absolute) ? '/runlight' : '';
            $url = (new Url('https://' . ($step->host ?? 'example.com') . $prefix . $step->path))->href();
            if ($request->url !== $url) {
                throw new \LogicException("$where was sent to $request->url");
            }
        }
        $sent = $request->url . "\n" . $request->text();
        foreach ($request->headers as $value) {
            $sent .= "\n" . $value;
        }
        if (str_contains($sent, '{{')) {
            throw new \LogicException("$where still holds a template: $sent");
        }
        foreach (Player::ENV as $name) {
            if (Env::get($name) !== null) {
                throw new \LogicException("$where can read $name");
            }
        }
        $now = ($this->now)();
        if (!is_int($now)) {
            throw new \LogicException("$where: the clock is not whole milliseconds");
        }
    }

    /** Makes one of the requests the step expects, through the runner's fetcher, as the core would. */
    private function fetch(\stdClass $fetched): void
    {
        $fetched = $this->values->value($fetched);
        $headers = (array) ($fetched->headers ?? []);
        $init = ['method' => $fetched->method, 'headers' => $headers];
        if (property_exists($fetched, 'body')) {
            $type = $headers['content-type'] ?? '';
            $init['body'] = match (true) {
                is_string($fetched->body) => $fetched->body,
                $fetched->body instanceof \stdClass && str_starts_with($type, 'application/x-www-form-urlencoded') => (new SearchParams(array_map('strval', get_object_vars($fetched->body))))->toString(),
                default => Json::encode($fetched->body),
            };
        }
        try {
            $this->fetcher->fetch($fetched->url, $init)->text();
        } catch (FetchError | BodyTooLong) {
            // A server that did not answer: the core carries on, as the TypeScript one did.
        }
    }
}
