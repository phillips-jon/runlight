package sh.runlight.importers;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.stream.Stream;
import org.junit.jupiter.api.Test;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.Time;

/** Link imports written into the store, as importers.test.ts tests them. */
class ImportStepTest {
  private static final long NOW = 1_791_288_000_000L;

  private record Run(TestHost host, long links, long clicks, long skipped, List<Object> failed) {}

  private static Run runAll(FakeService router, String source, Map<String, String> credentials) {
    TestHost rl = new TestHost(router, NOW);
    String cursor = null;
    double done = 0;
    long links = 0;
    long clicks = 0;
    long skipped = 0;
    List<Object> failed = new ArrayList<>();
    do {
      Map<String, Object> step = Index.importStep(rl, "default", source, credentials, cursor, done);
      cursor = (String) step.get("cursor");
      done = Js.asDouble(step.get("done"));
      links += Js.asLong(step.get("links"));
      clicks += Js.asLong(step.get("clicks"));
      skipped += Js.asLong(step.get("skipped"));
      failed.addAll(Js.list(step.get("failed")));
    } while (cursor != null);
    return new Run(rl, links, clicks, skipped, failed);
  }

  private static List<Map<String, Object>> links(TestHost rl) {
    return rl.store.links("default", 0, NOW + 1);
  }

  private static Map<String, Object> bySlug(TestHost rl, String slug) {
    for (Map<String, Object> l : links(rl)) {
      if (slug.equals(l.get("slug"))) {
        return l;
      }
    }
    return null;
  }

  @Test
  void dubEveryClickWhereThePlanAllows() {
    FakeService router =
        new FakeService()
            .route("api\\.dub\\.co/links\\?.*startingAfter=l2", Json.array())
            .route(
                "api\\.dub\\.co/links\\?",
                Json.array(
                    Json.object(
                        "id",
                        "l1",
                        "domain",
                        "dub.sh",
                        "key",
                        "launch",
                        "url",
                        "https://a.com/launch",
                        "title",
                        "Launch",
                        "createdAt",
                        "2026-01-02T00:00:00Z"),
                    Json.object(
                        "id",
                        "l2",
                        "domain",
                        "go.brand.com",
                        "key",
                        "sale",
                        "url",
                        "https://a.com/sale",
                        "title",
                        null,
                        "createdAt",
                        "2026-02-03T00:00:00Z")))
            .route(
                "/events\\?.*linkId=l1",
                Json.array(
                    Json.object(
                        "timestamp",
                        "2026-03-01T10:00:00Z",
                        "click",
                        Json.object(
                            "id",
                            "c1",
                            "country",
                            "CA",
                            "city",
                            "Toronto",
                            "device",
                            "Mobile",
                            "browser",
                            "Chrome",
                            "os",
                            "iOS",
                            "referer",
                            "instagram.com",
                            "refererUrl",
                            "https://instagram.com/")),
                    Json.object(
                        "timestamp",
                        "2026-03-02T10:00:00Z",
                        "click",
                        Json.object(
                            "id",
                            "c2",
                            "country",
                            "US",
                            "device",
                            "Desktop",
                            "browser",
                            "Safari",
                            "os",
                            "Mac OS",
                            "referer",
                            "(direct)"))))
            .route("/events\\?.*linkId=l2", Json.array());
    Run run = runAll(router, "dub", Map.of("apiKey", "dub_test"));
    assertEquals(2, run.links());
    assertEquals(2, run.clicks());
    TestHost rl = run.host();
    assertEquals(
        "", bySlug(rl, "launch").get("domain"), "dub.sh stays behind; the link moves to /go");
    assertEquals("go.brand.com", bySlug(rl, "sale").get("domain"), "branded domains come across");
    assertEquals(
        Json.stringify(Json.object("domain", "go.brand.com", "site", "default")),
        Json.stringify(rl.store.linkDomains().get(0)));
    assertEquals(1, rl.forgotten);
    Map<String, Object> session =
        rl.store
            .db()
            .all("SELECT country, source, device FROM rl_sessions ORDER BY started_at LIMIT 1")
            .get(0);
    assertEquals(
        List.of("CA", "Instagram", "mobile"),
        List.of(session.get("country"), session.get("source"), session.get("device")));
    assertEquals(
        1L,
        Js.asLong(
            rl.store.db().all("SELECT imported FROM rl_sessions LIMIT 1").get(0).get("imported")));
  }

