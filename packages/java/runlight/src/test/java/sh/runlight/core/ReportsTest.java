package sh.runlight.core;

import static org.junit.jupiter.api.Assertions.assertEquals;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import sh.runlight.Fixtures;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.Reports;
import sh.runlight.Runlight;
import sh.runlight.http.Headers;
import sh.runlight.http.Request;
import sh.runlight.store.Stores;

/**
 * Email reports rendered from visits the core recorded, replayed from what
 * scripts/php-fixtures-core2.mts had the TypeScript SDK write. Periods and number formats are in
 * sh.runlight.ReportsTest and IntlTest.
 */
class ReportsTest {
  private static final String AGENT =
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36";

  static List<String> cases() {
    List<String> names = new ArrayList<>();
    for (Map<String, Object> c : Fixtures.cases(Fixtures.load("reports"), "cases")) {
      names.add((String) c.get("name"));
    }
    return names;
  }

  @ParameterizedTest
  @MethodSource("cases")
  void reportsRenderAsTheTypeScriptSdkRendersThemInEveryLanguage(String name) {
    Map<String, Object> c = null;
    for (Map<String, Object> each : Fixtures.cases(Fixtures.load("reports"), "cases")) {
      if (name.equals(each.get("name"))) {
        c = each;
      }
    }
    String timezone = (String) c.get("timezone");
    AtomicLong now = new AtomicLong();
    Runlight rl =
        new Runlight(
            new Runlight.Options()
                .store(Stores.sqlite(":memory:"))
                .site(
                    Json.object(
                        "name",
                        "Example & Co",
                        "hostnames",
                        List.of("example.com"),
                        "timezone",
                        timezone))
                .now(now::get));
    rl.init();
    for (Object goal : Js.list(c.get("goals"))) {
      rl.store.saveGoal(Js.map(goal));
    }
    for (Object item : Js.list(c.get("hits"))) {
      Map<String, Object> hit = Js.map(item);
      now.set(Js.asLong(hit.get("at")));
      Headers headers = Headers.of("user-agent", AGENT, "x-forwarded-for", (String) hit.get("ip"));
      if (!"".equals(hit.get("country"))) {
        headers.set("x-vercel-ip-country", (String) hit.get("country"));
      }
      rl.collect(
          new Request(
              "https://example.com/runlight/e", "POST", headers, Json.stringify(hit.get("body"))));
    }
    now.set(Js.asLong(c.get("at")));
    Map<String, Object> site = rl.site("default");
    for (Object item : Js.list(c.get("reports"))) {
      Map<String, Object> expected = Js.map(item);
      String frequency = (String) expected.get("frequency");
      String lang = (String) expected.get("lang");
      String label = name + ", " + lang + " " + frequency;
      Fixtures.assertJson(
          expected.get("period"), Reports.lastPeriod(frequency, now.get(), timezone), label);
      Map<String, Object> report =
          Reports.buildReport(
              rl.store,
              site,
              frequency,
              Js.map(expected.get("period")),
              lang,
              Js.map(expected.get("links")));
      assertEquals(expected.get("subject"), report.get("subject"), label);
      assertEquals(expected.get("text"), report.get("text"), label);
      assertEquals(expected.get("html"), report.get("html"), label);
    }
  }
}
