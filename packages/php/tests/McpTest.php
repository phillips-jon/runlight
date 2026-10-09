<?php

declare(strict_types=1);

namespace Runlight\Tests;

use PHPUnit\Framework\TestCase;
use Runlight\Http\Request;
use Runlight\Http\Response;
use Runlight\Json;
use Runlight\Mcp;
use Runlight\McpError;

/**
 * The MCP server against tests/fixtures/mcp.json: the TypeScript's API reads and answers for the same JSON-RPC
 * messages and tool arguments, over canned API answers. The parts of mcp.test.ts that need no store are here too.
 */
final class McpTest extends TestCase
{
    /**
     * A readApi that logs each read and answers from the fixture's canned API.
     *
     * @param list<mixed> $log
     */
    public static function readApi(array &$log): \Closure
    {
        $api = Fixtures::load('mcp', true)['api'];
        return static function (string $path, array $params) use (&$log, $api): Response {
            $log[] = ['path' => $path, 'params' => $params];
            $canned = $api[$path] ?? ['status' => 404, 'body' => '{"error":"Not found: ' . str_replace('"', '', $path) . '"}'];
            return new Response($canned['body'], $canned['status'], ['content-type' => 'application/json']);
        };
    }

    public function testToolCallsReadTheSameApiAndAnswerTheSame(): void
    {
        foreach (Fixtures::load('mcp')->calls as $case) {
            $label = Json::encode($case->params);
            $log = [];
            try {
                $result = Mcp::callTool($case->params, self::readApi($log));
            } catch (McpError $error) {
                $this->assertTrue(isset($case->throws), "$label threw " . $error->getMessage());
                $this->assertSame($case->message, $error->getMessage(), $label);
                continue;
            }
            $this->assertFalse(isset($case->throws), "$label should throw");
            $this->assertSame(Json::encode($case->requests), Json::encode($log), $label);
            $this->assertSame(Json::encode($case->value), Json::encode($result), $label);
        }
    }

    public function testJsonRpcAnswersMatch(): void
    {
        foreach (Fixtures::load('mcp')->rpcs as $case) {
            $body = isset($case->bodyHex) ? (string) hex2bin($case->bodyHex) : $case->body;
            $log = [];
            $request = new Request('https://example.com/runlight/mcp', 'POST', [], $body);
            if (isset($case->throws)) {
                try {
                    Mcp::mcpResponse($request, self::readApi($log));
                    $this->fail("$body should throw");
                } catch (\TypeError) {
                    $this->addToAssertionCount(1);
                }
                continue;
            }
            $answer = Mcp::mcpResponse($request, self::readApi($log));
            $this->assertSame($case->status, $answer->status, $body);
            $this->assertSame((array) $case->headers, iterator_to_array($answer->headers), $body);
            $this->assertSame($case->text, $answer->text(), $body);
            $this->assertSame(Json::encode($case->requests), Json::encode($log), $body);
        }
    }

    public function testToolsAreListedReadOnlyInOrder(): void
    {
        $log = [];
        $answer = Mcp::mcpResponse(new Request('https://x.com/mcp', 'POST', [], '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'), self::readApi($log));
        $tools = Json::decode($answer->text(), true)['result']['tools'];
        $this->assertSame(Fixtures::load('mcp', true)['tools'], array_column($tools, 'name'));
        foreach ($tools as $tool) {
            $this->assertTrue($tool['annotations']['readOnlyHint']);
        }
        $this->assertStringContainsString('"properties":{}', $answer->text(), 'an empty schema is an object');
    }

    public function testInitializeAnswersTheAskedVersionOrTheNewest(): void
    {
        $log = [];
        $ask = fn (string $version) => Json::decode(Mcp::mcpResponse(
            new Request('https://x.com/mcp', 'POST', [], Json::encode(['jsonrpc' => '2.0', 'id' => 1, 'method' => 'initialize', 'params' => ['protocolVersion' => $version]])),
            self::readApi($log),
        )->text(), true)['result'];
        $this->assertSame('2025-06-18', $ask('2025-06-18')['protocolVersion']);
        $this->assertSame('runlight', $ask('2025-06-18')['serverInfo']['name']);
        $this->assertSame('2025-11-25', $ask('1999-01-01')['protocolVersion'], 'an unknown version gets the newest');
        $note = Mcp::mcpResponse(new Request('https://x.com/mcp', 'POST', [], '{"jsonrpc":"2.0","method":"notifications/initialized"}'), self::readApi($log));
        $this->assertSame(202, $note->status);
        $this->assertSame('', $note->text());
    }

    /** As edges.test.ts: a body that is fine but not an object passes as it is, even through a tool that reshapes. */
    public function testAnAnswerThatIsNotAnObjectIsPassedOnAsItIs(): void
    {
        foreach (['null', '[1]', '5'] as $body) {
            $result = Mcp::callTool(['name' => 'get_visit_times'], static fn (): Response => new Response($body, 200));
            $this->assertSame($body, $result['content'][0]['text'], $body);
            $refused = Mcp::callTool(['name' => 'list_sites'], static fn (): Response => new Response($body, 403));
            $this->assertSame(['content' => [['type' => 'text', 'text' => 'Runlight answered 403']], 'isError' => true], $refused, $body);
        }
    }
}