  @Test
  void dubDailyCountsWhenThePlanHasNoEventsApi() {
    FakeService router =
        new FakeService()
            .route(
                "api\\.dub\\.co/links\\?",
                Json.array(
                    Json.object(
                        "id",
                        "l1",
                        "domain",
                        "dub.sh",
                        "key",
                        "x",
                        "url",
                        "https://a.com",
                        "title",
                        "X",
                        "createdAt",
                        "2026-01-02T00:00:00Z")))
            .route(
                "/events\\?",
                new FakeService.Status(
                    403, Json.object("error", Json.object("message", "Business plan required"))))
            .route(
                "/analytics\\?",
                Json.array(
                    Json.object("start", "2026-03-01T00:00:00.000Z", "clicks", 3L),
                    Json.object("start", "2026-03-02T00:00:00.000Z", "clicks", 0L)));
    Run run = runAll(router, "dub", Map.of("apiKey", "dub_test"));
    assertEquals(3, run.clicks());
    Map<String, Object> row = links(run.host()).get(0);
    assertEquals(3L, row.get("clicks"));
    assertEquals(0L, row.get("visitors"), "daily counts add clicks, not made-up visitors");
    List<Long> times = new ArrayList<>();
    for (Map<String, Object> r :
        run.host().store.db().all("SELECT ts FROM rl_events ORDER BY ts")) {
      times.add(Js.asLong(r.get("ts")));
    }
    long day = Time.utc(2026, 2, 1, 0, 0, 0);
    assertEquals(
        List.of(day + 14_400_000, day + 43_200_000, day + 72_000_000),
        times,
        "spread through the day");
  }

  @Test
  void bitlyEveryGroupCustomBackHalvesDailyCounts() {
    FakeService router =
        new FakeService()
            .route(
                "/v4/groups$",
                Json.object(
                    "groups", Json.array(Json.object("guid", "G1"), Json.object("guid", "G2"))))
            .route(
                "/groups/G1/bitlinks",
                Json.object(
                    "links",
                    Json.array(
                        Json.object(
                            "id",
                            "bit.ly/3abc",
                            "link",
                            "https://bit.ly/3abc",
                            "long_url",
                            "https://a.com/1",
                            "title",
                            "One",
                            "created_at",
                            "2026-01-01T00:00:00+0000",
                            "custom_bitlinks",
                            Json.array("https://t.brand.com/one")),
                        Json.object(
                            "id",
                            "bit.ly/gone",
                            "link",
                            "https://bit.ly/gone",
                            "long_url",
                            "https://a.com/x",
                            "title",
                            "Gone",
                            "created_at",
                            "2026-01-01T00:00:00+0000",
                            "is_deleted",
                            true)),
                    "pagination",
                    Json.object("search_after", "")))
            .route(
                "/groups/G2/bitlinks",
                Json.object(
                    "links",
                    Json.array(
                        Json.object(
                            "id",
                            "bit.ly/4def",
                            "link",
                            "https://bit.ly/4def",
                            "long_url",
                            "https://a.com/2",
                            "title",
                            null,
                            "created_at",
                            "2026-02-01T00:00:00+0000")),
                    "pagination",
                    Json.object()))
            .route(
                "/bitlinks/bit\\.ly%2F3abc/clicks",
                Json.object(
                    "link_clicks",
                    Json.array(
                        Json.object("clicks", 5L, "date", "2026-03-01T00:00:00+0000"),
                        Json.object("clicks", 2L, "date", "2026-03-02T00:00:00+0000"))))
            .route(
                "/bitlinks/bit\\.ly%2F4def/clicks",
                new FakeService.Status(402, Json.object("message", "UPGRADE_REQUIRED")));
    Run run = runAll(router, "bitly", Map.of("token", "bitly_test"));
    assertEquals(2, run.links(), "the deleted link is skipped");
    assertEquals(7, run.clicks());
    List<String> pairs = new ArrayList<>();
    for (Map<String, Object> l : links(run.host())) {
      pairs.add(l.get("domain") + " " + l.get("slug"));
    }
    pairs.sort(Comparator.naturalOrder());
    assertEquals(List.of(" 4def", "t.brand.com one"), pairs);
  }

