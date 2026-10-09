package sh.runlight.accounts;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.Map;
import org.junit.jupiter.api.Test;
import sh.runlight.Fixtures;
import sh.runlight.Js;
import sh.runlight.Json;

/**
 * The account pages against tests/fixtures/pages.json, the TypeScript's HTML for the same inputs.
 */
class PagesTest {
  @Test
  void stylesAndScriptMatch() {
    Map<String, Object> fixture = Fixtures.load("pages");
    assertEquals(fixture.get("css"), Pages.AUTH_CSS);
    assertEquals(fixture.get("js"), Pages.AUTH_JS);
  }

  private static String render(String fn, String base, Map<String, Object> opts) {
    return switch (fn) {
      case "loginPage" -> Pages.loginPage(base, opts);
      case "codePage" -> Pages.codePage(base, opts);
      case "invitePage" -> Pages.invitePage(base, opts);
      case "inviteGonePage" -> Pages.inviteGonePage(base);
      case "setupPage" -> Pages.setupPage(base, opts);
      case "setupLockedPage" -> Pages.setupLockedPage(base);
      case "setupNeedsTokenPage" -> Pages.setupNeedsTokenPage(base);
      default -> throw new IllegalArgumentException(fn);
    };
  }

  @Test
  void pagesMatch() {
    Map<String, Object> fixture = Fixtures.load("pages");
    var pages = Fixtures.cases(fixture, "pages");
    assertTrue(pages.size() > 40);
    for (Map<String, Object> c : pages) {
      String fn = (String) c.get("fn");
      String base = (String) c.get("base");
      assertEquals(
          c.get("html"),
          render(fn, base, Js.map(c.get("opts"))),
          fn + " at \"" + base + "\" " + Json.stringify(c.get("opts")));
    }
    for (Map<String, Object> c : Fixtures.cases(fixture, "roles")) {
      assertEquals(c.get("text"), Pages.roleText((String) c.get("role")));
    }
  }

  @Test
  void setupAsksForTheTokenWhenTold() {
    String page = Pages.setupPage("/runlight", Json.object("code", "", "askCode", true));
    assertTrue(page.contains("RUNLIGHT_TOKEN"));
    assertTrue(page.contains("action=\"/runlight/setup\""));
    assertTrue(page.contains("href=\"/runlight/auth.css\""));
    assertTrue(
        Pages.invitePage(
                "", Json.object("code", "c", "email", "a@b.c", "role", "member", "host", "x"))
            .contains("as a member"));
  }
}
