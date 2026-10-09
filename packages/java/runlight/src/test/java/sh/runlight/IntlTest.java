package sh.runlight;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

/**
 * Intl's numbers, money, dates, and region names as reports.ts writes them, from Node's ICU: the
 * cases scripts/java-intl.mts wrote, and the intl sets of the shared reports.json.
 */
class IntlTest {
  private static Map<String, Object> cases() {
    try (InputStream in = IntlTest.class.getResourceAsStream("intl-cases.json")) {
      return Js.map(Json.parse(new String(in.readAllBytes(), StandardCharsets.UTF_8)));
    } catch (IOException e) {
      throw new UncheckedIOException(e);
    }
  }

  private static String run(Map<String, Object> c) {
    String lang = (String) c.get("lang");
    String kind = (String) c.get("kind");
    Number n = c.get("n") instanceof String s ? (Number) Js.num(Js.toNumber(s)) : null;
    return switch (kind) {
      case "number" -> Intl.number(lang, n);
      case "percent" -> Intl.percent(lang, n);
      case "decimal" -> Intl.number(lang, n, 1, 1);
      case "currency" ->
          Intl.currency(lang, n, (String) c.get("currency"), Js.isInteger(n) ? 0 : 2);
      case "monthYear" -> Intl.monthYear(lang, (String) c.get("date"));
      case "shortDay" -> Intl.shortDay(lang, (String) c.get("date"), false);
      case "shortDayYear" -> Intl.shortDay(lang, (String) c.get("date"), true);
      default -> Intl.region(lang, (String) c.get("code"));
    };
  }

  @Test
  void intlMatchesNode() {
    List<Map<String, Object>> all = Fixtures.cases(cases(), "cases");
    assertTrue(all.size() > 1000);
    List<String> failures = new ArrayList<>();
    for (Map<String, Object> c : all) {
      String out = run(c);
      if (!out.equals(c.get("out"))) {
        failures.add(Fixtures.label(c) + " gave " + out);
      }
    }
    assertEquals(List.of(), failures.subList(0, Math.min(20, failures.size())));
  }

  @Test
  void numbersPercentsDatesCurrenciesAndRegionsMatchTheReportsFixture() {
    for (Map<String, Object> set : Fixtures.cases(Fixtures.load("reports"), "intl")) {
      String lang = (String) set.get("lang");
      for (Object item : Js.list(set.get("number"))) {
        List<Object> c = Js.list(item);
        assertEquals(c.get(1), Intl.number(lang, (Number) c.get(0)), lang + " number " + c);
      }
      for (Object item : Js.list(set.get("decimal"))) {
        List<Object> c = Js.list(item);
        assertEquals(c.get(1), Intl.number(lang, (Number) c.get(0), 1, 1), lang + " decimal " + c);
      }
      for (Object item : Js.list(set.get("percent"))) {
        List<Object> c = Js.list(item);
        assertEquals(c.get(1), Intl.percent(lang, (Number) c.get(0)), lang + " percent " + c);
      }
      for (Object item : Js.list(set.get("monthYear"))) {
        List<Object> c = Js.list(item);
        assertEquals(c.get(1), Intl.monthYear(lang, (String) c.get(0)), lang + " " + c);
      }
      for (Object item : Js.list(set.get("shortDay"))) {
        List<Object> c = Js.list(item);
        assertEquals(c.get(1), Intl.shortDay(lang, (String) c.get(0), false), lang + " " + c);
        assertEquals(c.get(2), Intl.shortDay(lang, (String) c.get(0), true), lang + " " + c);
      }
      for (Object item : Js.list(set.get("currency"))) {
        List<Object> c = Js.list(item);
        Number n = (Number) c.get(0);
        assertEquals(
            c.get(2),
            Intl.currency(lang, n, (String) c.get(1), Js.isInteger(n) ? 0 : 2),
            lang + " " + c);
      }
      for (Object item : Js.list(set.get("region"))) {
        List<Object> c = Js.list(item);
        assertEquals(c.get(1), Intl.region(lang, (String) c.get(0)), lang + " region " + c);
      }
    }
  }
}
