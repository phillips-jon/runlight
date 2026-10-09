package sh.runlight;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import java.util.Map;
import java.util.function.Supplier;
import org.junit.jupiter.api.Test;

/**
 * Goals, funnels, and journeys checked as the TypeScript SDK checks them, against the shared
 * goals.json and journeys.json fixtures.
 */
class GoalsTest {
  /** The answer as the fixture writes it: the row with a new id as "<random>", or the error. */
  private static String outcome(Supplier<Map<String, Object>> fn, boolean fresh) {
    try {
      Map<String, Object> value = fn.get();
      if (fresh && ((String) value.get("id")).matches("[0-9a-f]{24}")) {
        value.put("id", "<random>");
      }
      return Json.stringify(Json.object("value", Fixtures.stored(value)));
    } catch (CodedError e) {
      return Json.stringify(
          Json.object(
              "error",
              Json.object("message", e.getMessage(), "code", e.code(), "params", e.params())));
    }
  }

  @Test
  void goalsAreCheckedAsTheTypeScriptSdkChecksThem() {
    Map<String, Object> fixture = Fixtures.load("goals");
    List<Map<String, Object>> existing = Fixtures.cases(fixture, "existing");
    List<Map<String, Object>> cases = Fixtures.cases(fixture, "goals");
    assertTrue(cases.size() > 50);
    for (int i = 0; i < cases.size(); i++) {
      Map<String, Object> c = cases.get(i);
      String id = (String) c.get("id");
      assertEquals(
          Json.stringify(c.get("result")),
          outcome(() -> Goals.goalFrom(c.get("input"), "s", existing, 1000, id), id == null),
          "#" + i + " " + Json.stringify(c.get("input")));
    }
  }

  @Test
  void funnelsAreCheckedAsTheTypeScriptSdkChecksThem() {
    Map<String, Object> fixture = Fixtures.load("goals");
    List<Map<String, Object>> existing = Fixtures.cases(fixture, "existingFunnels");
    List<Map<String, Object>> cases = Fixtures.cases(fixture, "funnels");
    for (int i = 0; i < cases.size(); i++) {
      Map<String, Object> c = cases.get(i);
      String id = (String) c.get("id");
      assertEquals(
          Json.stringify(c.get("result")),
          outcome(() -> Funnels.funnelFrom(c.get("input"), "s", existing, 1000, id), id == null),
          "#" + i + " " + Json.stringify(c.get("input")));
    }
  }

  private static Map<String, Object> goal(String id, Object... fields) {
    Map<String, Object> g =
        Json.object(
            "id",
            id,
            "site",
            "s",
            "name",
            id,
            "kind",
            "event",
            "match",
            id,
            "clickBy",
            "",
            "valueMode",
            "none",
            "value",
            0L,
            "valueProp",
            "",
            "currency",
            "USD",
            "createdAt",
            5L);
    for (int i = 0; i < fields.length; i += 2) {
      g.put((String) fields[i], fields[i + 1]);
    }
    return g;
  }

  @Test
  void pagePatternsAndClickRules() {
    Map<String, Object> fixture = Fixtures.load("goals");
    for (Map<String, Object> c : Fixtures.cases(fixture, "patterns")) {
      assertEquals(
          c.get("result"), Goals.pagePattern((String) c.get("input")), (String) c.get("input"));
    }
    Map<String, Object> rules =
        Goals.clickRules(
            List.of(
                Json.object(
                    "id",
                    "s",
                    "name",
                    "S",
                    "hostnames",
                    List.of("www.example.com", "shop.example.com"),
                    "timezone",
                    "UTC"),
                Json.object("id", "t", "name", "T", "hostnames", List.of(), "timezone", "UTC"),
                Json.object(
                    "id", "u", "name", "U", "hostnames", List.of("u.example"), "timezone", "UTC")),
            List.of(
                goal(
                    "c".repeat(24),
                    "name",
                    "Buy",
                    "kind",
                    "click",
                    "match",
                    ".buy",
                    "clickBy",
                    "selector"),
                goal(
                    "d".repeat(24),
                    "name",
                    "Out",
                    "kind",
                    "click",
                    "match",
                    "https://x.example/*",
                    "clickBy",
                    "link",
                    "site",
                    "t"),
                goal("e".repeat(24), "name", "E", "site", "u")));
    assertEquals(Json.stringify(fixture.get("rules")), Json.stringify(rules));
  }

  @Test
  void journeysMatchTheFixture() {
    Map<String, Object> fixture = Fixtures.load("journeys");
    List<Object> datasets = Js.list(fixture.get("datasets"));
    for (Map<String, Object> run : Fixtures.cases(fixture, "runs")) {
      Map<String, Object> options = new java.util.LinkedHashMap<>(Js.map(run.get("options")));
      if ("NaN".equals(options.get("steps"))) {
        options.put("steps", Double.NaN);
      }
      @SuppressWarnings("unchecked")
      List<Map<String, Object>> rows =
          (List<Map<String, Object>>)
              (List<?>) Js.list(datasets.get((int) Js.asLong(run.get("dataset"))));
      assertEquals(
          Json.stringify(run.get("result")),
          Json.stringify(Journeys.journeys(rows, options)),
          Json.stringify(run.get("options")));
    }
  }
}
