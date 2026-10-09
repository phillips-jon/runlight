<?php

declare(strict_types=1);

namespace Runlight\Tests\Conformance;

use Runlight\Accounts\Crypto;
use Runlight\Body;
use Runlight\Http\Request;
use Runlight\Http\Response;
use Runlight\Http\SearchParams;
use Runlight\Http\Url;
use Runlight\Json;

/**
 * Plays a scenario from conformance/http.json exactly as play() in
 * packages/sdk/test/http-conformance.ts does, and returns each step's answer,
 * normalized, in the shape of the file's `expect`: stdClass objects with
 * status, headers, body, text, files, found, fetched, or pass.
 *
 * The scenario's options become the PHP options the port conventions name,
 * and a Target (the core, or a fake) takes the requests. Keep this file in step
 * with the TypeScript runner: FORMAT_SHA256 fails a test when the file's
 * description of the format changes.
 */
final class Player
{
    /** The SHA-256 of http.json's description this runner was written against. */
    public const FORMAT_SHA256 = '87a6f2d7f8acd8026aa4c9ede697d21457a0b9c1a2bfc01488aa2d9598def68f';

    /** Environment the SDK reads defaults from, cleared while a scenario plays so nothing outside it counts. */
    public const ENV = ['RUNLIGHT_TOKEN', 'RUNLIGHT_SECRET', 'CRON_SECRET', 'RUNLIGHT_OBSERVE_KEY', 'NODE_ENV'];

    /** The content type JavaScript's Request gives a string body sent with none, which the TypeScript answers were made with. */
    public const TEXT_BODY_TYPE = 'text/plain;charset=UTF-8';

    /** The clock, in epoch milliseconds, as the scenario's steps move it. */
    private int $now = 0;

    /**
     * Runs a scenario's steps and returns each answer, normalized.
     *
     * @param \stdClass $scenario one of http.json's scenarios, as Json::decode gives it
     * @param \Closure(array<string, mixed>, array<string, mixed>): Target $target makes the target from
     *        the Runlight options and the routes() options
     * @param mixed $store the store the Runlight gets, as its `store` option; left out when null
     * @return list<\stdClass>
     */
    public function play(\stdClass $scenario, \Closure $target, mixed $store = null): array
    {
        $saved = self::clearEnv();
        try {
            return $this->steps($scenario, $target, $store, new UpstreamFetcher($scenario->upstream ?? []));
        } finally {
            self::restoreEnv($saved);
        }
    }

    /**
     * The options new Runlight([...]) gets, without the store, the clock, and the fetcher.
     *
     * @return array<string, mixed>
     */
    public static function runlightOptions(\stdClass $scenario): array
    {
        $options = $scenario->options ?? new \stdClass();
        $out = [];
        if (!empty($options->managedSites)) {
            $out['managedSites'] = true;
        } elseif (isset($scenario->sites)) {
            $out['sites'] = self::plain($scenario->sites);
        } else {
            $out['site'] = self::plain($scenario->site);
        }
        if (isset($options->secret) && $options->secret !== '') {
            $out['secret'] = $options->secret;
        }
        if (property_exists($options, 'rateLimit')) {
            $out['rateLimit'] = $options->rateLimit;
        }
        return $out;
    }

    /**
     * The options $rl->routes([...]) gets. The token is always there: a string, "" for none, or null to
     * leave the routes open, never left out, which would read RUNLIGHT_TOKEN.
     *
     * @return array<string, mixed>
     */
    public static function routesOptions(\stdClass $scenario): array
    {
        $options = $scenario->options ?? new \stdClass();
        $out = [
            'token' => $scenario->token,
            'observeKey' => $options->observeKey ?? '',
            'cronSecret' => $options->cronSecret ?? '',
        ];
        if (!empty($options->accounts)) {
            $out['accounts'] = true;
        }
        if (!empty($options->origin)) {
            $out['origin'] = $options->origin;
        }
        return $out;
    }

