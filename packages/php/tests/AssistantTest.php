<?php

declare(strict_types=1);

namespace Runlight\Tests;

use PHPUnit\Framework\TestCase;
use Runlight\Assistant;
use Runlight\AssistantError;
use Runlight\Http\Response;
use Runlight\Json;

/**
 * The assistant against tests/fixtures/assistant.json: for each provider and failure, the very requests the
 * TypeScript sends (bodies compared by SHA-256), the API reads its tools make, and what it answers.
 */
final class AssistantTest extends TestCase
{
    private const CONTEXT = ['site' => ['id' => 'default', 'name' => 'Blog', 'timezone' => 'UTC'], 'today' => '2026-10-08', 'view' => 'today', 'language' => 'en'];

    public function testScenariosSendTheSameRequestsAndAnswerTheSame(): void
    {
        foreach (Fixtures::load('assistant', true)['scenarios'] as $scenario) {
            $name = $scenario['name'];
            $queue = array_map(static fn (array $c) => isset($c['throws']) ? $c['throws'] : new Response($c['body'], $c['status'], ['content-type' => 'application/json']), $scenario['responses']);
            $fetcher = new RecordingFetcher($queue);
            $tools = [];
            try {
                $result = $scenario['call'] === 'chat'
                    ? Assistant::chat($scenario['settings'], $scenario['messages'], $scenario['context'], McpTest::readApi($tools), $fetcher)
                    : Assistant::listModels($scenario['settings'], $fetcher);
                $this->assertArrayHasKey('result', $scenario, "$name answered " . Json::encode($result));
                $this->assertSame(Json::encode($scenario['result']), Json::encode($result), $name);
            } catch (AssistantError $error) {
                $this->assertArrayHasKey('error', $scenario, "$name threw {$error->getMessage()}");
                $this->assertSame($scenario['error']['message'], $error->getMessage(), $name);
                $this->assertSame($scenario['error']['code'], $error->code, $name);
                $this->assertSame(Json::encode($scenario['error']['params'] === [] ? Json::object() : $scenario['error']['params']), Json::encode($error->params === [] ? Json::object() : $error->params), $name);
            }
            $this->assertSame(Json::encode($scenario['tools']), Json::encode($tools), "$name read the API differently");
            $this->assertCount(count($scenario['requests']), $fetcher->requests, $name);
            foreach ($scenario['requests'] as $i => $expected) {
                $sent = $fetcher->requests[$i];
                $this->assertSame($expected['url'], $sent['url'], "$name request $i");
                $this->assertSame($expected['method'], $sent['method'], "$name request $i");
                $this->assertSame(Json::encode($expected['headers'] === [] ? Json::object() : $expected['headers']), Json::encode($sent['headers'] === [] ? Json::object() : $sent['headers']), "$name request $i headers");
                $this->assertSame($expected['bodySha256'], $sent['body'] === null ? null : hash('sha256', $sent['body']), "$name request $i body: {$sent['body']}");
            }
        }
    }

    public function testAcknowledgementsMatch(): void
    {
        foreach (Fixtures::load('assistant', true)['acknowledgements'] as $case) {
            $this->assertSame($case['reply'], Assistant::acknowledgement($case['text'], $case['language']), Json::encode([$case['text'], $case['language']]));
        }
    }

    public function testThanksGetsAShortReplyWithoutTheModelOrTheTools(): void
    {
        foreach (['Thanks!', 'thank you', 'Thanks!! 🙏', 'ok', 'Great, thanks.', '👍', 'merci beaucoup', 'Danke schön!', 'valeu'] as $text) {
            $this->assertNotNull(Assistant::acknowledgement($text, 'en'), $text);
        }
        foreach (['Thanks, and what about last week?', 'What was my bounce rate?', 'ok so which pages?', 'great results?'] as $text) {
            $this->assertNull(Assistant::acknowledgement($text, 'en'), $text);
        }
        $this->assertMatchesRegularExpression('/plaisir/', (string) Assistant::acknowledgement('merci', 'fr'));
    }

    public function testEachRequestHasTheTimeLeftAndTheDeadlineStopsTheRest(): void
    {
        $clock = 1_000_000;
        $now = static function () use (&$clock): int {
            return $clock;
        };
        $toolUse = fn (string $id) => new Response(Json::encode(['stop_reason' => 'tool_use', 'content' => [['type' => 'tool_use', 'id' => $id, 'name' => 'list_sites', 'input' => Json::object()]]]));
        $fetcher = new RecordingFetcher([$toolUse('a'), $toolUse('b'), $toolUse('c')]);
        $log = [];
        $readApi = McpTest::readApi($log);
        $slowApi = static function (string $path, array $params) use (&$clock, $readApi): Response {
            $clock += 50_000;
            return $readApi($path, $params);
        };
        try {
            Assistant::chat(['provider' => 'anthropic', 'model' => 'm', 'baseUrl' => '', 'key' => 'k'], [['role' => 'user', 'content' => 'All of it']], self::CONTEXT, $slowApi, $fetcher, $now);
            $this->fail('should run out of time');
        } catch (AssistantError $error) {
            $this->assertSame('assistant_slow', $error->code);
        }
        $this->assertSame([90_000, 70_000, 20_000], array_column($fetcher->requests, 'timeoutMs'));
        $this->assertCount(3, $log);
    }

    public function testACancelledQuestionStopsBeforeItsNextRequest(): void
    {
        $fetcher = new RecordingFetcher([]);
        $log = [];
        try {
            Assistant::chat(['provider' => 'openai', 'model' => 'm', 'baseUrl' => '', 'key' => 'k'], [['role' => 'user', 'content' => 'Hi?']], self::CONTEXT, McpTest::readApi($log), $fetcher, null, fn () => true);
            $this->fail('should be cancelled');
        } catch (AssistantError $error) {
            $this->assertSame('assistant_cancelled', $error->code);
            $this->assertSame('The question was cancelled.', $error->getMessage());
        }
        $this->assertSame([], $fetcher->requests);
    }

    public function testModelsAreListedWithinTwentySeconds(): void
    {
        $fetcher = new RecordingFetcher([new Response('{"data":[{"id":"b"},{"id":"a"}]}')]);
        $this->assertSame([['id' => 'a', 'name' => 'a'], ['id' => 'b', 'name' => 'b']], Assistant::listModels(['provider' => 'ollama', 'baseUrl' => '', 'key' => ''], $fetcher));
        $this->assertSame(20_000, $fetcher->requests[0]['timeoutMs']);
        $this->assertSame('http://localhost:11434/v1/models', $fetcher->requests[0]['url']);
    }
}
