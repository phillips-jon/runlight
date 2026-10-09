package sh.runlight;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static sh.runlight.Fixtures.assertJson;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import sh.runlight.http.SearchParams;
import sh.runlight.http.Url;

/**
 * Replays conformance/url.json: URLs, query strings, and numbers read and written as JavaScript
 * does.
 */
class UrlTest {
  private static Map<String, Object> fixture() {
    return Fixtures.conformance("url");
  }

  private static void check(String input, String base, Object expect) {
    Url url = Url.parse(input, base);
    String label = Json.stringify(input) + (base == null ? "" : " on " + base);
    if (expect == null) {
      assertNull(url, label + " should not parse");
      return;
    }
    assertNotNull(url, label + " should parse");
    assertJson(
        expect,
        Json.object(
            "href", url.href(),
            "protocol", url.protocol,
            "username", url.username,
            "password", url.password,
            "hostname", url.hostname,
            "port", url.port,
            "host", url.host(),
            "origin", url.origin(),
            "pathname", url.pathname,
            "search", url.search,
            "hash", url.hash),
        label);
  }

  @Test
  void urls() {
    for (Map<String, Object> c : Fixtures.cases(fixture(), "urls")) {
      check((String) c.get("input"), null, c.get("expect"));
    }
    for (Map<String, Object> c : Fixtures.cases(fixture(), "relative")) {
      check((String) c.get("input"), (String) c.get("base"), c.get("expect"));
    }
  }

  @Test
  void queries() {
    for (Map<String, Object> c : Fixtures.cases(fixture(), "queries")) {
      SearchParams params = new SearchParams((String) c.get("input"));
      List<Object> pairs = new ArrayList<>();
      for (Map.Entry<String, String> e : params.entries()) {
        pairs.add(List.of(e.getKey(), e.getValue()));
      }
      assertJson(c.get("pairs"), pairs, (String) c.get("input"));
      assertEquals(c.get("string"), params.toString(), (String) c.get("input"));
    }
    for (Map<String, Object> c : Fixtures.cases(fixture(), "written")) {
      SearchParams params = new SearchParams();
      for (Object pair : Js.list(c.get("pairs"))) {
        params.append((String) Js.list(pair).get(0), (String) Js.list(pair).get(1));
      }
      assertEquals(c.get("string"), params.toString());
    }
  }

  @Test
  void numbers() {
    for (Map<String, Object> c : Fixtures.cases(fixture(), "numbers")) {
      Object n = c.get("n");
      double value = n instanceof String s ? Double.parseDouble(s) : ((Number) n).doubleValue();
      assertEquals(c.get("text"), Json.number(value), String.valueOf(n));
    }
  }

  @Test
  void jsonIsWrittenAsJavaScriptWritesIt() {
    assertEquals(
        "{\"1\":\"b\",\"2\":\"c\",\"a\":1}",
        Json.stringify(Json.object("a", 1, "2", "c", "1", "b")));
    assertEquals(
        "[1,2.5,null,\"\\ud800\",\"\u2028\"]",
        Json.stringify(List.of(1L, 2.5, Double.NaN, "\ud800", "\u2028")));
    assertEquals("1e+21", Json.number(1e21));
    assertEquals("123456789012345680000", Json.number(123456789012345680000.0));
    assertEquals("1e-7", Json.number(1e-7));
    assertEquals("0.000001", Json.number(0.000001));
    assertEquals("-1.5", Json.number(-1.5));
    assertEquals(
        "{\n  \"a\": [\n    1\n  ],\n  \"b\": {}\n}",
        Json.stringify(Json.object("a", List.of(1), "b", Map.of()), 2));
    assertJson(
        Json.object("x", Json.array(1L, 2.5, true, null)),
        Json.parse(" {\"x\":[1,2.5,true,null]} "));
  }
}
