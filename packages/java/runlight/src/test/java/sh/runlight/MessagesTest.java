package sh.runlight;

import static org.junit.jupiter.api.Assertions.assertEquals;

import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

/**
 * The translator against fixtures/messages.json: Intl.PluralRules' forms and the TypeScript's
 * words.
 */
class MessagesTest {
  @Test
  void languages() {
    assertEquals(Fixtures.load("messages").get("languages"), Messages.languages());
  }

  @Test
  void pluralFormsMatchIntl() {
    Map<String, Object> fixture = Fixtures.load("messages");
    // NaN and the infinities come as text.
    List<Object> numbers = Js.list(fixture.get("numbers"));
    for (Map.Entry<String, Object> set : Js.map(fixture.get("plural")).entrySet()) {
      List<Object> forms = Js.list(set.getValue());
      for (int i = 0; i < numbers.size(); i++) {
        Object raw = numbers.get(i);
        Number n = raw instanceof String s ? (Number) Js.num(Js.toNumber(s)) : (Number) raw;
        assertEquals(forms.get(i), Messages.plural(set.getKey(), n), set.getKey() + " " + raw);
      }
    }
  }

  @Test
  void wordsMatch() {
    for (Map<String, Object> set : Fixtures.cases(Fixtures.load("messages"), "words")) {
      Messages.Translator words = Messages.translator((String) set.get("lang"));
      assertEquals(set.get("code"), words.lang());
      for (Map<String, Object> c : Fixtures.cases(set, "t")) {
        assertEquals(
            c.get("text"),
            words.t((String) c.get("key"), Js.map(c.get("vars"))),
            set.get("lang") + " " + c.get("key"));
      }
      for (Map<String, Object> c : Fixtures.cases(set, "tn")) {
        Number n = (Number) c.get("n");
        assertEquals(
            c.get("text"),
            words.tn((String) c.get("key"), n, Map.of("n", n, "name", "x")),
            set.get("lang") + " " + c.get("key") + " " + n);
      }
    }
  }

  @Test
  void frenchCountsZeroAsOne() {
    assertEquals("one", Messages.plural("fr", 0L));
    assertEquals("one", Messages.plural("fr", 1.5));
    assertEquals("many", Messages.plural("fr", 1_000_000L));
    assertEquals("other", Messages.plural("en", 0L));
  }
}
