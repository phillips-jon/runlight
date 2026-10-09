package sh.runlight;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static sh.runlight.Fixtures.assertJson;

import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import sh.runlight.http.Url;

/**
 * Replays tracker bodies through parsePayload, and the query fixture, as the TypeScript SDK read
 * them.
 */
class PayloadTest {
  @Test
  void payloads() {
    Map<String, Object> fixture = Fixtures.load("payload");
    assertEquals(Js.asLong(fixture.get("maxBody")), Payload.MAX_BODY);
    for (Map<String, Object> c : Fixtures.cases(fixture, "cases")) {
      Map<String, Object> payload = Payload.parsePayload((String) c.get("text"));
      if (payload != null) {
        payload.put("url", ((Url) payload.get("url")).href());
        payload.put(
            "props",
            payload.get("props") == null
                ? null
                : Json.stringify(Fixtures.stored(payload.get("props"))));
      }
      assertJson(c.get("payload"), payload, (String) c.get("text"));
    }
  }

  @Test
  void propsWithIndexKeysStayAnObject() {
    Map<String, Object> payload =
        Payload.parsePayload(
            "{\"k\":\"event\",\"u\":\"https://example.com/\",\"n\":\"x\",\"p\":{\"1\":\"b\",\"0\":\"a\"}}");
    assertEquals("{\"0\":\"a\",\"1\":\"b\"}", Json.stringify(payload.get("props")));
  }

  @Test
  void dimensionsAndFilters() {
    Map<String, Object> fixture = Fixtures.load("query");
    assertJson(fixture.get("eventDimensions"), Query.EVENT_DIMENSIONS);
    assertJson(fixture.get("sessionDimensions"), Query.SESSION_DIMENSIONS);
    assertJson(fixture.get("dimensions"), Query.DIMENSIONS);
    assertEquals(Js.asLong(fixture.get("maxFilters")), Query.MAX_FILTERS);
    for (Map<String, Object> c : Fixtures.cases(fixture, "dimensionTests")) {
      String value = (String) c.get("value");
      assertJson(
          List.of(c.get("isDimension"), c.get("isSessionDimension"), c.get("isEventDimension")),
          List.of(
              Query.isDimension(value),
              Query.isSessionDimension(value),
              Query.isEventDimension(value)),
          value);
    }
    for (Map<String, Object> c : Fixtures.cases(fixture, "filters")) {
      assertJson(
          c.get("filter"), Query.parseFilter((String) c.get("text")), (String) c.get("text"));
    }
  }

  @Test
  void theVersionsAndIconAreTheTypeScriptSdks() {
    Map<String, Object> fixture = Fixtures.load("version");
    assertEquals(fixture.get("version"), Version.version());
    assertEquals(Js.asLong(fixture.get("apiVersion")), Version.apiVersion());
    assertEquals(fixture.get("icon"), Version.runlightIcon());
  }
}