    /** @return list<\stdClass> */
    private function steps(\stdClass $scenario, \Closure $makeTarget, mixed $store, UpstreamFetcher $fetcher): array
    {
        $this->now = (int) $scenario->start;
        $runlightOptions = ($store === null ? [] : ['store' => $store]) + self::runlightOptions($scenario) + [
            'now' => fn (): int => $this->now,
            'fetcher' => $fetcher,
        ];
        $target = $makeTarget($runlightOptions, self::routesOptions($scenario));
        /** @var array<string, string> $kept */
        $kept = [];
        /** @var array<string, array<string, string>> $jars */
        $jars = [];
        $answers = [];
        foreach ($scenario->steps as $i => $step) {
            try {
                $answers[] = $this->step($step, $target, $fetcher, $kept, $jars);
            } catch (\Throwable $error) {
                throw new \RuntimeException(sprintf('%s: step %d, %s %s: %s', $scenario->name, $i + 1, $step->method, $step->path, $error->getMessage()), 0, $error);
            }
        }
        return $answers;
    }

    /**
     * @param array<string, string> $kept
     * @param array<string, array<string, string>> $jars
     */
    private function step(\stdClass $step, Target $target, UpstreamFetcher $fetcher, array &$kept, array &$jars): \stdClass
    {
        $this->now += (int) ($step->advance ?? 0);
        $headers = [];
        foreach (get_object_vars($step->headers ?? new \stdClass()) as $k => $v) {
            $headers[strtolower((string) $k)] = $this->fillTotp((string) $v, $kept);
        }
        $body = null;
        if (isset($step->form)) {
            $fields = [];
            foreach (get_object_vars($this->fillDeep($step->form, $kept)) as $name => $value) {
                $fields[(string) $name] = (string) $value;
            }
            $body = (new SearchParams($fields))->toString();
            $headers['content-type'] ??= 'application/x-www-form-urlencoded';
        } elseif (property_exists($step, 'body')) {
            $body = is_string($step->body) ? $this->fillTotp($step->body, $kept) : Json::encode($this->fillDeep($step->body, $kept));
        }
        // JavaScript's Request gives a string body this type when none is named, and the core may read it.
        if ($body !== null) {
            $headers['content-type'] ??= self::TEXT_BODY_TYPE;
        }
        $jar = null;
        if (($step->jar ?? 'main') !== false) {
            $jars[(string) ($step->jar ?? 'main')] ??= [];
            $jar = &$jars[(string) ($step->jar ?? 'main')];
        }
        if ($jar !== null && $jar !== [] && !isset($headers['cookie'])) {
            $pairs = [];
            foreach ($jar as $k => $v) {
                $pairs[] = "$k=$v";
            }
            $headers['cookie'] = implode('; ', $pairs);
        }
        $to = $step->to ?? 'routes';
        $prefix = $to === 'routes' && empty($step->absolute) ? '/runlight' : '';
        $raw = 'https://' . ($step->host ?? 'example.com') . $prefix . $this->fillTotp((string) $step->path, $kept);
        // request.url is the parsed URL, as `new Request(url)` gives it.
        $url = Url::parse($raw)?->href() ?? $raw;
        $request = new Request($url, (string) $step->method, $headers, $body ?? '');
        $fetcher->take();
        $answer = match ($to) {
            'links' => $target->links($request),
            'linkDomain' => $target->linkDomain($request),
            default => $target->handle($request),
        };
        // Work the request started after answering (retention) finishes before the next one, as it would between real requests.
        $target->idle();
        $sentOut = $fetcher->take();
        $outbound = array_map(fn (array $f) => Normalizer::normalize($f['seen']), $sentOut);
        if ($answer === null) {
            $out = new \stdClass();
            $out->pass = true;
            if ($outbound !== []) {
                $out->fetched = $outbound;
            }
            return $out;
        }
        return $this->answer($step, $answer, $sentOut, $outbound, $kept, $jar);
    }

