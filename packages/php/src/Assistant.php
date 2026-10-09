<?php

declare(strict_types=1);

namespace Runlight;

use Runlight\Http\CurlFetcher;
use Runlight\Http\Fetcher;
use Runlight\Http\FetchError;
use Runlight\Http\Response;
use Runlight\Http\Url;

/**
 * The dashboard's assistant: questions about the stats, answered by a model
 * the owner chooses, through the same read-only tools as the MCP server. The
 * model runs on the server, so the key never reaches a browser, and each tool
 * reads the API with the asking person's own access.
 *
 * Two protocols cover the providers: Anthropic's Messages API, and OpenAI's
 * Chat Completions, which OpenAI, Gemini (through its compatible endpoint),
 * OpenRouter, Ollama, LM Studio, and most others speak. Plain HTTP through a
 * Fetcher, no SDKs.
 *
 * Settings are array{provider: string, model: string, baseUrl: string, key: string}; messages are
 * list<array{role: 'user'|'assistant', content: string}>; the context (what the person is looking at, so "this
 * week" and "this page" mean what they see) is array{site: array{id: string, name: string, timezone: string},
 * today: string, view: string, language: string}.
 */
final class Assistant
{
    /**
     * Each provider: id, name, protocol ("anthropic" or "openai"), baseUrl (the API's address, filled in for
     * known services and asked for otherwise), model (one to start with, or "" when the person picks one), and
     * key ("yes", "no" for a model on your own machine, or "optional").
     */
    public const PROVIDERS = [
        ['id' => 'anthropic', 'name' => 'Anthropic (Claude)', 'protocol' => 'anthropic', 'baseUrl' => 'https://api.anthropic.com/v1', 'model' => 'claude-sonnet-5-5', 'key' => 'yes'],
        ['id' => 'openai', 'name' => 'OpenAI', 'protocol' => 'openai', 'baseUrl' => 'https://api.openai.com/v1', 'model' => '', 'key' => 'yes'],
        ['id' => 'gemini', 'name' => 'Google Gemini', 'protocol' => 'openai', 'baseUrl' => 'https://generativelanguage.googleapis.com/v1beta/openai', 'model' => '', 'key' => 'yes'],
        ['id' => 'openrouter', 'name' => 'OpenRouter', 'protocol' => 'openai', 'baseUrl' => 'https://openrouter.ai/api/v1', 'model' => '', 'key' => 'yes'],
        ['id' => 'ollama', 'name' => 'Ollama', 'protocol' => 'openai', 'baseUrl' => 'http://localhost:11434/v1', 'model' => '', 'key' => 'no'],
        ['id' => 'lmstudio', 'name' => 'LM Studio', 'protocol' => 'openai', 'baseUrl' => 'http://localhost:1234/v1', 'model' => '', 'key' => 'no'],
        ['id' => 'custom', 'name' => 'Another OpenAI-compatible service', 'protocol' => 'openai', 'baseUrl' => '', 'model' => '', 'key' => 'optional'],
    ];

    private const MAX_ROUNDS = 8;
    /** However many rounds a question takes, the answer comes within this long or the assistant stops. */
    public const DEADLINE_MS = 120_000;
    private const MAX_TOKENS = 1500;

    private const TOO_LONG = 'That question took too long to answer. Try asking something narrower.';

    /** Words that only acknowledge an answer, in the dashboard's languages; a message of nothing else gets a reply without the model. */
    private const THANKS = '/^(?:(?:thanks|thank you|thank you so much|thanks a lot|thx|ty|cheers|ok|okay|great|cool|nice|perfect|awesome|got it|good|merci|merci beaucoup|super|parfait|d\'accord|gracias|muchas gracias|vale|genial|perfecto|danke|danke schön|vielen dank|prima|alles klar|obrigado|obrigada|valeu|ótimo|beleza)[' . Js::SPACE . '!.,]*)+$/iuD';

    private const WELCOME = [
        'en' => "You're welcome. Ask me anything else about your stats.",
        'fr' => 'Avec plaisir. Demandez-moi autre chose sur vos statistiques.',
        'es' => 'De nada. Pregúntame lo que quieras sobre tus estadísticas.',
        'de' => 'Gern geschehen. Frag mich gern noch etwas zu deinen Statistiken.',
        'pt' => 'De nada. Pergunte o que quiser sobre suas estatísticas.',
    ];