  @Test
  void shortIoEveryDomainPagedWithDailyCountsInEitherShape() {
    FakeService router =
        new FakeService()
            .route(
                "api\\.short\\.io/api/domains",
                Json.array(Json.object("id", 7L, "hostname", "s.brand.com")))
            .route(
                "api/links\\?.*pageToken=P2",
                Json.object(
                    "links",
                    Json.array(
                        Json.object(
                            "idString",
                            "lnk2",
                            "id",
                            2L,
                            "path",
                            "two",
                            "originalURL",
                            "https://a.com/2",
                            "createdAt",
                            "2026-02-01T00:00:00Z")),
                    "nextPageToken",
                    null))
            .route(
                "api/links\\?domain_id=7",
                Json.object(
                    "links",
                    Json.array(
                        Json.object(
                            "idString",
                            "lnk1",
                            "id",
                            1L,
                            "path",
                            "one",
                            "originalURL",
                            "https://a.com/1",
                            "title",
                            "One",
                            "createdAt",
                            "2026-01-01T00:00:00Z")),
                    "nextPageToken",
                    "P2"))
            .route(
                "statistics/link/lnk1/by_interval",
                Json.object(
                    "clickStatistics",
                    Json.array(Json.object("x", "2026-03-01T00:00:00Z", "y", 4L))))
            .route(
                "statistics/link/lnk2/by_interval",
                Json.object(
                    "clickStatistics",
                    Json.object(
                        "datasets",
                        Json.array(
                            Json.object(
                                "data",
                                Json.array(
                                    Json.object("x", Time.utc(2026, 2, 2, 0, 0, 0), "y", 1L)))))));
    // Short.io's pace of one statistics call a second is kept, so this takes two seconds.
    Run run = runAll(router, "shortio", Map.of("apiKey", "sk_test"));
    assertEquals(2, run.links());
    assertEquals(5, run.clicks());
  }

  @Test
  void rebrandlyLinksOnlyPagedByTheLastId() {
    FakeService router =
        new FakeService()
            .route("/links\\?.*last=r24", page(25, 3))
            .route("rebrandly\\.com/v1/links\\?", page(0, 25));
    Run run = runAll(router, "rebrandly", Map.of("apiKey", "rb_test"));
    assertEquals(28, run.links());
    assertEquals(0, run.clicks());
    assertEquals("", links(run.host()).get(0).get("domain"), "rebrand.ly stays behind");
  }

  private static List<Object> page(int from, int n) {
    List<Object> out = new ArrayList<>();
    for (int i = from; i < from + n; i++) {
      out.add(
          Json.object(
              "id",
              "r" + i,
              "slashtag",
              "s" + i,
              "destination",
              "https://a.com/" + i,
              "domain",
              Json.object("fullName", "rebrand.ly"),
              "createdAt",
              "2026-01-01T00:00:00Z"));
    }
    return out;
  }

