package sh.runlight;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.fail;

import java.util.ArrayList;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import sh.runlight.http.Headers;
import sh.runlight.http.Request;
import sh.runlight.http.Response;

/**
 * The MCP server against tests/fixtures/mcp.json: the TypeScript's API reads and answers for the
 * same JSON-RPC messages and tool arguments, over canned API answers. The parts of mcp.test.ts that
 * need no store are here too.
 */
final class McpTest {
  /**
   * A readApi that logs each read, as path and [name, value] pairs, and answers from the fixture.
   */
  static Mcp.ApiRead readApi(List<Object> log) {
    Map<String, Object> api = Js.map(Fixtures.load("mcp").get("api"));
    return (path, params) -> {
      List<Object> pairs = new ArrayList<>();
      for (Map.Entry<String, String> p : params) {
        pairs.add(List.of(p.getKey(), p.getValue()));
      }
      log.add(Json.object("path", path, "params", pairs));
      Map<String, Object> canned = Js.map(api.get(path));
      if (canned == null) {
        canned =
            Json.object(
                "status",
                404L,
                "body",
                "{\"error\":\"Not found: " + path.replace("\"", "") + "\"}");
      }
      return new Response(
          (String) canned.get("body"),
          (int) Js.asLong(canned.get("status")),
          Headers.of("content-type", "application/json"));
    };
  }

  private static Request post(String url, String body) {
    return new Request(url, "POST", new Headers(), body);
  }

  @Test
  void toolCallsReadTheSameApiAndAnswerTheSame() {
    for (Map<String, Object> c : Fixtures.cases(Fixtures.load("mcp"), "calls")) {
      String label = Json.stringify(c.get("params"));
      List<Object> log = new ArrayList<>();
      Map<String, Object> result;
      try {
        result = Mcp.callTool(c.get("params"), readApi(log));
      } catch (McpError error) {
        assertTrue(c.containsKey("throws"), label + " threw " + error.getMessage());
        assertEquals(c.get("message"), error.getMessage(), label);
        continue;
      }
      assertFalse(c.containsKey("throws"), label + " should throw");
      assertEquals(Json.stringify(c.get("requests")), Json.stringify(log), label);
      Fixtures.assertJson(c.get("value"), result, label);
    }
  }

  @Test
  void jsonRpcAnswersMatch() {
    for (Map<String, Object> c : Fixtures.cases(Fixtures.load("mcp"), "rpcs")) {
      byte[] body =
          c.containsKey("bodyHex")
              ? HexFormat.of().parseHex((String) c.get("bodyHex"))
              : Js.utf8((String) c.get("body"));
      String label = Json.stringify(c.containsKey("bodyHex") ? c.get("bodyHex") : c.get("body"));
      List<Object> log = new ArrayList<>();
      Request request =
          new Request("https://example.com/runlight/mcp", "POST", new Headers(), body, "");
      if (c.containsKey("throws")) {
        assertThrows(RuntimeException.class, () -> Mcp.mcpResponse(request, readApi(log)), label);
        continue;
      }
      Response answer = Mcp.mcpResponse(request, readApi(log));
      assertEquals(Js.asLong(c.get("status")), answer.status(), label);
      Map<String, Object> headers = new LinkedHashMap<>();
      for (Map.Entry<String, String> e : answer.headers().entries()) {
        headers.put(e.getKey(), e.getValue());
      }
      assertEquals(Json.stringify(c.get("headers")), Json.stringify(headers), label);
      assertEquals(c.get("text"), answer.text(), label);
      assertEquals(Json.stringify(c.get("requests")), Json.stringify(log), label);
    }
  }

  @Test
  void toolsAreListedReadOnlyInOrder() {
    List<Object> log = new ArrayList<>();
    Response answer =
        Mcp.mcpResponse(
            post("https://x.com/mcp", "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}"),
            readApi(log));
    List<Object> tools = Js.list(Js.get(Js.get(Json.parse(answer.text()), "result"), "tools"));
    List<Object> names = new ArrayList<>();
    for (Object tool : tools) {
      names.add(Js.get(tool, "name"));
      assertEquals(true, Js.get(Js.get(tool, "annotations"), "readOnlyHint"));
    }
    assertEquals(Fixtures.load("mcp").get("tools"), names);
    assertTrue(answer.text().contains("\"properties\":{}"), "an empty schema is an object");
  }

  @Test
  void initializeAnswersTheAskedVersionOrTheNewest() {
    List<Object> log = new ArrayList<>();
    java.util.function.Function<String, Object> ask =
        version ->
            Js.get(
                Json.parse(
                    Mcp.mcpResponse(
                            post(
                                "https://x.com/mcp",
                                Json.stringify(
                                    Json.object(
                                        "jsonrpc",
                                        "2.0",
                                        "id",
                                        1L,
                                        "method",
                                        "initialize",
                                        "params",
                                        Json.object("protocolVersion", version)))),
                            readApi(log))
                        .text()),
                "result");
    assertEquals("2025-06-18", Js.get(ask.apply("2025-06-18"), "protocolVersion"));
    assertEquals("runlight", Js.get(Js.get(ask.apply("2025-06-18"), "serverInfo"), "name"));
    assertEquals(
        "2025-11-25",
        Js.get(ask.apply("1999-01-01"), "protocolVersion"),
        "an unknown version gets the newest");
    Response note =
        Mcp.mcpResponse(
            post(
                "https://x.com/mcp",
                "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"),
            readApi(log));
    assertEquals(202, note.status());
    assertEquals("", note.text());
  }

  @Test
  void anUnknownToolThrowsWithItsCode() {
    try {
      Mcp.callTool(Json.object("name", "nope"), readApi(new ArrayList<>()));
      fail("should throw");
    } catch (McpError error) {
      assertEquals(-32602, error.code());
      assertEquals("Unknown tool \"nope\"", error.getMessage());
    }
  }

  /** As edges.test.ts: a body that is fine but not an object passes as it is, even reshaped. */
  @Test
  void anAnswerThatIsNotAnObjectIsPassedOnAsItIs() {
    for (String body : List.of("null", "[1]", "5")) {
      Map<String, Object> result =
          Mcp.callTool(
              Json.object("name", "get_visit_times"), (path, params) -> new Response(body, 200));
      assertEquals(body, Js.get(Js.get(Js.get(result, "content"), "0"), "text"), body);
      Map<String, Object> refused =
          Mcp.callTool(
              Json.object("name", "list_sites"), (path, params) -> new Response(body, 403));
      assertEquals(
          "{\"content\":[{\"type\":\"text\",\"text\":\"Runlight answered 403\"}],\"isError\":true}",
          Json.stringify(refused),
          body);
    }
  }
}
