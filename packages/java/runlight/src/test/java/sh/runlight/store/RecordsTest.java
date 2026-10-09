package sh.runlight.store;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static sh.runlight.Fixtures.assertJson;
import static sh.runlight.store.Seed.row;
import static sh.runlight.store.Seed.rows;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import sh.runlight.Js;
import sh.runlight.Json;

/**
 * Sites, links, shares, tokens, reports, settings, salts, and the live view, at the store, on every
 * database.
 */
class RecordsTest extends StoreTestCase {
  private static long count(SqlStore store, String sql) {
    return Js.asLong(store.db().all(sql).get(0).get("n"));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void sitesAreKeptWithTheirOverridesAndADeletedSitesRecordsGoWithIt(String kind) {
    SqlStore store = store(kind);
    store.upsertSite(
        Json.object(
            "id", "shop",
            "name", "Shop",
            "hostnames", List.of("shop.example.com", "store.example.com"),
            "timezone", "Europe/London"),
        NOW);
    // Unchanged, it is left alone; changed, it is updated, keeping when it was made.
    store.upsertSite(
        Json.object(
            "id", "shop",
            "name", "Shop",
            "hostnames", List.of("shop.example.com", "store.example.com"),
            "timezone", "Europe/London"),
        NOW + 1);
    store.upsertSite(
        Json.object(
            "id", "shop",
            "name", "A shop",
            "hostnames", List.of("shop.example.com"),
            "timezone", "Europe/London"),
        NOW + 2);
    assertJson(
        List.of(
            Json.object(
                "id", "shop",
                "name", "A shop",
                "hostnames", List.of("shop.example.com"),
                "timezone", "Europe/London"),
            Json.object(
                "id", "default",
                "name", "Example",
                "hostnames", List.of("example.com"),
                "timezone", "UTC")),
        store.sites());
    List<Long> created = new ArrayList<>();
    for (Map<String, Object> r :
        store.db().all("SELECT created_at FROM rl_sites WHERE id = 'shop'")) {
      created.add(Js.asLong(r.get("created_at")));
    }
    assertEquals(List.of(NOW), created);
    store.setSiteOverrides("shop", Json.object("name", "Renamed", "timezone", "Asia/Tokyo"));
    store.setSiteOverrides("default", Json.object());
    assertJson(
        Json.object(
            "default", Json.object(),
            "shop", Json.object("name", "Renamed", "timezone", "Asia/Tokyo")),
        new TreeMap<>(store.siteOverrides()));
    assertEquals(
        "{}",
        store
            .db()
            .all("SELECT overrides FROM rl_sites WHERE id = 'default'")
            .get(0)
            .get("overrides"),
        "no overrides is an empty object");

    long t = NOW - HOUR;
    Seed.visit(store, "s1", "v1", t, Map.of(), rows(row("pageview", "/", t, "p1")), "shop");
    Seed.visit(
        store,
        "s2",
        "v2",
        t - 40 * DAY,
        Map.of(),
        rows(row("pageview", "/", t - 40 * DAY, "p2")),
        "shop");
    Seed.visit(store, "s3", "v3", t, Map.of(), rows(row("pageview", "/", t, "p3")));
    store.saveGoal(goal("g1", Json.object("site", "shop", "match", "x")));
    store.insertShare(Json.object("id", "sh", "site", "shop", "name", "", "createdAt", 1L));
    store.addLinkDomain("go.shop.example", "shop", 1);
    store.buildRollupDay("shop", "2026-10-05", NOW - 36 * HOUR, NOW - 12 * HOUR);
    assertJson(t, store.lastSeen("shop"));
    store.deleteSite("shop");
    assertEquals(List.of("default"), column(store.sites(), "id"));
    for (String table :
        List.of(
            "rl_events",
            "rl_sessions",
            "rl_goals",
            "rl_shares",
            "rl_link_domains",
            "rl_rollups",
            "rl_rollup_days")) {
      assertEquals(
          0, count(store, "SELECT COUNT(*) AS n FROM " + table + " WHERE site = 'shop'"), table);
    }
    assertJson(1, store.stats(today()).get("visits"), "the other site keeps its visits");
    assertNull(store.lastSeen("shop"));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void shortLinksAndTheirClicks(String kind) {
    SqlStore store = store(kind);
    String id = "l".repeat(24);
    Map<String, Object> link =
        Json.object(
            "id", id,
            "site", "default",
            "domain", "",
            "slug", "launch",
            "name", "Launch",
            "url", "https://example.com/launch",
            "createdAt", NOW - DAY,
            "updatedAt", NOW - DAY);
    store.insertLink(link);
    assertJson(link, store.linkBySlug("launch"));
    // A slug is unique across every domain while its link lives.
    assertThrows(
        RuntimeException.class,
        () -> store.insertLink(with(link, "id", "m".repeat(24), "domain", "go.example.com")),
        "a second live link with the slug");
    store.updateLink(with(link, "domain", "go.example.com", "name", "Moved", "updatedAt", NOW));
    assertJson(
        List.of("go.example.com", "Moved", NOW),
        List.of(
            store.linkById(id).get("domain"),
            store.linkById(id).get("name"),
            store.linkById(id).get("updatedAt")));
    for (int i = 0; i < 40; i++) {
      long ts = NOW - i * HOUR;
      String session = i % 4 != 0 ? "c" + i : "";
      if (!session.isEmpty()) {
        Seed.visit(
            store,
            session,
            "cv" + (i % 3),
            ts,
            Json.object(
                "source", i % 2 != 0 ? "Twitter" : "Direct", "country", i % 2 != 0 ? "GB" : "US"));
      }
      store.insertEvent(
          Json.object(
              "site",
              "default",
              "ts",
              ts,
              "kind",
              "click",
              "visitor",
              session.isEmpty() ? "" : "cv" + (i % 3),
              "session",
              session,
              "pageview",
              "",
              "path",
              "",
              "hostname",
              "",
              "title",
              "",
              "name",
              "",
              "props",
              null,
              "engagedMs",
              0L,
              "scroll",
              null,
              "link",
              id));
      if (!session.isEmpty()) {
        store.touchSession(session, ts, "click", "");
      }
    }
    List<Map<String, Object>> listed = store.links("default", NOW - 2 * DAY, NOW + 1);
    assertJson(
        List.of(40, 3),
        List.of(listed.get(0).get("clicks"), listed.get(0).get("visitors")),
        "clicks imported as counts add to clicks only");
    List<Map<String, Object>> buckets = new ArrayList<>();
    for (int h = 0; h < 45; h++) {
      buckets.add(
          Json.object("start", NOW - 44 * HOUR + h * HOUR, "end", NOW - 43 * HOUR + h * HOUR));
    }
    List<Map<String, Object>> series = store.linkSeries("default", id, buckets);
    assertEquals(45, series.size(), "more buckets than one statement takes");
    assertEquals(40, sum(series, "clicks"));
    assertJson(
        List.of(
            Json.object("value", "Twitter", "visitors", 3, "events", 20),
            Json.object("value", "Direct", "visitors", 3, "events", 10)),
        store.linkBreakdown("default", id, 0, NOW + 1, "source", 5));
    assertJson(0, store.stats(q(0, NOW + 1)).get("visits"), "a click alone is not a visit");

    store.deleteLink(id, NOW);
    assertNull(store.linkBySlug("launch"));
    assertNull(store.linkById(id));
    assertJson(List.of(), store.links("default", 0, NOW + 1));
    store.insertLink(with(link, "id", "n".repeat(24)));
    assertEquals(
        "n".repeat(24), store.linkBySlug("launch").get("id"), "a deleted link frees its slug");

    store.addLinkDomain("go.example.com", "default", 1);
    store.addLinkDomain("go.example.com", "other", 2);
    store.addLinkDomain("a.example.com", "default", 3);
    assertJson(
        List.of(
            Json.object("domain", "a.example.com", "site", "default"),
            Json.object("domain", "go.example.com", "site", "default")),
        store.linkDomains(),
        "a domain stays with its first site");
    store.removeLinkDomain("go.example.com");
    assertEquals(List.of("a.example.com"), column(store.linkDomains(), "domain"));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void sharesTokensReportsAndSettings(String kind) {
    SqlStore store = store(kind);
    store.insertShare(
        Json.object("id", "s1", "site", "default", "name", "Client", "createdAt", 1L));
    store.insertShare(Json.object("id", "s2", "site", "default", "name", "", "createdAt", 2L));
    store.renameShare("s1", "Renamed");
    assertEquals(List.of("s2", "s1"), column(store.shares("default"), "id"));
    assertJson(
        Json.object("id", "s1", "site", "default", "name", "Renamed", "createdAt", 1),
        store.shareById("s1"));
    store.deleteShare("s1");
    assertNull(store.shareById("s1"));

    Map<String, Object> token =
        Json.object(
            "id", "t1",
            "name", "Script",
            "site", "",
            "scope", "read",
            "hash", "h".repeat(64),
            "hint", "abcd",
            "createdAt", 5L,
            "lastUsedAt", null);
    store.insertToken(token);
    store.insertToken(
        with(
            token,
            "id",
            "t2",
            "site",
            "default",
            "scope",
            "manage",
            "hash",
            "g".repeat(64),
            "createdAt",
            6L));
    store.touchToken("t1", 99);
    assertJson(with(token, "lastUsedAt", 99L), store.tokenByHash("h".repeat(64)));
    assertEquals(List.of("t2", "t1"), column(store.tokens(), "id"));
    assertTrue(store.deleteToken("t1"), "a token that was there");
    assertFalse(store.deleteToken("t1"), "and once it is gone");

    Map<String, Object> report =
        Json.object(
            "id", "r1",
            "site", "default",
            "email", "a@example.com",
            "frequency", "weekly",
            "lang", "en",
            "token", "q".repeat(32),
            "origin", "",
            "lastPeriod", "",
            "lastSentAt", null,
            "createdAt", 7L);
    store.insertReport(report);
    assertTrue(store.claimReport("r1", "w:2026-09-28", 100), "the first claim wins");
    assertFalse(store.claimReport("r1", "w:2026-09-28", 101), "a second, at once, does not");
    assertJson(
        with(report, "lastPeriod", "w:2026-09-28", "lastSentAt", 100L),
        store.reportBy("token", "q".repeat(32)));
    store.releaseReport("r1", "w:2026-09-28", "");
    assertEquals("", store.reportBy("id", "r1").get("lastPeriod"));
    assertEquals(1, store.reports(null).size());
    assertEquals(1, store.reports("default").size());
    assertJson(List.of(), store.reports("elsewhere"));
    store.deleteReport("r1");
    assertNull(store.reportBy("id", "r1"));

    store.setSetting("remote:a", "1");
    store.setSetting("remote:a", "2");
    store.setSetting("remote_b", "3");
    store.setSetting("remote%c", "4");
    store.setSetting("remote\\d", "5");
    assertEquals("2", store.setting("remote:a"));
    assertJson(
        List.of(Json.object("key", "remote:a", "value", "2")),
        store.settingsStartingWith("remote:"));
    assertJson(
        List.of(Json.object("key", "remote_b", "value", "3")),
        store.settingsStartingWith("remote_"),
        "an underscore is taken literally");
    assertJson(
        List.of(Json.object("key", "remote%c", "value", "4")),
        store.settingsStartingWith("remote%"));
    assertJson(
        List.of(Json.object("key", "remote\\d", "value", "5")),
        store.settingsStartingWith("remote\\"),
        "and a backslash, on MySQL too");
    store.setSetting("remote:a", null);
    assertNull(store.setting("remote:a"));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void saltsSessionsAndTheLiveView(String kind) {
    SqlStore store = store(kind);
    assertEquals("first", store.salt("2026-10-06", "first"));
    assertEquals("first", store.salt("2026-10-06", "second"), "two racing callers agree on one");
    store.salt("2026-10-05", "old");
    store.dropSaltsBefore("2026-10-06");
    assertNull(store.saltIfExists("2026-10-05"));
    assertEquals("first", store.saltIfExists("2026-10-06"));

    long t = NOW - 3 * MIN;
    Seed.visit(
        store,
        "s1",
        "v1",
        t - HOUR,
        Json.object("source", "Google", "country", "GB", "city", "London", "device", "Desktop"),
        rows(
            row("pageview", "/", t - HOUR, "old"),
            row("pageview", "/pricing", t, "p1"),
            row("event", "Signup", t + 1000, null)));
    Seed.visit(
        store, "s2", "v2", t, Json.object("country", "US"), rows(row("pageview", "/", t, "p2")));
    assertJson(
        Json.object("id", "s1", "visitor", "v1"),
        store.openSession("default", List.of("v0", "v1"), t - 1));
    assertNull(store.openSession("default", List.of("v1"), t + 2000));
    assertNull(store.openSession("default", List.of(), 0));
    assertJson(
        Json.object(
            "session", "s1",
            "visitor", "v1",
            "path", "/pricing",
            "hostname", "example.com",
            "ts", t,
            "startedAt", t - HOUR,
            "lastAt", t + 1000),
        store.pageview("default", "p1"));
    assertNull(store.pageview("default", "nope"));

    Map<String, Object> live = store.realtime("default", NOW);
    assertJson(2, live.get("visitors"));
    assertJson(
        List.of(
            Json.object("value", "/", "visitors", 1),
            Json.object("value", "/pricing", "visitors", 1)),
        live.get("pages"));
    assertJson(List.of(Json.object("value", "Google", "visitors", 1)), live.get("sources"));
    assertJson(
        List.of(
            Json.object("value", "GB", "visitors", 1), Json.object("value", "US", "visitors", 1)),
        live.get("countries"));
    List<Object> minutes = Js.list(live.get("minutes"));
    assertEquals(30, minutes.size());
    assertJson(2, minutes.get(26));
    List<Object> recent = Js.list(live.get("recent"));
    assertJson(
        Json.object(
            "ts", t + 1000,
            "kind", "event",
            "path", "/pricing",
            "name", "Signup",
            "country", "GB",
            "city", "London",
            "source", "Google",
            "device", "Desktop"),
        recent.get(0));
    assertEquals(3, recent.size());
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void aiAgentFetchesAreTheirOwnRowsOutsideVisits(String kind) {
    SqlStore store = store(kind);
    List<String> agents = List.of("GPTBot", "GPTBot", "ClaudeBot", "ClaudeBot", "Amazonbot");
    for (int i = 0; i < agents.size(); i++) {
      store.insertEvent(
          Json.object(
              "site",
              "default",
              "ts",
              NOW - i * MIN,
              "kind",
              "fetch",
              "visitor",
              "",
              "session",
              "",
              "pageview",
              "",
              "path",
              i % 2 != 0 ? "/a" : "/b",
              "hostname",
              "example.com",
              "title",
              "",
              "name",
              agents.get(i),
              "props",
              Json.object("company", "X", "kind", "crawler"),
              "engagedMs",
              0L,
              "scroll",
              null,
              "link",
              ""));
    }
    assertJson(
        List.of(
            Json.object("value", "ClaudeBot", "visitors", 0, "fetches", 2),
            Json.object("value", "GPTBot", "visitors", 0, "fetches", 2),
            Json.object("value", "Amazonbot", "visitors", 0, "fetches", 1)),
        store.breakdown(today(), "ai_agent", 10, 0));
    assertJson(
        List.of(Json.object("value", "/a", "visitors", 0, "fetches", 2)),
        store.breakdown(today(), "ai_page", 1, 1));
    assertJson(0, store.stats(today()).get("visits"));
    assertEquals(
        "{\"company\":\"X\",\"kind\":\"crawler\"}",
        store
            .db()
            .all("SELECT props FROM rl_events WHERE kind = 'fetch' LIMIT 1")
            .get(0)
            .get("props"));
  }
}