  @Test
  void umamiSignsInWithAUsernameAndPasswordAndReRunsSkipWhatIsThere() {
    FakeService router =
        new FakeService()
            .route(
                "/api/auth/login",
                (u, init) ->
                    "pw".equals(Js.get(Json.parse(init.bodyText()), "password"))
                        ? Json.object("token", "tok")
                        : Json.object())
            .route(
                "/api/links\\?",
                Json.object(
                    "data",
                    Json.array(
                        Json.object(
                            "id",
                            "u-1",
                            "name",
                            "Golden",
                            "url",
                            "https://a.com",
                            "slug",
                            "golden",
                            "createdAt",
                            "2026-01-01T00:00:00Z",
                            "deletedAt",
                            null,
                            "customDomain",
                            Json.object("domain", "t.brand.com"))),
                    "count",
                    1L))
            .route(
                "/websites/u-1/events",
                Json.object(
                    "data",
                    Json.array(
                        Json.object(
                            "sessionId",
                            "s1",
                            "createdAt",
                            "2026-03-01T00:00:00Z",
                            "urlPath",
                            "/golden",
                            "urlQuery",
                            "utm_source=newsletter",
                            "referrerDomain",
                            "",
                            "referrerPath",
                            "",
                            "country",
                            "GB",
                            "city",
                            "London",
                            "device",
                            "mobile",
                            "os",
                            "iOS",
                            "browser",
                            "ios")),
                    "count",
                    1L))
            .route(
                "/websites/u-1/sessions",
                Json.object(
                    "data",
                    Json.array(
                        Json.object(
                            "id", "s1", "screen", "390x844", "language", "en-GB", "region", "ENG")),
                    "count",
                    1L));
    TestHost rl = new TestHost(router, NOW);
    Map<String, String> creds =
        Map.of("url", "https://stats.example.com/", "username", "jon", "password", "pw");
    Map<String, Object> first = Index.importStep(rl, "default", "umami", creds, null, 0);
    assertEquals(1L, first.get("links"));
    assertEquals(1L, first.get("clicks"));
    assertTrue(router.calls.get(0).startsWith("POST stats.example.com/api/auth/login"));
    Map<String, Object> s =
        rl.store.db().all("SELECT region, source, browser FROM rl_sessions").get(0);
    assertEquals(
        List.of("GB-ENG", "Newsletter", "Safari"),
        List.of(s.get("region"), s.get("source"), s.get("browser")));
    Map<String, Object> again = Index.importStep(rl, "default", "umami", creds, null, 0);
    assertEquals(1L, again.get("skipped"));
    ImportError bad =
        assertThrows(
            ImportError.class,
            () -> Index.importStep(rl, "default", "umami", Map.of("url", "nope"), null, 0));
    assertTrue(bad.getMessage().contains("Umami address"));
    ImportError unknown =
        assertThrows(
            ImportError.class, () -> Index.importStep(rl, "default", "nowhere", Map.of(), null, 0));
    assertTrue(unknown.getMessage().contains("cannot import"));
    assertEquals(Map.of("source", "nowhere"), unknown.params());
  }

  @Test
  void umamiALinkAlreadyHereWithTheSameSlugAndDestinationIsSkippedBeforeItsHistoryIsFetched() {
    FakeService router =
        new FakeService()
            .route(
                "/api/links\\?",
                Json.object(
                    "data",
                    Json.array(
                        Json.object(
                            "id",
                            "u-9",
                            "name",
                            "Golden",
                            "url",
                            "https://a.com/",
                            "slug",
                            "golden",
                            "createdAt",
                            "2026-01-01T00:00:00Z",
                            "deletedAt",
                            null)),
                    "count",
                    1L))
            .route("/websites/u-9/", Json.object("data", Json.array(), "count", 0L));
    TestHost rl = new TestHost(router, NOW);
    rl.init();
    // Brought in earlier some other way, such as a CSV, so it has no Umami id.
    rl.store.insertLink(
        Json.object(
            "id",
            "own",
            "site",
            "default",
            "domain",
            "",
            "slug",
            "golden",
            "name",
            "Golden",
            "url",
            "https://a.com",
            "createdAt",
            NOW,
            "updatedAt",
            NOW));
    Map<String, Object> step =
        Index.importStep(
            rl,
            "default",
            "umami",
            Map.of("url", "https://stats.example.com/", "apiKey", "k"),
            null,
            0);
    assertEquals(1L, step.get("skipped"));
    assertEquals(0L, step.get("links"));
    for (String call : router.calls) {
      assertTrue(!call.contains("/websites/u-9/"), "no history was fetched for it");
    }
  }

  private static Map<String, Object> umamiLink(int i) {
    return Json.object(
        "id", "u" + i,
        "name", "N" + i,
        "url", "https://a.com/" + i,
        "slug", "s" + i,
        "createdAt", "2026-01-01T00:00:00Z",
        "deletedAt", null);
  }

  @Test
  void umamiALinkListWithoutACountGivesNoTotalAndPagesOnWhilePagesAreFull() {
    List<Object> full = new ArrayList<>();
    for (int i = 0; i < 5; i++) {
      full.add(umamiLink(i));
    }
    FakeService router =
        new FakeService()
            .route("/api/links\\?page=1&", Json.object("data", full))
            .route(
                "/api/links\\?page=2&",
                Json.object("data", Json.array(umamiLink(5)), "count", "six"))
            .route("/websites/", Json.object("data", Json.array(), "count", 0L));
    TestHost rl = new TestHost(router, NOW);
    Map<String, String> creds = Map.of("url", "https://stats.example.com", "apiKey", "k");
    Map<String, Object> first = Index.importStep(rl, "default", "umami", creds, null, 0);
    assertNull(first.get("total"));
    assertNotNull(first.get("cursor"), "a full page may have more after it");
    Map<String, Object> second =
        Index.importStep(
            rl,
            "default",
            "umami",
            creds,
            (String) first.get("cursor"),
            Js.asDouble(first.get("done")));
    assertEquals(
        Json.stringify(Json.array(null, 6L, null)),
        Json.stringify(Json.array(second.get("cursor"), second.get("done"), second.get("total"))));
    Map<String, Object> empty =
        Index.importStep(
            new TestHost(
                new FakeService().route("/api/links\\?", Json.object("data", Json.array())), NOW),
            "default",
            "umami",
            creds,
            null,
            0);
    assertEquals(
        Json.stringify(Json.array(null, 0L, null)),
        Json.stringify(Json.array(empty.get("cursor"), empty.get("done"), empty.get("total"))));
  }

