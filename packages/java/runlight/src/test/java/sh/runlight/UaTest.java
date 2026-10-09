package sh.runlight;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static sh.runlight.Fixtures.assertJson;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

/**
 * Replays conformance/ua.json, every case, and the wider fixture written from the TypeScript SDK.
 */
class UaTest {
  private static Double width(Object value) {
    return value == null ? null : ((Number) value).doubleValue();
  }

  @Test
  void conformance() {
    for (Map<String, Object> c : Fixtures.cases(Fixtures.conformance("ua"), "cases")) {
      String ua = (String) c.get("ua");
      Map<String, Object> agent = Ua.aiAgent(ua);
      if (c.get("agent") != null) {
        Map<String, Object> want = Js.map(c.get("agent"));
        assertEquals(want.get("name"), agent == null ? null : agent.get("name"), ua);
        assertEquals(want.get("kind"), agent == null ? null : agent.get("kind"), ua);
        continue;
      }
      assertNull(agent, ua);
      assertEquals(Boolean.TRUE.equals(c.get("bot")), Ua.isBot(ua), ua);
      if (c.get("client") != null) {
        Map<String, Object> hints = c.get("hints") == null ? Map.of() : Js.map(c.get("hints"));
        assertJson(c.get("client"), Ua.parseClient(ua, hints, width(c.get("screenWidth"))), ua);
      }
    }
  }

  @Test
  void clientHintsMarkAMobileChromiumAsMobile() {
    String ua =
        "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36";
    assertEquals("tablet", Ua.parseClient(ua).get("device"));
    assertEquals("tablet", Ua.parseClient(ua, Map.of("mobile", "?1"), null).get("device"));
    String desktop =
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36";
    assertEquals("mobile", Ua.parseClient(desktop, Map.of("mobile", "?1"), null).get("device"));
  }

  @Test
  void fixture() {
    List<Map<String, Object>> cases = Fixtures.cases(Fixtures.load("ua"), "cases");
    List<String> failures = new ArrayList<>();
    for (Map<String, Object> c : cases) {
      String ua = (String) c.get("ua");
      Map<String, Object> hints = c.get("hints") == null ? Map.of() : Js.map(c.get("hints"));
      Map<String, Object> got =
          Json.object(
              "agent", Ua.aiAgent(ua),
              "bot", Ua.isBot(ua),
              "client", Ua.parseClient(ua, hints, width(c.get("screenWidth"))));
      Map<String, Object> want =
          Json.object("agent", c.get("agent"), "bot", c.get("bot"), "client", c.get("client"));
      if (!Json.stringify(Fixtures.stored(got)).equals(Json.stringify(want))) {
        failures.add(Fixtures.label(c) + " gave " + Fixtures.label(got));
      }
    }
    assertTrue(cases.size() > 200);
    assertEquals(List.of(), failures.subList(0, Math.min(20, failures.size())));
  }
}
