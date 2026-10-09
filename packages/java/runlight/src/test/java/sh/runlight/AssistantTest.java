package sh.runlight;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.fail;

import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;
import org.junit.jupiter.api.Test;
import sh.runlight.http.FetchError;
import sh.runlight.http.FetchInit;
import sh.runlight.http.Fetcher;
import sh.runlight.http.Headers;
import sh.runlight.http.Response;

/**
 * The assistant against tests/fixtures/assistant.json: for each provider and failure, the very
 * requests the TypeScript sends (bodies compared by SHA-256), the API reads its tools make, and
 * what it answers.
 */
final class AssistantTest {
  private static final Map<String, Object> CONTEXT =
      Json.object(
          "site",
          Json.object("id", "default", "name", "Blog", "timezone", "UTC"),
          "today",
          "2026-10-08",
          "view",
          "today",
          "language",
          "en");

  /**
   * A Fetcher that records each request and answers from a queue: a Response, or "timeout" or
   * "network" to fail.
   */
  private static final class Recorder implements Fetcher {
    final List<Map<String, Object>> requests = new ArrayList<>();
    private final Deque<Object> queue;

    Recorder(List<Object> queue) {
      this.queue = new ArrayDeque<>(queue);
    }

    @Override
    public Response fetch(String url, FetchInit init) {
      Map<String, Object> headers = new LinkedHashMap<>();
      for (Map.Entry<String, List<String>> e : init.headers.all().entrySet()) {
        headers.put(e.getKey(), String.join(", ", e.getValue()));
      }
      requests.add(
          Json.object(
              "url",
              url,
              "method",
              init.method,
              "headers",
              headers,
              "body",
              init.body,
              "timeoutMs",
              init.timeoutMs));
      Object next = queue.poll();
      if (next == null) {
        throw new IllegalStateException("No canned answer left");
      }
      if (next.equals("timeout")) {
        throw new FetchError("The operation timed out", true, null);
      }
      if (next.equals("network")) {
        throw new FetchError("Could not connect");
      }
      return (Response) next;
    }
  }

  private static Response json(String body) {
    return new Response(body, 200, Headers.of("content-type", "application/json"));
  }

  @SuppressWarnings("unchecked")
  private static List<Map<String, Object>> maps(Object list) {
    return (List<Map<String, Object>>) (List<?>) Js.list(list);
  }

  @Test
  void scenariosSendTheSameRequestsAndAnswerTheSame() {
    for (Map<String, Object> scenario : Fixtures.cases(Fixtures.load("assistant"), "scenarios")) {
      String name = (String) scenario.get("name");
      List<Object> queue = new ArrayList<>();
      for (Map<String, Object> c : maps(scenario.get("responses"))) {
        queue.add(
            c.containsKey("throws")
                ? c.get("throws")
                : new Response(
                    (String) c.get("body"),
                    (int) Js.asLong(c.get("status")),
                    Headers.of("content-type", "application/json")));
      }
      Recorder fetcher = new Recorder(queue);
      List<Object> tools = new ArrayList<>();
      Map<String, Object> settings = Js.map(scenario.get("settings"));
      try {
        Object result =
            scenario.get("call").equals("chat")
                ? Assistant.chat(
                    settings,
                    maps(scenario.get("messages")),
                    Js.map(scenario.get("context")),
                    McpTest.readApi(tools),
                    fetcher)
                : Assistant.listModels(settings, fetcher);
        assertTrue(scenario.containsKey("result"), name + " answered " + Json.stringify(result));
        Fixtures.assertJson(scenario.get("result"), result, name);
      } catch (AssistantError error) {
        assertTrue(scenario.containsKey("error"), name + " threw " + error.getMessage());
        Map<String, Object> expected = Js.map(scenario.get("error"));
        assertEquals(expected.get("message"), error.getMessage(), name);
        assertEquals(expected.get("code"), error.code(), name);
        assertEquals(Json.stringify(expected.get("params")), Json.stringify(error.params()), name);
      }
      assertEquals(
          Json.stringify(scenario.get("tools")),
          Json.stringify(tools),
          name + " read the API differently");
      List<Map<String, Object>> expectedRequests = maps(scenario.get("requests"));
      assertEquals(expectedRequests.size(), fetcher.requests.size(), name);
      for (int i = 0; i < expectedRequests.size(); i++) {
        Map<String, Object> expected = expectedRequests.get(i);
        Map<String, Object> sent = fetcher.requests.get(i);
        assertEquals(expected.get("url"), sent.get("url"), name + " request " + i);
        assertEquals(expected.get("method"), sent.get("method"), name + " request " + i);
        assertEquals(
            Json.stringify(expected.get("headers")),
            Json.stringify(sent.get("headers")),
            name + " request " + i + " headers");
        byte[] body = (byte[]) sent.get("body");
        assertEquals(
            expected.get("bodySha256"),
            body == null ? null : HexFormat.of().formatHex(Hash.sha256Bytes(body)),
            name + " request " + i + " body: " + (body == null ? null : Js.decodeUtf8(body)));
      }
    }
  }

