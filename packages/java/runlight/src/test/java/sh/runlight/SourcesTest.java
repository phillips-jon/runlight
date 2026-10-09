package sh.runlight;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static sh.runlight.Fixtures.assertJson;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;
import org.junit.jupiter.api.Test;
import sh.runlight.http.Url;

/** The TypeScript SDK's sources tests, then the fixture written from it. */
class SourcesTest {
  private static Map<String, Object> visit(String url, String referrer, List<String> internal) {
    return Sources.attribute(Sources.parsePage(new Url(url)), referrer, internal);
  }

  private static Map<String, Object> visit(String url, String referrer) {
    return visit(url, referrer, List.of());
  }

  @Test
  void noReferrerAndNoTagsIsDirect() {
    assertJson(
        Json.object("referrerHost", "", "referrerPath", "", "source", "", "channel", "Direct"),
        visit("https://example.com/", ""));
  }

  @Test
  void searchEnginesAreOrganicSearchByTheMostSpecificHost() {
    assertEquals(
        "Organic Search",
        visit("https://example.com/", "https://www.google.co.uk/").get("channel"));
    assertEquals(
        "Google", visit("https://example.com/", "https://www.google.co.uk/").get("source"));
    assertEquals("Gmail", Sources.sourceForHost("mail.google.com").get("name"));
    assertEquals("Gemini", Sources.sourceForHost("gemini.google.com").get("name"));
  }

  @Test
  void aClickIdOnASearchReferrerIsPaidSearch() {
    assertEquals(
        "Paid Search",
        visit("https://example.com/?gclid=abc", "https://www.google.com/").get("channel"));
    assertEquals(
        "Paid Search",
        visit("https://example.com/?utm_source=google&utm_medium=cpc", "").get("channel"));
  }

  @Test
  void onlyThePathAndCampaignParametersAreKeptFromAUrl() {
    Map<String, Object> page =
        Sources.parsePage(
            new Url("https://www.example.com/a/b?email=x@y.z&utm_campaign=spring&fbclid=123#top"));
    assertEquals("example.com", page.get("hostname"));
    assertEquals("/a/b#top", page.get("path"));
    assertEquals("spring", Js.map(page.get("utm")).get("campaign"));
    assertEquals(true, page.get("paid"));
    assertFalse(Json.stringify(page).contains("x@y.z"));
    assertFalse(Json.stringify(page).contains("123"));
  }

  @Test
  void appReferrersEmailClickTrackersAndWebmailAreNamed() {
    assertEquals(
        "Gmail",
        visit("https://example.com/", "android-app://com.google.android.gm/").get("source"));
    assertEquals(
        "Kit",
        visit("https://example.com/", "https://15a992bb.click.convertkit-mail4.com/x")
            .get("source"));
    assertEquals("Email", visit("https://example.com/", "https://mail.aol.com/").get("channel"));
    assertEquals("Referral", visit("https://example.com/", "https://mailbox.org/").get("channel"));
  }

  @Test
  void hostsAndAliases() {
    Map<String, Object> fixture = Fixtures.load("sources");
    for (Map<String, Object> c : Fixtures.cases(fixture, "hosts")) {
      assertJson(
          c.get("source"), Sources.sourceForHost((String) c.get("host")), (String) c.get("host"));
    }
    for (Map<String, Object> c : Fixtures.cases(fixture, "aliases")) {
      assertJson(
          c.get("source"),
          Sources.sourceForAlias((String) c.get("alias")),
          (String) c.get("alias"));
    }
    for (Map<String, Object> c : Fixtures.cases(fixture, "stripWww")) {
      assertEquals(c.get("host"), Sources.stripWww((String) c.get("input")));
    }
  }

  @Test
  void pages() {
    for (Map<String, Object> c : Fixtures.cases(Fixtures.load("sources"), "pages")) {
      Url url = Url.parse((String) c.get("url"));
      assertJson(c.get("page"), url == null ? null : Sources.parsePage(url), (String) c.get("url"));
    }
  }

  @Test
  void visits() {
    List<Map<String, Object>> cases = Fixtures.cases(Fixtures.load("sources"), "visits");
    List<String> failures = new ArrayList<>();
    for (Map<String, Object> c : cases) {
      List<String> internal = new ArrayList<>();
      for (Object host : Js.list(c.get("internal"))) {
        internal.add((String) host);
      }
      Map<String, Object> got = visit((String) c.get("url"), (String) c.get("referrer"), internal);
      if (!Json.stringify(Fixtures.stored(got)).equals(Json.stringify(c.get("attribution")))) {
        failures.add(Fixtures.label(c) + " gave " + Fixtures.label(got));
      }
    }
    assertTrue(cases.size() > 300);
    assertEquals(List.of(), failures.subList(0, Math.min(20, failures.size())));
  }

  private static final Pattern UNASSIGNED = Pattern.compile("\\p{Cn}");

  @Test
  void recordedAndReadablePaths() {
    Map<String, Object> fixture = Fixtures.load("sources");
    for (Map<String, Object> c : Fixtures.cases(fixture, "recordedPaths")) {
      assertEquals(
          c.get("path"), Sources.recordedPath((String) c.get("input")), (String) c.get("input"));
    }
    for (Map<String, Object> c : Fixtures.cases(fixture, "readablePaths")) {
      String readable = Sources.readablePath((String) c.get("input"));
      String decoded = Js.decodeURIComponent((String) c.get("path"));
      // A character newer than this JDK's Unicode tables reads as unassigned, so it stays encoded
      // where Node, with newer tables, shows it.
      if (!readable.equals(c.get("path"))
          && decoded != null
          && UNASSIGNED.matcher(decoded).find()) {
        continue;
      }
      assertEquals(c.get("path"), readable, (String) c.get("input"));
    }
  }
}