    /** @return array{id: string, name: string, protocol: string, baseUrl: string, model: string, key: string}|null */
    private static function provider(mixed $id): ?array
    {
        foreach (self::PROVIDERS as $provider) {
            if ($provider['id'] === $id) {
                return $provider;
            }
        }
        return null;
    }

    /** @param array{site: array{id: string, name: string, timezone: string}, today: string, view: string, language: string} $context */
    private static function system(array $context): string
    {
        $site = $context['site'];
        return Mcp::INSTRUCTIONS . "

You are the assistant inside this Runlight dashboard. Today is {$context['today']} in {$site['timezone']}. The person is looking at the site \"{$site['name']}\" (id {$site['id']}) for {$context['view']}. Unless they ask about another site or range, use this site and these dates.

When a question needs numbers, read them with the tools first and never guess one. Answer in a few short sentences or a short list, in plain language, and name the dates you looked at.

Rule: answer only the newest message. If it asks nothing new (thanks, a greeting, \"great\", \"that helps\"), reply with one short friendly sentence, call no tools, and do not repeat, summarise, or re-check any earlier answer. Only go back to earlier numbers when the person asks about them again. Bounce rate is a fraction from 0 to 1 and durations are milliseconds in the tools; give them as a percent and in seconds or minutes. Write in the language whose code is \"{$context['language']}\".";
    }

    /** Stops when the question's time is up or the person has left, before more work starts. */
    private static function inTime(int $deadline, \Closure $now, ?\Closure $cancelled): void
    {
        if ($cancelled !== null && $cancelled()) {
            throw new AssistantError('The question was cancelled.', 'assistant_cancelled');
        }
        if ($now() >= $deadline) {
            throw new AssistantError(self::TOO_LONG, 'assistant_slow');
        }
    }

    /** The service's own message from an error answer, never the request (it carries the key); "" when there is none. */
    private static function serviceMessage(mixed $data): string
    {
        $error = $data === null ? Undefined::value() : Js::get($data, 'error');
        if (is_string($error)) {
            return $error;
        }
        $message = $error === null || $error instanceof Undefined ? null : Js::get($error, 'message');
        return is_string($message) ? $message : '';
    }

    /** @param array<string, string> $headers */
    private static function post(Fetcher $fetcher, string $url, array $headers, mixed $body, int $deadline, \Closure $now, ?\Closure $cancelled): mixed
    {
        self::inTime($deadline, $now, $cancelled);
        $left = $deadline - $now();
        try {
            $answer = $fetcher->fetch($url, [
                'method' => 'POST',
                'headers' => array_merge(['content-type' => 'application/json'], $headers),
                'body' => Json::encode($body),
                'timeoutMs' => min(90_000, $left),
            ]);
        } catch (\Throwable $error) {
            $host = (new Url($url))->host();
            throw $error instanceof FetchError && $error->timedOut
                ? new AssistantError("Could not reach $host: it took too long to answer", 'assistant_timeout', ['host' => $host])
                : new AssistantError("Could not reach $host: the connection failed", 'unreachable', ['host' => $host]);
        }
        [$parsed, $data] = Js::parseJson($answer->text());
        if (!$parsed) {
            $data = null;
        }
        if (!$answer->ok()) {
            $message = self::serviceMessage($data);
            $host = (new Url($url))->host();
            if ($message === '') {
                throw new AssistantError("$host: it answered {$answer->status}", 'assistant_status', ['host' => $host, 'status' => (string) $answer->status]);
            }
            $detail = Js::cut($message, 300);
            throw new AssistantError("$host: $detail", 'assistant_refused', ['host' => $host, 'detail' => $detail]);
        }
        return $data ?? Json::object();
    }

    /**
     * @param callable(string, list<array{0: string, 1: string}>): Response $readApi
     * @return array{text: string, error: bool}
     */
    private static function toolText(mixed $name, mixed $args, callable $readApi): array
    {
        try {
            $result = Mcp::callTool(['name' => $name, 'arguments' => Js::truthy($args) && Js::isObject($args) ? $args : Json::object()], $readApi);
            return ['text' => $result['content'][0]['text'] ?? '', 'error' => ($result['isError'] ?? false) === true];
        } catch (\Throwable $error) {
            return ['text' => $error->getMessage(), 'error' => true];
        }
    }

    /** A short reply to a message that only says thanks or OK, or null when the message asks something. */
    public static function acknowledgement(string $text, string $language): ?string
    {
        $plain = Js::trim((string) preg_replace('/\p{Extended_Pictographic}|\x{FE0F}/u', ' ', $text));
        $welcome = self::WELCOME[$language] ?? self::WELCOME['en'];
        if ($plain === '' && Js::trim($text) !== '') {
            return $welcome;
        }
        return preg_match(self::THANKS, $plain) ? $welcome : null;
    }

    private static function clock(?\Closure $now): \Closure
    {
        return $now ?? static fn (): int => (int) floor(microtime(true) * 1000);
    }

    /**
     * Answers the last question in `messages`, calling tools as the model asks. Returns the reply and the tools it
     * used. `$now` is the clock in milliseconds; `$cancelled` says whether the person has left, checked before each
     * request and tool, as the TypeScript's AbortSignal is.
     *
     * @param array{provider: string, model: string, baseUrl: string, key: string} $settings
     * @param list<array{role: string, content: string}> $messages
     * @param array{site: array{id: string, name: string, timezone: string}, today: string, view: string, language: string} $context
     * @param callable(string, list<array{0: string, 1: string}>): Response $readApi
     * @param (\Closure(): int)|null $now
     * @param (\Closure(): bool)|null $cancelled
     * @return array{reply: string, tools: list<mixed>}
     * @throws AssistantError
     */
    public static function chat(array $settings, array $messages, array $context, callable $readApi, ?Fetcher $fetcher = null, ?\Closure $now = null, ?\Closure $cancelled = null): array
    {
        $fetcher ??= new CurlFetcher();
        $now = self::clock($now);
        $provider = self::provider($settings['provider'] ?? null);
        if ($provider === null) {
            throw new AssistantError('Choose a provider in Settings, AI Assistant', 'assistant_provider');
        }
        $base = (string) preg_replace('#/+\z#', '', ($settings['baseUrl'] ?? '') !== '' ? $settings['baseUrl'] : $provider['baseUrl']);
        if ($base === '') {
            throw new AssistantError("Enter the service's address in Settings, AI Assistant", 'assistant_address');
        }
        $model = ($settings['model'] ?? '') !== '' ? $settings['model'] : $provider['model'];
        if ($model === '') {
            throw new AssistantError('Enter a model in Settings, AI Assistant', 'assistant_model');
        }
        $key = (string) ($settings['key'] ?? '');
        $used = [];
        // "Thanks!" needs no model, no tools, and certainly not the last answer again.
        $last = $messages === [] ? null : $messages[count($messages) - 1]['content'] ?? null;
        $thanks = self::acknowledgement($last === null ? '' : Js::string($last), $context['language']);
        if ($thanks !== null) {
            return ['reply' => $thanks, 'tools' => []];
        }
        $deadline = $now() + self::DEADLINE_MS;
        // The last twenty turns, starting with a question (Anthropic refuses a history that opens with an answer),
        // and with unanswered questions in a row (a reply that never came) joined into one.
        $recent = array_slice(array_values($messages), -20);
        while ($recent !== [] && $recent[0]['role'] !== 'user') {
            array_shift($recent);
        }
        $history = [];
        foreach ($recent as $m) {
            $content = Js::cut(Js::string($m['content']), 8000);
            $n = count($history);
            if ($n > 0 && $history[$n - 1]['role'] === $m['role']) {
                $history[$n - 1]['content'] .= "\n\n$content";
            } else {
                $history[] = ['role' => $m['role'], 'content' => $content];
            }
        }

        if ($provider['protocol'] === 'anthropic') {
            $tools = array_map(static fn (array $t): array => ['name' => $t['name'], 'description' => $t['description'], 'input_schema' => $t['inputSchema']], Mcp::tools());
            $convo = $history;
            for ($round = 0; $round < self::MAX_ROUNDS; $round++) {
                $data = self::post(
                    $fetcher,
                    "$base/messages",
                    ['x-api-key' => $key, 'anthropic-version' => '2023-06-01'],
                    ['model' => $model, 'max_tokens' => self::MAX_TOKENS, 'system' => self::system($context), 'tools' => $tools, 'messages' => $convo],
                    $deadline,
                    $now,
                    $cancelled,
                );
                $blocks = Js::get($data, 'content');
                if ($blocks === null || $blocks instanceof Undefined) {
                    $blocks = [];
                }
                if (!is_array($blocks) || !array_is_list($blocks)) {
                    throw new \TypeError('blocks.filter is not a function');
                }
                $calls = array_values(array_filter($blocks, static fn ($b) => Js::get($b, 'type') === 'tool_use'));
                if (Js::get($data, 'stop_reason') !== 'tool_use' || !$calls) {
                    $texts = [];
                    foreach ($blocks as $b) {
                        if (Js::get($b, 'type') === 'text') {
                            $text = Js::get($b, 'text');
                            $texts[] = $text === null || $text instanceof Undefined ? '' : Js::string($text);
                        }
                    }
                    return ['reply' => Js::trim(implode("\n", $texts)), 'tools' => $used];
                }
                $convo[] = ['role' => 'assistant', 'content' => $blocks];
                $results = [];
                foreach ($calls as $call) {
                    // The deadline covers the reading too, however many tools one answer asks for.
                    self::inTime($deadline, $now, $cancelled);
                    $name = Js::get($call, 'name');
                    $name = $name === null || $name instanceof Undefined ? '' : $name;
                    $used[] = $name;
                    $out = self::toolText($name, Js::get($call, 'input'), $readApi);
                    $result = ['type' => 'tool_result', 'tool_use_id' => Js::get($call, 'id'), 'content' => $out['text']];
                    if ($out['error']) {
                        $result['is_error'] = true;
                    }
                    $results[] = $result;
                }
                $convo[] = ['role' => 'user', 'content' => $results];
            }
            throw new AssistantError('The assistant needed too many steps for that question. Try asking something narrower.', 'assistant_steps');
        }

        $tools = array_map(static fn (array $t): array => ['type' => 'function', 'function' => ['name' => $t['name'], 'description' => $t['description'], 'parameters' => $t['inputSchema']]], Mcp::tools());
        $convo = [['role' => 'system', 'content' => self::system($context)], ...$history];
        $headers = $key !== '' ? ['authorization' => "Bearer $key"] : [];
        for ($round = 0; $round < self::MAX_ROUNDS; $round++) {
            // OpenAI's newer models take max_completion_tokens and refuse max_tokens; the other services still take max_tokens.
            $limit = $provider['id'] === 'openai' ? ['max_completion_tokens' => self::MAX_TOKENS] : ['max_tokens' => self::MAX_TOKENS];
            $data = self::post($fetcher, "$base/chat/completions", $headers, ['model' => $model, ...$limit, 'messages' => $convo, 'tools' => $tools], $deadline, $now, $cancelled);
            $message = self::firstMessage($data);
            $calls = Js::get($message, 'tool_calls');
            $count = $calls === null || $calls instanceof Undefined ? Undefined::value() : Js::get($calls, 'length');
            $content = Js::get($message, 'content');
            if (!Js::truthy($count)) {
                return ['reply' => Js::trim($content === null || $content instanceof Undefined ? '' : Js::string($content)), 'tools' => $used];
            }
            if (!is_array($calls) || !array_is_list($calls)) {
                throw new \TypeError('message.tool_calls is not iterable');
            }
            $convo[] = ['role' => 'assistant', 'content' => $content instanceof Undefined ? null : $content, 'tool_calls' => $calls];
            foreach ($calls as $call) {
                self::inTime($deadline, $now, $cancelled);
                $function = Js::get($call, 'function');
                $name = Js::get($function, 'name');
                $used[] = $name instanceof Undefined ? null : $name;
                $given = Js::get($function, 'arguments');
                [$parsed, $args] = Js::parseJson(Js::truthy($given) ? Js::string($given) : '{}');
                if (!$parsed) {
                    $args = Json::object();
                }
                $out = self::toolText($name, $args, $readApi);
                $convo[] = ['role' => 'tool', 'tool_call_id' => Js::get($call, 'id'), 'content' => $out['text']];
            }
        }
        throw new AssistantError('The assistant needed too many steps for that question. Try asking something narrower.', 'assistant_steps');
    }

    /** data.choices?.[0]?.message ?? {} */
    private static function firstMessage(mixed $data): mixed
    {
        $choices = Js::get($data, 'choices');
        if ($choices === null || $choices instanceof Undefined) {
            return Json::object();
        }
        $first = Js::get($choices, 0);
        if ($first === null || $first instanceof Undefined) {
            return Json::object();
        }
        $message = Js::get($first, 'message');
        return $message === null || $message instanceof Undefined ? Json::object() : $message;
    }

    /**
     * The models a service offers with a key, from its own list: Anthropic's
     * /models, or the /models of an OpenAI-compatible API. Newest or most
     * relevant first where the service orders them; otherwise by name.
     *
     * @param array{provider: string, baseUrl: string, key: string} $settings
     * @return list<array{id: string, name: string}>
     * @throws AssistantError
     */
    public static function listModels(array $settings, ?Fetcher $fetcher = null): array
    {
        $fetcher ??= new CurlFetcher();
        $provider = self::provider($settings['provider'] ?? null);
        if ($provider === null) {
            throw new AssistantError('Choose a provider', 'assistant_provider');
        }
        $base = (string) preg_replace('#/+\z#', '', ($settings['baseUrl'] ?? '') !== '' ? $settings['baseUrl'] : $provider['baseUrl']);
        if ($base === '') {
            throw new AssistantError("Enter the service's address first", 'assistant_address');
        }
        $key = (string) ($settings['key'] ?? '');
        if ($provider['key'] === 'yes' && $key === '') {
            throw new AssistantError("Enter your {$provider['name']} key first", 'assistant_key', ['provider' => $provider['name']]);
        }
        $headers = $provider['protocol'] === 'anthropic'
            ? ['x-api-key' => $key, 'anthropic-version' => '2023-06-01']
            : ($key !== '' ? ['authorization' => "Bearer $key"] : []);
        try {
            $answer = $fetcher->fetch("$base/models" . ($provider['protocol'] === 'anthropic' ? '?limit=100' : ''), ['headers' => $headers, 'timeoutMs' => 20_000]);
        } catch (\Throwable) {
            $host = (new Url($base))->host();
            throw new AssistantError("Could not reach $host", 'unreachable', ['host' => $host]);
        }
        [$parsed, $data] = Js::parseJson($answer->text());
        if (!$parsed) {
            $data = null;
        }
        if (!$answer->ok()) {
            $message = self::serviceMessage($data);
            $host = (new Url($base))->host();
            if ($message === '') {
                throw new AssistantError("$host: it answered {$answer->status}", 'assistant_status', ['host' => $host, 'status' => (string) $answer->status]);
            }
            $detail = Js::cut($message, 300);
            throw new AssistantError("$host: $detail", 'assistant_refused', ['host' => $host, 'detail' => $detail]);
        }
        $list = $data === null ? Undefined::value() : Js::get($data, 'data');
        if ($list === null || $list instanceof Undefined) {
            $list = [];
        }
        if (!is_array($list) || !array_is_list($list)) {
            throw new \TypeError('data.data.filter is not a function');
        }
        $models = [];
        foreach ($list as $m) {
            $id = Js::get($m, 'id');
            if (!is_string($id) || $id === '') {
                continue;
            }
            // Gemini lists ids as "models/gemini-...", which its OpenAI-compatible API takes without the prefix.
            $id = (string) preg_replace('#^models/#', '', $id);
            $display = Js::get($m, 'display_name');
            $models[] = ['id' => $id, 'name' => is_string($display) ? $display : $id];
        }
        if ($models === []) {
            $host = (new Url($base))->host();
            throw new AssistantError("$host listed no models. Type the model's name instead.", 'assistant_no_models', ['host' => $host]);
        }
        // Anthropic lists newest first already; others come in no useful order.
        if ($provider['protocol'] !== 'anthropic') {
            usort($models, static fn (array $a, array $b): int => self::localeCompare($a['id'], $b['id']));
        }
        return $models;
    }

    /** a.localeCompare(b) with ICU's default collation, as Node has it; by UTF-16 code units without ext-intl. */
    private static function localeCompare(string $a, string $b): int
    {
        static $collator = null;
        if (class_exists(\Collator::class)) {
            $collator ??= new \Collator('en');
            $order = $collator->compare($a, $b);
            if ($order !== false) {
                return $order;
            }
        }
        return Js::compare($a, $b);
    }
}
