package sh.runlight;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.fail;

import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import sh.runlight.CodedError.LinkError;
import sh.runlight.store.Databases;
import sh.runlight.store.SqlStore;
import sh.runlight.store.Stores;

/**
 * Short links made, changed, removed, and imported through Links, as the PHP port's Core/LinksTest
 * and links.test.ts check them. Following a link (linkHandler, linkDomainResponse) needs the core,
 * so those cases are left to the core's tests.
 */
class LinksTest {
  private static final long NOW = 1_791_297_059_000L;

  static List<String> kinds() {
    return Databases.kinds();
  }

  @AfterEach
  void tearDown() {
    Databases.cleanup();
  }

  private static SqlStore store(String kind) {
    SqlStore store = Databases.fresh(kind);
    store.migrate();
    return store;
  }

  private static Links links(SqlStore store) {
    return new Links(store, store::migrate, () -> NOW);
  }

  private static List<Map<String, Object>> all(SqlStore store) {
    return store.links("default", 0, NOW + 1);
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void aNewLinkGetsARandomSlugAndANameFromItsUrl(String kind) {
    SqlStore store = store(kind);
    Map<String, Object> link =
        links(store)
            .create(
                "default", Json.object("url", "https://thedailypreset.com/presets/golden?ref=x"));
    assertTrue(((String) link.get("slug")).matches("[a-z2-9]{6}"));
    assertEquals("thedailypreset.com/presets/golden", link.get("name"));
    assertEquals("https://thedailypreset.com/presets/golden?ref=x", link.get("url"));
    assertEquals(link.get("id"), store.linkBySlug((String) link.get("slug")).get("id"));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void slugsAreCheckedUniquePerDomainAndFreedByDeleting(String kind) {
    SqlStore store = store(kind);
    Links links = links(store);
    links.create("default", Json.object("url", "https://a.com", "slug", "launch"));
    try {
      links.create("default", Json.object("url", "https://b.com", "slug", "launch"));
      fail("a taken slug");
    } catch (LinkError e) {
      assertTrue(e.getMessage().contains("taken"));
      assertEquals("link_taken", e.code(), "a code the dashboard can translate");
      assertEquals(Map.of("slug", "launch"), e.params());
    }
    List<Object[]> bad =
        List.of(
            new Object[] {Json.object("url", "https://b.com", "slug", "has space"), "link_slug"},
            new Object[] {Json.object("url", "javascript:alert(1)"), "link_protocol"},
            new Object[] {Json.object("url", "not a url"), "link_url"},
            new Object[] {
              Json.object("url", "https://b.com", "domain", "t.unknown.com"), "link_domain"
            });
    for (Object[] c : bad) {
      @SuppressWarnings("unchecked")
      Map<String, Object> input = (Map<String, Object>) c[0];
      LinkError e = assertThrows(LinkError.class, () -> links.create("default", input));
      assertEquals(c[1], e.code());
    }
    String id = (String) all(store).get(0).get("id");
    Map<String, Object> renamed =
        links.update(id, Json.object("slug", "launch-2", "name", "Launch"));
    assertEquals("launch-2", renamed.get("slug"));
    assertEquals("Launch", renamed.get("name"));
    assertEquals("https://a.com/", renamed.get("url"), "a key left out is left alone");
    links.remove(id);
    links.create("default", Json.object("url", "https://c.com", "slug", "launch-2"));
    assertEquals(1, all(store).size(), "a deleted link's slug is free again");
    assertThrows(RangeError.class, () -> links.remove("nope"));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void aSlugIsUniqueAcrossEveryDomain(String kind) {
    SqlStore store = store(kind);
    store.addLinkDomain("t.a.com", "default", NOW);
    Links links = links(store);
    links.create(
        "default", Json.object("url", "https://a.com/sale", "slug", "sale", "domain", "t.a.com"));
    assertThrows(
        LinkError.class,
        () -> links.create("default", Json.object("url", "https://b.com/sale", "slug", "sale")));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void keepingARemovedDomainNeedsNoCheck(String kind) {
    SqlStore store = store(kind);
    store.addLinkDomain("t.a.com", "default", NOW);
    Links links = links(store);
    Map<String, Object> link =
        links.create("default", Json.object("url", "https://a.com/x", "domain", "t.a.com"));
    store.removeLinkDomain("t.a.com");
    Map<String, Object> kept =
        links.update((String) link.get("id"), Json.object("domain", "www.t.a.com", "name", ""));
    assertEquals("t.a.com", kept.get("domain"));
    assertEquals("a.com/x", kept.get("name"), "an empty name is the URL's again");
    LinkError e =
        assertThrows(
            LinkError.class,
            () -> links.update((String) link.get("id"), Json.object("domain", "t.b.com")));
    assertEquals(Map.of("domain", "t.b.com"), e.params());
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void csvRowsInTheUmamiForksFormatImportAndBadRowsSayWhy(String kind) {
    SqlStore store = store(kind);
    store.addLinkDomain("t.thedailypreset.com", "default", NOW);
    Map<String, Object> result =
        links(store)
            .importRows(
                "default",
                List.of(
                    Json.object(
                        "link_name", "Golden hour",
                        "destination_url", "https://thedailypreset.com/golden",
                        "link_slug", "golden",
                        "tracking_domain", "t.thedailypreset.com"),
                    Json.object("name", "Plain", "url", "https://example.com/plain"),
                    Json.object("name", "Broken", "url", "not a url"),
                    Json.object(
                        "name", "Duplicate",
                        "url", "https://example.com/x",
                        "slug", "golden",
                        "domain", "t.thedailypreset.com")));
    assertEquals(2L, result.get("created"));
    List<Object> failed = Js.list(result.get("failed"));
    assertEquals(List.of(3L, 4L), failed.stream().map(f -> Js.map(f).get("row")).toList());
    assertEquals(
        "{\"row\":3,\"reason\":\"The destination must be a full URL, starting with https://\","
            + "\"code\":\"link_url\",\"params\":{}}",
        Json.stringify(failed.get(0)));
    List<Map<String, Object>> made = all(store);
    assertEquals(2, made.size());
    assertTrue(
        made.stream()
            .anyMatch(
                l ->
                    l.get("domain").equals("t.thedailypreset.com")
                        && l.get("slug").equals("golden")));
  }

  @Test
  void aLinkOnAnotherSitesDomainIsRefused() {
    SqlStore store = Stores.sqlite(":memory:");
    store.migrate();
    store.addLinkDomain("go.a.com", "a", 0);
    Links links = links(store);
    assertEquals(
        "go.a.com",
        links
            .create("a", Json.object("url", "https://a.com/x", "domain", "go.a.com"))
            .get("domain"));
    assertThrows(
        LinkError.class,
        () -> links.create("b", Json.object("url", "https://b.com/x", "domain", "go.a.com")));
  }
}