    /**
     * @param list<array{seen: \stdClass, text: string}> $sentOut
     * @param list<mixed> $outbound
     * @param array<string, string> $kept
     * @param array<string, string>|null $jar
     */
    private function answer(\stdClass $step, Response $answer, array $sentOut, array $outbound, array &$kept, ?array &$jar): \stdClass
    {
        $bytes = $answer->text();
        $text = Body::utf8($bytes);
        $type = trim(explode(';', $answer->headers->get('content-type') ?? '')[0]);
        $parsed = null;
        $hasParsed = false;
        if ($type !== 'application/zip' && $text !== '') {
            try {
                $parsed = Json::decode($text);
                $hasParsed = true;
            } catch (\JsonException) {
            }
        }
        foreach (get_object_vars($step->capture ?? new \stdClass()) as $name => $spec) {
            $kept[(string) $name] = self::capture((string) $spec, $answer, $text, $hasParsed ? $parsed : null, $sentOut);
        }
        foreach ($answer->headers->getSetCookie() as $cookie) {
            if ($jar === null) {
                continue;
            }
            $attributes = explode(';', $cookie);
            $pair = array_shift($attributes);
            $at = strpos($pair, '=');
            // As pair.slice(0, pair.indexOf("=")): with no "=", indexOf is -1, and the last character is cut.
            $name = trim($at === false ? substr($pair, 0, -1) : substr($pair, 0, $at));
            $value = trim($at === false ? $pair : substr($pair, $at + 1));
            $clears = false;
            foreach ($attributes as $attribute) {
                if (preg_match('/^\s*max-age=0\s*\z/i', $attribute)) {
                    $clears = true;
                }
            }
            if ($value === '' || $clears) {
                unset($jar[$name]);
            } else {
                $jar[$name] = $value;
            }
        }
        $sent = new \stdClass();
        foreach (Normalizer::HEADERS as $name) {
            if ($name === 'set-cookie') {
                $cookies = $answer->headers->getSetCookie();
                if ($cookies !== []) {
                    $sent->{$name} = array_map(Normalizer::cookieShape(...), $cookies);
                }
                continue;
            }
            $value = $answer->headers->get($name);
            if ($value !== null && $value !== '') {
                $sent->{$name} = $name === 'content-type' ? trim(explode(';', $value)[0]) : Normalizer::normalize($value);
            }
        }
        $out = new \stdClass();
        $out->status = $answer->status;
        if (get_object_vars($sent) !== []) {
            $out->headers = $sent;
        }
        if ($hasParsed) {
            $out->body = Normalizer::normalize($parsed);
        }
        if (!$hasParsed && ($type === 'text/plain' || $type === 'text/csv')) {
            $out->text = Normalizer::normalize($text);
        }
        if ($type === 'application/zip') {
            $out->files = array_map(fn (array $f) => (object) ['name' => $f['name'], 'text' => Normalizer::normalize($f['text'])], Zip::unzip($bytes));
        }
        if (isset($step->look)) {
            $out->found = array_map(fn ($s) => str_contains($text, (string) $s), $step->look);
        }
        if ($outbound !== []) {
            $out->fetched = $outbound;
        }
        return $out;
    }

    /**
     * A value kept from an answer: a dotted path into its JSON body, header:<name>, text, or fetched,
     * any of them followed by ~<regex> to keep the regex's first group instead. Read before normalizing.
     *
     * @param list<array{seen: \stdClass, text: string}> $sentOut
     */
    public static function capture(string $spec, Response $answer, string $text, mixed $parsed, array $sentOut): string
    {
        $cut = strpos($spec, '~');
        $source = $cut === false ? $spec : substr($spec, 0, $cut);
        $pattern = $cut === false ? null : substr($spec, $cut + 1);
        if ($source === 'text') {
            $value = $text;
        } elseif ($source === 'fetched') {
            $value = implode("\n", array_map(fn (array $f) => $f['text'], $sentOut));
        } elseif (str_starts_with($source, 'header:')) {
            $header = strtolower(substr($source, strlen('header:')));
            $value = $header === 'set-cookie' ? implode("\n", $answer->headers->getSetCookie()) : ($answer->headers->get($header) ?? '');
        } else {
            $value = self::jsString(self::dig($parsed, $source));
        }
        if ($pattern === null) {
            return $value;
        }
        return self::firstGroup($pattern, $value);
    }