  @Test
  void acknowledgementsMatch() {
    for (Map<String, Object> c : Fixtures.cases(Fixtures.load("assistant"), "acknowledgements")) {
      assertEquals(
          c.get("reply"),
          Assistant.acknowledgement((String) c.get("text"), (String) c.get("language")),
          Json.stringify(List.of(c.get("text"), c.get("language"))));
    }
  }

  @Test
  void thanksGetsAShortReplyWithoutTheModelOrTheTools() {
    for (String text :
        List.of(
            "Thanks!",
            "thank you",
            "Thanks!! 🙏",
            "ok",
            "Great, thanks.",
            "👍",
            "merci beaucoup",
            "Danke schön!",
            "valeu")) {
      assertNotNull(Assistant.acknowledgement(text, "en"), text);
    }
    for (String text :
        List.of(
            "Thanks, and what about last week?",
            "What was my bounce rate?",
            "ok so which pages?",
            "great results?")) {
      assertNull(Assistant.acknowledgement(text, "en"), text);
    }
    assertTrue(Assistant.acknowledgement("merci", "fr").contains("plaisir"));
  }

  @Test
  void eachRequestHasTheTimeLeftAndTheDeadlineStopsTheRest() {
    AtomicLong clock = new AtomicLong(1_000_000);
    java.util.function.Function<String, Response> toolUse =
        id ->
            json(
                Json.stringify(
                    Json.object(
                        "stop_reason",
                        "tool_use",
                        "content",
                        List.of(
                            Json.object(
                                "type",
                                "tool_use",
                                "id",
                                id,
                                "name",
                                "list_sites",
                                "input",
                                new LinkedHashMap<>())))));
    Recorder fetcher =
        new Recorder(List.of(toolUse.apply("a"), toolUse.apply("b"), toolUse.apply("c")));
    List<Object> log = new ArrayList<>();
    Mcp.ApiRead readApi = McpTest.readApi(log);
    Mcp.ApiRead slowApi =
        (path, params) -> {
          clock.addAndGet(50_000);
          return readApi.read(path, params);
        };
    try {
      Assistant.chat(
          Json.object("provider", "anthropic", "model", "m", "baseUrl", "", "key", "k"),
          List.of(Json.object("role", "user", "content", "All of it")),
          CONTEXT,
          slowApi,
          fetcher,
          clock::get,
          null);
      fail("should run out of time");
    } catch (AssistantError error) {
      assertEquals("assistant_slow", error.code());
    }
    List<Object> timeouts = new ArrayList<>();
    for (Map<String, Object> r : fetcher.requests) {
      timeouts.add(r.get("timeoutMs"));
    }
    assertEquals(List.of(90_000L, 70_000L, 20_000L), timeouts);
    assertEquals(3, log.size());
  }

  @Test
  void aCancelledQuestionStopsBeforeItsNextRequest() {
    Recorder fetcher = new Recorder(List.of());
    try {
      Assistant.chat(
          Json.object("provider", "openai", "model", "m", "baseUrl", "", "key", "k"),
          List.of(Json.object("role", "user", "content", "Hi?")),
          CONTEXT,
          McpTest.readApi(new ArrayList<>()),
          fetcher,
          null,
          () -> true);
      fail("should be cancelled");
    } catch (AssistantError error) {
      assertEquals("assistant_cancelled", error.code());
      assertEquals("The question was cancelled.", error.getMessage());
    }
    assertEquals(List.of(), fetcher.requests);
  }

  @Test
  void modelsAreListedWithinTwentySeconds() {
    Recorder fetcher =
        new Recorder(List.of(new Response("{\"data\":[{\"id\":\"b\"},{\"id\":\"a\"}]}", 200)));
    assertEquals(
        "[{\"id\":\"a\",\"name\":\"a\"},{\"id\":\"b\",\"name\":\"b\"}]",
        Json.stringify(
            Assistant.listModels(
                Json.object("provider", "ollama", "baseUrl", "", "key", ""), fetcher)));
    assertEquals(20_000L, fetcher.requests.get(0).get("timeoutMs"));
    assertEquals("http://localhost:11434/v1/models", fetcher.requests.get(0).get("url"));
  }

  /**
   * collation.json, written by scripts/java-collation.mts, holds pairs of strings with Node 24's
   * Math.sign(a.localeCompare(b)), over ASCII, spaces, controls, Latin letters with marks
   * (precomposed and not), and model names.
   */
  @Test
  void collationMatchesNode() {
    List<Object> pairs;
    try (InputStream in = AssistantTest.class.getResourceAsStream("collation.json")) {
      pairs = Js.list(Json.parse(new String(in.readAllBytes(), StandardCharsets.UTF_8)));
    } catch (IOException e) {
      throw new UncheckedIOException(e);
    }
    List<String> wrong = new ArrayList<>();
    for (Object p : pairs) {
      List<Object> pair = Js.list(p);
      String a = (String) pair.get(0);
      String b = (String) pair.get(1);
      long want = Js.asLong(pair.get(2));
      int got = Assistant.localeCompare(a, b);
      if (got != want) {
        wrong.add(Json.stringify(Json.array(a, b, want, (long) got)));
      }
    }
    assertTrue(
        wrong.isEmpty(),
        wrong.size()
            + " of "
            + pairs.size()
            + " pairs differ: "
            + String.join(", ", wrong.subList(0, Math.min(20, wrong.size()))));
  }
}