  @Test
  void aLinkWhoseSlugIsTakenOrUnusableIsReportedWithACode() {
    TestHost rl = new TestHost(new FakeService(), NOW);
    rl.init();
    rl.store.insertLink(
        Json.object(
            "id",
            "other",
            "site",
            "default",
            "domain",
            "",
            "slug",
            "taken",
            "name",
            "Other",
            "url",
            "https://elsewhere.com",
            "createdAt",
            NOW,
            "updatedAt",
            NOW));
    Map<String, Object> taken =
        Write.writeLink(
            rl, "default", "dub", foreign("x", "taken", "", "X", "https://a.com"), Json.object());
    assertEquals(
        Json.stringify(
            Json.object(
                "status",
                "failed",
                "clicks",
                0L,
                "reason",
                "/taken is already used by \"Other\"",
                "code",
                "import_slug_taken",
                "params",
                Json.object("slug", "taken", "name", "Other"))),
        Json.stringify(taken));
    Map<String, Object> bad =
        Write.writeLink(
            rl, "default", "dub", foreign("y", "a/b", "", "", "https://a.com"), Json.object());
    assertEquals("import_slug_bad", bad.get("code"));
    Map<String, Object> made =
        Write.writeLink(
            rl,
            "default",
            "dub",
            foreign("z", "fine", "www.Go.Brand.com", "", "https://a.com/z"),
            Json.object(
                "clicks",
                Json.array(
                    Json.object(
                        "ts", 5_000L, "visit", "v", "path", "/fine", "query", "?utm_campaign=c"))));
    assertEquals(
        Json.stringify(Json.object("status", "created", "clicks", 1L)), Json.stringify(made));
    Map<String, Object> link = rl.store.linkBySlug("fine");
    assertEquals(
        List.of("go.brand.com", "fine", Write.importedLinkId("dub", "z")),
        List.of(link.get("domain"), link.get("name"), link.get("id")));
    assertEquals(
        "c", rl.store.db().all("SELECT utm_campaign FROM rl_sessions").get(0).get("utm_campaign"));
    assertEquals(
        Json.stringify(Json.object("status", "skipped", "clicks", 0L)),
        Json.stringify(
            Write.writeLink(
                rl,
                "default",
                "dub",
                foreign("z", "fine", "", "", "https://a.com/z"),
                Json.object())),
        "the same link again");
  }

  private static Map<String, Object> foreign(
      String sourceId, String slug, String domain, String name, String url) {
    return Json.object(
        "sourceId",
        sourceId,
        "slug",
        slug,
        "domain",
        domain,
        "name",
        name,
        "url",
        url,
        "createdAt",
        0L);
  }

  /** Names JavaScript objects carry on their prototype are just names, as edges.test.ts checks. */
  @Test
  void namesLikeObjectPropertiesAreJustNames() {
    TestHost rl = new TestHost(new FakeService(), NOW);
    for (String source : List.of("constructor", "toString", "__proto__", "hasOwnProperty")) {
      ImportError e =
          assertThrows(
              ImportError.class, () -> Index.importStep(rl, "default", source, Map.of(), null, 0));
      assertEquals("import_source", e.code(), source);
    }
    assertEquals(
        List.of("Constructor", "__proto__", "ToString"),
        Stream.of("constructor", "__proto__", "toString").map(Write::browser).toList());
    assertEquals(
        List.of("constructor", "toString"),
        Stream.of("constructor", "toString").map(Write::system).toList());
    assertEquals(List.of("", ""), Stream.of("constructor", "valueOf").map(Write::device).toList());
  }
}