    /** `new RegExp(pattern).exec(value)?.[1] ?? ""`. */
    public static function firstGroup(string $pattern, string $value): string
    {
        $regex = "\x01" . $pattern . "\x01u";
        $found = @preg_match($regex, $value, $m);
        if ($found === false) {
            $found = @preg_match(substr($regex, 0, -1), $value, $m);
        }
        if ($found === false) {
            throw new \InvalidArgumentException("The capture pattern $pattern is not one PCRE reads");
        }
        return $m[1] ?? '';
    }

    /** `path.split(".").reduce((v, k) => (v && typeof v === "object" ? v[k] : undefined), value)`. */
    public static function dig(mixed $value, string $path): mixed
    {
        foreach (explode('.', $path) as $k) {
            if ($value instanceof \stdClass) {
                $value = property_exists($value, $k) ? $value->{$k} : null;
            } elseif (is_array($value)) {
                $value = ctype_digit($k) && (string) (int) $k === $k ? ($value[(int) $k] ?? null) : null;
            } else {
                return null;
            }
        }
        return $value;
    }

    /** `String(value ?? "")`, as JavaScript writes a JSON value as text. */
    public static function jsString(mixed $value): string
    {
        return match (true) {
            $value === null => '',
            is_string($value) => $value,
            is_bool($value) => $value ? 'true' : 'false',
            is_int($value), is_float($value) => Json::number($value),
            is_array($value) => implode(',', array_map(self::jsString(...), $value)),
            default => '[object Object]',
        };
    }

    /** {{totp:name}} as the six-digit code for the captured secret at the step's clock, then {{name}}. */
    private function fillTotp(string $text, array $kept): string
    {
        $out = $text;
        if (preg_match_all('/\{\{totp:(\w+)\}\}/', $text, $matches, PREG_SET_ORDER)) {
            foreach ($matches as [$whole, $name]) {
                $at = strpos($out, $whole);
                if ($at !== false) {
                    $out = substr_replace($out, Crypto::totp($kept[$name] ?? '', intdiv($this->now, 30_000)), $at, strlen($whole));
                }
            }
        }
        return self::fill($out, $kept);
    }

    /** {{name}} as the value captured earlier, empty when nothing was. */
    private static function fill(string $text, array $kept): string
    {
        return (string) preg_replace_callback('/\{\{(\w+)\}\}/', fn (array $m) => $kept[$m[1]] ?? '', $text);
    }

    private function fillDeep(mixed $value, array $kept): mixed
    {
        if (is_string($value)) {
            return $this->fillTotp($value, $kept);
        }
        if (is_array($value)) {
            return array_map(fn ($v) => $this->fillDeep($v, $kept), $value);
        }
        if ($value instanceof \stdClass) {
            $out = new \stdClass();
            foreach (get_object_vars($value) as $k => $v) {
                $out->{$k} = $this->fillDeep($v, $kept);
            }
            return $out;
        }
        return $value;
    }

    /** A JSON value as plain PHP arrays, the shape options take. */
    private static function plain(mixed $value): mixed
    {
        return Json::decode(Json::encode($value), true);
    }

    /** @return array<string, array{env: string|false, _ENV: ?string, _SERVER: ?string, inEnv: bool, inServer: bool}> */
    public static function clearEnv(): array
    {
        $saved = [];
        foreach (self::ENV as $name) {
            $saved[$name] = [
                'env' => getenv($name),
                'inEnv' => array_key_exists($name, $_ENV),
                '_ENV' => $_ENV[$name] ?? null,
                'inServer' => array_key_exists($name, $_SERVER),
                '_SERVER' => $_SERVER[$name] ?? null,
            ];
            putenv($name);
            unset($_ENV[$name], $_SERVER[$name]);
        }
        return $saved;
    }

    public static function restoreEnv(array $saved): void
    {
        foreach ($saved as $name => $was) {
            if ($was['env'] === false) {
                putenv($name);
            } else {
                putenv("$name={$was['env']}");
            }
            if ($was['inEnv']) {
                $_ENV[$name] = $was['_ENV'];
            } else {
                unset($_ENV[$name]);
            }
            if ($was['inServer']) {
                $_SERVER[$name] = $was['_SERVER'];
            } else {
                unset($_SERVER[$name]);
            }
        }
    }
}
