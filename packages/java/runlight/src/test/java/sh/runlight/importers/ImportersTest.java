package sh.runlight.importers;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;
import java.util.stream.Stream;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import sh.runlight.Fixtures;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.http.FetchError;
import sh.runlight.http.FetchInit;
import sh.runlight.http.Fetcher;
import sh.runlight.http.Headers;
import sh.runlight.http.Response;

/**
 * Replays the importer scenarios in tests/fixtures/outbound.json (the cases of importers.test.ts
 * and more): each importer, run step by step against the same answers, must send the TypeScript
 * SDK's exact requests, wait as long between retries, ask about the same known links, and hand back
 * the same steps, cursors included.
 */
class ImportersTest {
  /**
   * A Fetcher that records each request as the TS fixtures record them, and answers from a table.
   */
  private static final class Recorder implements Fetcher {
    final List<Object> requests = new ArrayList<>();
    private final List<Map<String, Object>> routes;
    private final long[] left;

    Recorder(List<Map<String, Object>> routes) {
      this.routes = routes;
      this.left = new long[routes.size()];
      for (int i = 0; i < routes.size(); i++) {
        Object times = routes.get(i).get("times");
        left[i] = times == null ? Long.MAX_VALUE : Js.asLong(times);
      }
    }

    @Override
    public List<String> lookup(String name) {
      return List.of("93.184.215.14");
    }

    @Override
    public Response fetch(String url, FetchInit init) {
      Map<String, Object> headers = new LinkedHashMap<>();
      for (Map.Entry<String, String> e : init.headers.entries()) {
        headers.put(e.getKey(), e.getValue());
      }
      String body = init.bodyText();
      requests.add(
          Json.object(
              "method",
              init.method,
              "url",
              url,
              "headers",
              headers,
              "body",
              body == null ? "" : body));
      for (int i = 0; i < routes.size(); i++) {
        Map<String, Object> route = routes.get(i);
        if (left[i] <= 0 || !Pattern.compile((String) route.get("pattern")).matcher(url).find()) {
          continue;
        }
        left[i]--;
        if (Js.truthy(route.get("unreachable"))) {
          throw new FetchError("fetch failed");
        }
        Headers answer = Headers.of("content-type", "application/json");
        Map<String, Object> extra = Js.map(route.get("headers"));
        if (extra != null) {
          for (Map.Entry<String, Object> e : extra.entrySet()) {
            answer.set(e.getKey(), Js.string(e.getValue()));
          }
        }
        Object status = route.get("status");
        return new Response(
            Json.stringify(route.get("body")),
            status == null ? 200 : (int) Js.asLong(status),
            answer);
      }
      return new Response("{}", 404);
    }
  }

  static Stream<String> scenarios() {
    List<String> names = new ArrayList<>();
    for (Map<String, Object> s : Fixtures.cases(Fixtures.load("outbound"), "importers")) {
      names.add((String) s.get("name"));
    }
    return names.stream();
  }

  private static Map<String, Object> scenario(String name) {
    for (Map<String, Object> s : Fixtures.cases(Fixtures.load("outbound"), "importers")) {
      if (s.get("name").equals(name)) {
        return s;
      }
    }
    throw new IllegalArgumentException(name);
  }

  @ParameterizedTest
  @MethodSource("scenarios")
  void scenarioMatchesTypeScript(String name) {
    Map<String, Object> scenario = scenario(name);
    long now = Js.asLong(Fixtures.load("outbound").get("now"));
    @SuppressWarnings("unchecked")
    List<Map<String, Object>> routes =
        (List<Map<String, Object>>) (List<?>) Js.list(scenario.get("routes"));
    Recorder fetcher = new Recorder(routes);
    List<Object> waits = new ArrayList<>();
    Http http = new Http(fetcher, ms -> waits.add(Js.num(ms)));
    Importer importer = Index.IMPORTERS.get((String) scenario.get("source")).apply(http, () -> now);
    List<Object> knownList = Js.list(scenario.get("known"));
    List<Object> knownCalls = new ArrayList<>();
    Importer.Known known =
        (sourceId, slug, url) -> {
          knownCalls.add(Json.array(sourceId, slug, url));
          return knownList.contains(sourceId)
              || knownList.contains(Js.string(slug) + " " + Js.string(url));
        };
    Map<String, String> credentials = new LinkedHashMap<>();
    for (Map.Entry<String, Object> e : Js.map(scenario.get("credentials")).entrySet()) {
      credentials.put(e.getKey(), (String) e.getValue());
    }

    List<Map<String, Object>> expected = Fixtures.cases(scenario, "steps");
    String cursor = (String) expected.get(0).get("cursor");
    for (int i = 0; i < expected.size(); i++) {
      Map<String, Object> want = expected.get(i);
      assertEquals(want.get("cursor"), cursor, "step " + i + " starts from the same cursor");
      Map<String, Object> result;
      try {
        result = importer.step(credentials, cursor, known);
      } catch (ImportError error) {
        assertTrue(
            want.containsKey("error"), "step " + i + " should not fail: " + error.getMessage());
        Map<String, Object> got =
            Json.object(
                "message", error.getMessage(), "code", error.code(), "params", error.params());
        if (error instanceof HttpError h) {
          got.put("status", (long) h.status());
        }
        got.put("name", error.getClass().getSimpleName());
        assertEquals(Json.stringify(want.get("error")), Json.stringify(got));
        continue;
      }
      assertFalse(want.containsKey("error"), "step " + i + " should fail");
      assertEquals(Json.stringify(want.get("result")), Json.stringify(result), "step " + i);
      cursor = (String) result.get("cursor");
    }

    List<String> sent = new ArrayList<>();
    for (Object r : fetcher.requests) {
      sent.add(Json.stringify(r));
    }
    List<String> requests = new ArrayList<>();
    for (Object r : Js.list(scenario.get("requests"))) {
      requests.add(Json.stringify(r));
    }
    if (!Boolean.TRUE.equals(scenario.get("ordered"))) {
      // Umami asks for a link's events and sessions at once in TS; here one follows the other.
      Collections.sort(sent);
      Collections.sort(requests);
    }
    assertEquals(requests, sent);
    assertEquals(Json.stringify(scenario.get("waits")), Json.stringify(waits));
    assertEquals(Json.stringify(scenario.get("knownCalls")), Json.stringify(knownCalls));
  }

  @Test
  void datesParseAsJavaScriptParsesThem() {
    assertEquals(1767225600000.0, Http.parseDate("2026-01-01T00:00:00Z"));
    assertEquals(1767225600000.0, Http.parseDate("2026-01-01T00:00:00+0000"));
    assertEquals(1767225600000.0, Http.parseDate("2026-01-01"));
    assertEquals(1767225600500.0, Http.parseDate("2026-01-01T02:00:00.5+02:00"));
    assertEquals(
        1767225600000.0,
        Http.parseDate("2026-01-01T00:00:00"),
        "local time, and the tests run in UTC");
    assertEquals(0.0, Http.parseDate("1970-01-01T00:00:00.000Z"));
    assertTrue(Double.isNaN(Http.parseDate("nope")));
    assertTrue(Double.isNaN(Http.parseDate("2026-02-30")));
    assertTrue(Double.isNaN(Http.parseDate(null)));
    assertEquals("2026-03-02T00:00:00.000Z", Http.isoString(1772409600000.0));
    assertEquals("1969-12-31T23:59:59.999Z", Http.isoString(-1));
    assertThrows(IllegalArgumentException.class, () -> Http.isoString(Double.NaN));
  }
}
