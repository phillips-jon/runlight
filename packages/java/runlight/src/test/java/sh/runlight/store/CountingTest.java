package sh.runlight.store;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.fail;
import static sh.runlight.Fixtures.assertJson;
import static sh.runlight.store.Seed.row;
import static sh.runlight.store.Seed.rows;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.function.LongFunction;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import sh.runlight.CodedError.FunnelError;
import sh.runlight.Funnels;
import sh.runlight.Goals;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.Sources;

/**
 * What the reports count, at the store: the store-level parts of counting.test.ts, filters.test.ts,
 * goals.test.ts, funnels.test.ts, journeys.test.ts, props.test.ts, and mysql.test.ts. Visits are
 * written through the store as the tracker writes them.
 */
class CountingTest extends StoreTestCase {
  /** The stats numbers asked for. */
  private static List<Object> pick(Map<String, Object> stats, String... keys) {
    List<Object> out = new ArrayList<>();
    for (String k : keys) {
      out.add(stats.get(k));
    }
    return out;
  }

  private static long n(Object value) {
    return Js.asLong(value);
  }

  @SuppressWarnings("unchecked")
  private static List<Map<String, Object>> rowsOf(Object value) {
    return (List<Map<String, Object>>) (List<?>) Js.list(value);
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void goalsFunnelsAndEventPropertiesCountVisitsByWhenTheyStartedWithOrWithoutAFilter(String kind) {
    SqlStore store = store(kind);
    // Two people start at 23:50 on the 5th and sign up at 00:10 on the 6th; a third visits on the
    // 6th.
    long start = NOW - 12 * HOUR - 10 * MIN;
    for (int i : new int[] {1, 2}) {
      Seed.visit(
          store,
          "s" + i,
          "v" + i,
          start,
          Json.object("country", "GB"),
          rows(
              row("pageview", "/signup", start, "p" + i),
              row("event", "Signup", start + 20 * MIN, Json.object("plan", "pro"))));
    }
    Seed.visit(
        store,
        "s3",
        "v3",
        start + 80 * MIN,
        Map.of(),
        rows(row("pageview", "/", start + 80 * MIN, "q")));
    Map<String, Object> goal =
        goal("a".repeat(24), Json.object("name", "Signup", "match", "Signup"));
    store.saveGoal(goal);
    Map<String, Object> funnel =
        Json.object(
            "id",
            "b".repeat(24),
            "site",
            "default",
            "name",
            "Signup",
            "steps",
            List.of(
                Json.object("kind", "page", "match", "/signup"),
                Json.object("kind", "event", "match", "Signup")),
            "createdAt",
            0L);
    store.saveFunnel(funnel);
    long day5 = utc(2026, 10, 5, 0);
    for (String[][] filters :
        new String[][][] {
          {}, {w("country", "not", "ZZ")}, {w("page", "contains", "/")},
        }) {
      LongFunction<List<Object>> read =
          from -> {
            Map<String, Object> query = q(from, from + DAY, filters);
            Map<String, Object> totals = store.goalTotals(query, goal);
            double visitors = Js.toNumber(store.visitors(query));
            List<Object> events = new ArrayList<>();
            for (Map<String, Object> r : store.breakdown(query, "event", 10, 0)) {
              events.add(r.get("value") + ":" + Js.string(r.get("events")));
            }
            return List.of(
                totals.get("conversions"),
                visitors > 0 ? Js.num(Js.toNumber(totals.get("visitors")) / visitors) : 0L,
                store.funnelCounts(query, funnel),
                store.eventPropKeys(query, "Signup").size(),
                events);
          };
      String label = Json.stringify(List.of((Object[]) filters));
      assertJson(
          List.of(2, 1, List.of(2, 2), 1, List.of("Signup:2")),
          read.apply(day5),
          "the visits that started on the 5th " + label);
      assertJson(
          List.of(0, 0, List.of(0, 0), 0, List.of()),
          read.apply(day5 + DAY),
          "nothing that started on the 6th converted " + label);
    }
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void containsFindsCapitalsBeyondAsciiAndTwoPageFiltersCountBothPages(String kind) {
    SqlStore store = store(kind);
    long t = NOW - HOUR;
    Seed.visit(
        store,
        "s1",
        "v1",
        t,
        Json.object("utmCampaign", "Über"),
        rows(row("pageview", "/a", t, "a"), row("pageview", "/b", t + MIN, "b")));
    for (String value : List.of("über", "Über", "ÜBER", "ber")) {
      assertJson(
          1,
          store.stats(today(w("utm_campaign", "contains", value))).get("visits"),
          "contains " + value);
    }
    Map<String, Object> both = store.stats(today(w("page", "is", "/a"), w("page", "is", "/b")));
    assertJson(List.of(1, 2), pick(both, "visits", "pageviews"));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void aPageGoalFunnelOrFilterWrittenInPlainLettersMatchesTheEncodedPath(String kind) {
    SqlStore store = store(kind);
    long t = NOW - HOUR;
    Seed.visit(
        store,
        "s1",
        "v1",
        t,
        Map.of(),
        rows(row("pageview", Sources.recordedPath("/café"), t, "a")));
    Map<String, Object> goal =
        Goals.goalFrom(
            Json.object("name", "Café", "kind", "page", "match", "/café"),
            "default",
            List.of(),
            NOW,
            null);
    store.saveGoal(goal);
    assertJson(1, store.goalTotals(today(), goal).get("conversions"));
    assertJson(1, store.stats(today(w("page", "is", "/café"))).get("visits"));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void anEventThatJoinsAVisitAlreadyEndedCountsWithoutReopeningIt(String kind) {
    SqlStore store = store(kind);
    long t = NOW - 6 * HOUR;
    Seed.visit(store, "s1", "v1", t, Map.of(), rows(row("pageview", "/", t, "p1")));
    store.insertEvent(
        Json.object(
            "site",
            "default",
            "ts",
            t + 2 * HOUR,
            "kind",
            "event",
            "visitor",
            "v1",
            "session",
            "s1",
            "pageview",
            "p1",
            "path",
            "/",
            "hostname",
            "example.com",
            "title",
            "",
            "name",
            "Late",
            "props",
            null,
            "engagedMs",
            0L,
            "scroll",
            null,
            "link",
            ""));
    store.touchSession("s1", t + 2 * HOUR, "event", "/", false);
    assertNull(store.openSession("default", List.of("v1"), t + HOUR), "still ended");
    assertJson(
        List.of(Json.object("value", "Late", "visitors", 1, "events", 1)),
        store.breakdown(today(), "event", 10, 0));
    assertJson(0, store.stats(today()).get("bounceRate"));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void timeOnPageIsOverEveryPageviewCountingQuickOnesAsNone(String kind) {
    SqlStore store = store(kind);
    long t = NOW - HOUR;
    for (int i = 0; i < 4; i++) {
      List<Object[]> rows = new ArrayList<>();
      rows.add(row("pageview", "/a", t, "v" + i));
      if (i == 0) {
        rows.add(row("engagement", "v0", t + 1000, 60_000L, 50L));
      }
      Seed.visit(store, "s" + i, "v" + i, t, Map.of(), rows);
    }
    Map<String, Object> r = store.breakdown(today(), "page", 10, 0).get(0);
    assertJson(List.of(15_000, 50), List.of(r.get("timeOnPage"), r.get("scrollDepth")));
  }

  @Test
  void journeysAppliesAFilterBeforeItsCapOnVisitsAndSaysWhenTheCapWasReached() {
    SqlStore store = store("sqlite");
    long start = utc(2026, 10, 6, 0);
    // Ten visits from Britain early in the day, then more from the US than journeys reads.
    store.transaction(
        tx -> {
          for (int i = 0; i < 10 + SqlStore.JOURNEY_VISITS; i++) {
            long ts = start + i;
            tx.db()
                .run(
                    "INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, entry_path, exit_path, country) VALUES (?, 'default', ?, ?, ?, 1, '/', '/', ?)",
                    List.of("s" + i, "v" + i, ts, ts, i < 10 ? "GB" : "US"));
            tx.db()
                .run(
                    "INSERT INTO rl_events (site, ts, kind, visitor, session, pageview, path, hostname) VALUES ('default', ?, 'pageview', ?, ?, ?, '/', 'example.com')",
                    List.of(ts, "v" + i, "s" + i, "p" + i));
          }
          return null;
        });
    java.util.function.Function<Map<String, Object>, Integer> sessions =
        answer -> new LinkedHashSet<>(column(rowsOf(answer.get("rows")), "session")).size();
    Map<String, Object> britain =
        store.journeyPages(q(start, start + DAY, w("country", "is", "GB")), 5);
    assertEquals(
        10,
        sessions.apply(britain),
        "every British visit, though they are older than the newest visits read");
    assertEquals(false, britain.get("sampled"));
    Map<String, Object> all = store.journeyPages(q(start, start + DAY), 5);
    assertEquals(SqlStore.JOURNEY_VISITS, sessions.apply(all));
    assertEquals(true, all.get("sampled"));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void aPageGoalOrFunnelStepForAHashRouteCountsThatRouteOnly(String kind) {
    SqlStore store = store(kind);
    long t = NOW - HOUR;
    for (int i = 0; i < 5; i++) {
      List<Object[]> rows = new ArrayList<>();
      rows.add(row("pageview", "/", t, "h" + i));
      if (i < 2) {
        rows.add(row("pageview", "/#/cart", t + 1000, "c" + i));
        rows.add(row("pageview", "/#/thanks", t + 2000, "t" + i));
      }
      Seed.visit(store, "s" + i, "v" + i, t, Map.of(), rows);
    }
    Map<String, Object> goal =
        Goals.goalFrom(
            Json.object("name", "Thanks", "kind", "page", "match", "/#/thanks"),
            "default",
            List.of(),
            NOW,
            null);
    Map<String, Object> funnel =
        Funnels.funnelFrom(
            Json.object(
                "name",
                "Checkout",
                "steps",
                List.of(
                    Json.object("kind", "page", "match", "/#/cart"),
                    Json.object("kind", "page", "match", "https://example.com/#/thanks"))),
            "default",
            List.of(),
            NOW,
            null);
    Map<String, Object> totals = store.goalTotals(today(), goal);
    assertJson(
        List.of("/#/thanks", 2, 2),
        List.of(goal.get("match"), totals.get("conversions"), totals.get("visitors")));
    assertJson(List.of("/#/cart", "/#/thanks"), column(rowsOf(funnel.get("steps")), "match"));
    assertJson(List.of(2, 2), store.funnelCounts(today(), funnel));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void pageAndHostnameFiltersTogetherCountPageviewsMatchingBoth(String kind) {
    SqlStore store = store(kind);
    long t = NOW - HOUR;
    Seed.visit(
        store,
        "s1",
        "v1",
        t,
        Map.of(),
        rows(
            row("pageview", "/pricing", t, "a", "example.com"),
            row("pageview", "/start", t + 1000, "b", "docs.example.com"),
            row("pageview", "/pricing", t + 2000, "c", "docs.example.com")));
    Map<String, Object> query =
        today(w("page", "is", "/pricing"), w("hostname", "is", "docs.example.com"));
    assertJson(1, store.stats(query).get("pageviews"));
    List<Object> pages = new ArrayList<>();
    for (Map<String, Object> r : store.breakdown(query, "page", 10, 0)) {
      pages.add(List.of(r.get("value"), r.get("pageviews")));
    }
    assertJson(List.of(List.of("/pricing", 1)), pages);
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void containsIgnoresCaseInAnyMixInPathsTooAndFiltersTakePathsAsTheBrowserWritesThem(String kind) {
    SqlStore store = store(kind);
    long t = NOW - HOUR;
    Seed.visit(
        store,
        "s1",
        "v1",
        t,
        Json.object("utmCampaign", "ÉcoleÉté"),
        rows(row("pageview", Sources.recordedPath("/Über-uns"), t, "a")));
    Seed.visit(
        store,
        "s2",
        "v2",
        t,
        Map.of(),
        rows(row("pageview", Sources.recordedPath("/a^b"), t, "b")));
    Seed.visit(
        store,
        "s3",
        "v3",
        t,
        Map.of(),
        rows(row("pageview", Sources.recordedPath("/#/x{y}"), t, "c")));
    for (String value : List.of("écoleété", "ÉCOLEÉTÉ", "eÉté")) {
      assertJson(1, store.stats(today(w("utm_campaign", "contains", value))).get("visits"), value);
    }
    for (String value : List.of("über", "ÜBER", "Über-Uns")) {
      assertJson(1, store.stats(today(w("page", "contains", value))).get("visits"), value);
    }
    assertJson(1, store.stats(today(w("page", "is", "/a^b"))).get("visits"));
    assertJson(1, store.stats(today(w("page", "is", "/#/x{y}"))).get("visits"));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void timeOnPageLeavesOutImportedViewsWhichCanReportNoTime(String kind) {
    SqlStore store = store(kind);
    // Nine pageviews written as the Umami import writes them: no pageview id, never any engaged
    // time.
    long day = utc(2026, 10, 5, 10);
    for (int i = 0; i < 9; i++) {
      store
          .db()
          .run(
              "INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, entry_path, exit_path, imported) VALUES (?, 'default', ?, ?, ?, 1, '/pricing', '/pricing', 1)",
              List.of("i" + i, "v" + i, day + i, day + i));
      store
          .db()
          .run(
              "INSERT INTO rl_events (site, ts, kind, visitor, session, pageview, path, hostname) VALUES ('default', ?, 'pageview', ?, ?, '', '/pricing', 'example.com')",
              List.of(day + i, "v" + i, "i" + i));
    }
    long t = NOW - HOUR;
    Seed.visit(
        store,
        "live",
        "lv",
        t,
        Map.of(),
        rows(
            row("pageview", "/pricing", t, "live"),
            row("engagement", "live", t + 1000, 60_000L, null)));
    Map<String, Object> week = q(NOW - 7 * DAY, NOW + DAY);
    java.util.function.Supplier<Map<String, Object>> pricing =
        () -> {
          for (Map<String, Object> r : store.breakdown(week, "page", 10, 0)) {
            if ("/pricing".equals(r.get("value"))) {
              return r;
            }
          }
          throw new AssertionError("no /pricing row");
        };
    assertJson(
        List.of(10, 60_000),
        List.of(pricing.get().get("pageviews"), pricing.get().get("timeOnPage")));
    Seed.buildDays(store, "default", NOW - 7 * DAY, NOW + DAY);
    assertJson(60_000, pricing.get().get("timeOnPage"), "the same once the days are built");
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void aFilterPicksVisitsAndTheNumbersDescribeThoseWholeVisits(String kind) {
    SqlStore store = store(kind);
    long t = NOW - 3 * HOUR;
    // Visit A: two pages and a Signup. Visit B: one page, no Signup.
    Seed.visit(
        store,
        "a",
        "va",
        t,
        Map.of(),
        rows(
            row("pageview", "/", t, "a1"),
            row("pageview", "/pricing", t + 30_000, "a2"),
            row("event", "Signup", t + 60_000, null)));
    Seed.visit(
        store, "b", "vb", t + 60_000, Map.of(), rows(row("pageview", "/blog", t + 60_000, "b1")));
    assertJson(
        List.of(1, 1, 2),
        pick(store.stats(today(w("event", "is", "Signup"))), "visitors", "visits", "pageviews"),
        "the visits with a Signup, and all their pageviews");
    assertJson(
        List.of(1, 1),
        pick(store.stats(today(w("page", "is", "/pricing"))), "visits", "pageviews"),
        "a page filter counts that page's views");
    assertJson(
        1,
        store.stats(today(w("page", "is", "/pricing"), w("event", "is", "Signup"))).get("visits"),
        "a page and an event in the same visit");
    assertJson(
        List.of(1, 1),
        pick(store.stats(today(w("event", "not", "Signup"))), "visits", "pageviews"),
        "is not means visits that never had one");

    List<Map<String, Object>> buckets = new ArrayList<>();
    for (int h = 0; h < 24; h++) {
      buckets.add(
          Json.object("start", NOW - 12 * HOUR + h * HOUR, "end", NOW - 11 * HOUR + h * HOUR));
    }
    List<Map<String, Object>> points =
        store.series(
            Json.object("site", "default", "filters", List.of(f("event", "is", "Signup"))),
            buckets);
    assertEquals(
        List.of(1L, 2L),
        List.of(sum(points, "visits"), sum(points, "pageviews")),
        "the chart agrees");
    List<String> pages = new ArrayList<>();
    for (Object v :
        column(store.breakdown(today(w("event", "is", "Signup")), "page", 10, 0), "value")) {
      pages.add((String) v);
    }
    pages.sort(null);
    assertEquals(List.of("/", "/pricing"), pages, "the pages of the visits that signed up");
    assertEquals(
        List.of("Signup"),
        column(store.breakdown(today(w("page", "is", "/pricing")), "event", 10, 0), "value"));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void goalsCountEventsPagePatternsAndRevenueIncludingVisitsFromBeforeTheGoal(String kind) {
    SqlStore store = store(kind);
    long t = NOW - HOUR;
    Seed.visit(
        store,
        "a",
        "v1",
        t,
        Json.object("source", "Google"),
        rows(
            row("pageview", "/pricing", t, "a1"),
            row("event", "Purchase", t + 1, Json.object("revenue", 49L)),
            row("pageview", "/thanks", t + 2, "a2")));
    Seed.visit(
        store,
        "b",
        "v2",
        t,
        Map.of(),
        rows(
            row("pageview", "/pricing", t, "b1"),
            row("event", "Purchase", t + 1, Json.object("revenue", "19.50")),
            row("pageview", "/thanks/pro", t + 2, "b2")));
    Seed.visit(
        store,
        "c",
        "v3",
        t,
        Map.of(),
        rows(
            row("pageview", "/", t, "c1"),
            row("event", "Purchase", t + 1, Json.object("revenue", "not a number"))));

    Map<String, Object> purchase =
        Goals.goalFrom(
            Json.object(
                "name",
                "Purchase",
                "kind",
                "event",
                "match",
                "Purchase",
                "valueMode",
                "prop",
                "valueProp",
                "revenue",
                "currency",
                "usd"),
            "default",
            List.of(),
            NOW,
            null);
    Map<String, Object> thanks =
        Goals.goalFrom(
            Json.object(
                "name",
                "Thank you page",
                "kind",
                "page",
                "match",
                "https://example.com/thanks*",
                "valueMode",
                "fixed",
                "value",
                9.99),
            "default",
            List.of(purchase),
            NOW,
            null);
    Map<String, Object> button =
        Goals.goalFrom(
            Json.object(
                "name", "Buy button", "kind", "click", "clickBy", "selector", "match", ".buy"),
            "default",
            List.of(purchase, thanks),
            NOW,
            null);
    for (Map<String, Object> g : List.of(purchase, thanks, button)) {
      store.saveGoal(g);
    }
    assertJson(3, store.visitors(today()));
    Map<String, Map<String, Object>> all = store.goalTotalsAll(today(), store.goals("default"));
    assertJson(
        Json.object("conversions", 3, "visitors", 3, "revenue", 68.5),
        all.get((String) purchase.get("id")),
        "numbers and numeric strings add up; anything else counts as nothing");
    assertEquals("USD", purchase.get("currency"));
    assertEquals("/thanks*", thanks.get("match"), "a pasted URL keeps only its path");
    Map<String, Object> thanked = all.get((String) thanks.get("id"));
    assertJson(2, thanked.get("conversions"));
    assertEquals(
        19.98,
        Js.toNumber(thanked.get("revenue")),
        1e-9,
        "a decimal fixed value works on every database, Postgres too");
    assertJson(0, all.get((String) button.get("id")).get("conversions"));
    assertJson(thanked, store.goalTotals(today(), thanks));

    List<Object> pages = new ArrayList<>();
    for (Map<String, Object> r : store.goalBreakdown(today(), purchase, "path")) {
      pages.add(List.of(r.get("value"), r.get("conversions")));
    }
    assertJson(List.of(List.of("/pricing", 2), List.of("/", 1)), pages);
    assertJson(68.5, store.goalTotals(today(), purchase).get("revenue"));
    List<Map<String, Object>> series =
        store.goalSeries(
            Json.object("site", "default", "filters", List.of()),
            purchase,
            List.of(
                Json.object("start", NOW - 12 * HOUR, "end", NOW),
                Json.object("start", NOW, "end", NOW + 12 * HOUR)));
    assertEquals(3, sum(series, "conversions"));
    assertJson(
        List.of(List.of("s", ".buy", "Buy button")),
        Goals.clickRules(store.sites(), store.goals(null)).get("default"));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void renamingAClickGoalRenamesItsPastClicks(String kind) {
    SqlStore store = store(kind);
    long t = NOW - HOUR;
    Seed.visit(
        store,
        "a",
        "v1",
        t,
        Map.of(),
        rows(row("pageview", "/", t, "a1"), row("event", "Buy", t + 1, null)));
    Map<String, Object> before =
        goal(
            "c".repeat(24),
            Json.object("name", "Buy", "kind", "click", "clickBy", "selector", "match", ".buy"));
    store.saveGoal(before);
    Map<String, Object> after = with(before, "name", "Buy now");
    store.saveGoal(after, before);
    assertJson(1, store.goalTotals(today(), after).get("conversions"));
    assertEquals("Buy now", store.goalById((String) before.get("id")).get("name"));
    store.deleteGoal((String) before.get("id"));
    assertJson(List.of(), store.goals("default"));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void funnelStepsInTheSameMillisecondBothCountAndOneRowNeverCountsAsTwoSteps(String kind) {
    SqlStore store = store(kind);
    long t = NOW - MIN;
    Seed.visit(
        store,
        "a",
        "v1",
        t,
        Map.of(),
        rows(row("pageview", "/pricing", t, "a1"), row("event", "Signup", t, null)));
    Map<String, Object> same =
        Funnels.funnelFrom(
            Json.object(
                "name",
                "Same moment",
                "steps",
                List.of(
                    Json.object("kind", "page", "match", "/pricing"),
                    Json.object("kind", "event", "match", "Signup"))),
            "default",
            List.of(),
            NOW,
            null);
    Map<String, Object> twice =
        Funnels.funnelFrom(
            Json.object(
                "name",
                "Twice",
                "steps",
                List.of(
                    Json.object("kind", "page", "match", "/pricing"),
                    Json.object("kind", "page", "match", "/pricing"))),
            "default",
            List.of(same),
            NOW,
            null);
    assertJson(List.of(1, 1), store.funnelCounts(today(), same));
    assertJson(List.of(1, 0), store.funnelCounts(today(), twice), "one pageview is not two steps");
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void aFunnelCountsVisitsThatTookEachStepInOrderWithinOneVisit(String kind) {
    SqlStore store = store(kind);
    int[] n = {0};
    java.util.function.Consumer<String[][]> visit =
        steps -> {
          n[0]++;
          long t = NOW - 3 * HOUR + n[0] * 10L * MIN;
          List<Object[]> rows = new ArrayList<>();
          for (int i = 0; i < steps.length; i++) {
            String path = steps[i][0];
            String event = steps[i][1];
            rows.add(
                event == null
                    ? row("pageview", path, t + i * MIN, "p" + n[0] + "x" + i)
                    : row("event", event, t + i * MIN, null, path));
          }
          Seed.visit(store, "s" + n[0], "v" + n[0], t, Map.of(), rows);
        };
    // All three steps in order; two steps, then gone; the right pages in the wrong order; never on
    // pricing.
    visit.accept(new String[][] {{"/pricing", null}, {"/signup", "Signup"}, {"/welcome", null}});
    visit.accept(new String[][] {{"/pricing", null}, {"/signup", "Signup"}});
    visit.accept(new String[][] {{"/welcome", null}, {"/pricing", null}});
    visit.accept(new String[][] {{"/blog", null}, {"/welcome", null}});

    try {
      Funnels.funnelFrom(
          Json.object(
              "name",
              "One step",
              "steps",
              List.of(Json.object("kind", "page", "match", "/pricing"))),
          "default",
          List.of(),
          NOW,
          null);
      fail("one step");
    } catch (FunnelError error) {
      assertEquals("funnel_short", error.code());
    }
    Map<String, Object> funnel =
        Funnels.funnelFrom(
            Json.object(
                "name",
                "Signup",
                "steps",
                List.of(
                    Json.object("kind", "page", "match", "https://example.com/pricing*"),
                    Json.object("kind", "event", "match", "Signup"),
                    Json.object("kind", "page", "match", "welcome"))),
            "default",
            List.of(),
            NOW,
            null);
    assertJson(
        List.of("/pricing*", "Signup", "/welcome"),
        column(rowsOf(funnel.get("steps")), "match"),
        "a pasted URL keeps its path; a bare path gains its slash");
    store.saveFunnel(funnel);
    assertJson(List.of(3, 2, 1), store.funnelCounts(today(), store.funnels("default").get(0)));
    // Filters choose which visits enter. The Signup events were sent from /signup, so a page
    // filter finds them.
    assertJson(List.of(2, 2, 1), store.funnelCounts(today(w("page", "is", "/signup")), funnel));
    Map<String, Object> changed =
        Funnels.funnelFrom(
            Json.object(
                "name",
                "Signup flow",
                "steps",
                List.of(
                    Json.object("kind", "page", "match", "/pricing"),
                    Json.object("kind", "page", "match", "/welcome"))),
            "default",
            List.of(funnel),
            NOW + 1,
            (String) funnel.get("id"));
    assertJson(funnel.get("createdAt"), changed.get("createdAt"));
    store.saveFunnel(changed);
    assertJson(List.of(3, 1), store.funnelCounts(today(), store.funnels("default").get(0)));
    store.deleteFunnel((String) funnel.get("id"));
    assertJson(List.of(), store.funnels("default"));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void journeyPagesReadsEachVisitsPagesInOrder(String kind) {
    SqlStore store = store(kind);
    long t = NOW - HOUR;
    List<List<String>> visits =
        List.of(
            List.of("/", "/pricing", "/signup"),
            List.of("/", "/pricing", "/pricing", "/about"),
            List.of("/blog"));
    for (int i = 0; i < visits.size(); i++) {
      List<Object[]> rows = new ArrayList<>();
      for (int j = 0; j < visits.get(i).size(); j++) {
        rows.add(
            row("pageview", visits.get(i).get(j), t + i * MIN + j * 10_000L, "p" + i + "x" + j));
      }
      Seed.visit(store, "s" + i, "v" + i, t + i * MIN, Map.of(), rows);
    }
    Map<String, Object> answer = store.journeyPages(today(), 3);
    assertEquals(false, answer.get("sampled"));
    assertJson(
        List.of(
            Json.object("session", "s0", "path", "/"),
            Json.object("session", "s0", "path", "/pricing"),
            Json.object("session", "s0", "path", "/signup"),
            Json.object("session", "s1", "path", "/"),
            Json.object("session", "s1", "path", "/pricing"),
            Json.object("session", "s1", "path", "/about"),
            Json.object("session", "s2", "path", "/blog")),
        answer.get("rows"),
        "a refresh is not a step");
    assertJson(Json.object("rows", List.of(), "sampled", false), store.journeyPages(q(0, 1), 3));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void anEventsPropertiesAndTheirValuesFilteredLikeEverythingElse(String kind) {
    SqlStore store = store(kind);
    long t = NOW - HOUR;
    Seed.visit(
        store,
        "a",
        "v1",
        t,
        Map.of(),
        rows(
            row("pageview", "/", t, "a1"),
            row("event", "Outbound link", t + 1, Json.object("url", "https://github.com/x")),
            row(
                "event",
                "Outbound link",
                t + 2,
                Json.object("url", "https://news.ycombinator.com/")),
            row("event", "Signup", t + 3, Json.object("plan", "pro", "seats", 3L)),
            row("event", "Signup", t + 4, Json.object("plan", "team")),
            row("event", "404", t + 5, Json.object("path", "/missing"))));
    Seed.visit(
        store,
        "b",
        "v2",
        t,
        Map.of(),
        rows(
            row("pageview", "/blog", t, "b1"),
            row(
                "event",
                "Outbound link",
                t + 1,
                Json.object("url", "https://github.com/x"),
                "/blog")));

    assertJson(
        List.of(Json.object("key", "url", "events", 3)),
        store.eventPropKeys(today(), "Outbound link"));
    assertJson(
        List.of(
            Json.object("value", "https://github.com/x", "events", 2, "visitors", 2),
            Json.object("value", "https://news.ycombinator.com/", "events", 1, "visitors", 1)),
        store.eventPropValues(today(), "Outbound link", "url", 10));
    assertJson(List.of("plan", "seats"), column(store.eventPropKeys(today(), "Signup"), "key"));
    assertJson(
        List.of(Json.object("value", "3", "events", 1, "visitors", 1)),
        store.eventPropValues(today(), "Signup", "seats", 10));
    assertJson(
        List.of("https://github.com/x"),
        column(
            store.eventPropValues(today(w("page", "is", "/blog")), "Outbound link", "url", 10),
            "value"));
    assertJson(List.of(), store.eventPropKeys(today(), "Nothing"));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void theLongestValuesTheTrackerAcceptsAreKeptWhole(String kind) {
    SqlStore store = store(kind);
    long t = NOW - 3 * HOUR;
    String path = "/" + "p".repeat(999);
    Seed.visit(
        store,
        "a",
        "v1",
        t,
        Json.object(
            "referrerHost", "r".repeat(60) + ".example.org",
            "referrerPath", "/" + "q".repeat(499),
            "utmSource", "s".repeat(200),
            "utmMedium", "m".repeat(200),
            "utmCampaign", "c".repeat(200),
            "utmTerm", "t".repeat(200),
            "utmContent", "o".repeat(200)),
        rows(row("pageview", path, t, "a1")));
    Map<String, Object> props = new java.util.LinkedHashMap<>();
    for (int i = 0; i < 8; i++) {
      props.put(i + "k".repeat(59), "v".repeat(500));
    }
    store.insertEvent(
        Json.object(
            "site",
            "default",
            "ts",
            t + 1,
            "kind",
            "pageview",
            "visitor",
            "v1",
            "session",
            "a",
            "pageview",
            "a2",
            "path",
            "/x",
            "hostname",
            "example.com",
            "title",
            "t".repeat(500),
            "name",
            "",
            "props",
            null,
            "engagedMs",
            0L,
            "scroll",
            null,
            "link",
            ""));
    Seed.visit(
        store,
        "b",
        "v2",
        t,
        Map.of(),
        rows(row("pageview", "/", t, "b1"), row("event", "n".repeat(120), t + 1, props)));

    assertTrue(column(store.breakdown(today(), "page", 10, 0), "value").contains(path));
    Map<String, String> utm =
        Json.object(
                "utm_source",
                "s",
                "utm_medium",
                "m",
                "utm_campaign",
                "c",
                "utm_term",
                "t",
                "utm_content",
                "o")
            .entrySet()
            .stream()
            .collect(
                java.util.stream.Collectors.toMap(
                    Map.Entry::getKey,
                    e -> (String) e.getValue(),
                    (a, b) -> a,
                    java.util.LinkedHashMap::new));
    for (Map.Entry<String, String> e : utm.entrySet()) {
      assertEquals(
          List.of(e.getValue().repeat(200)),
          column(store.breakdown(today(), e.getKey(), 10, 0), "value"));
    }
    assertEquals("n".repeat(120), store.breakdown(today(), "event", 10, 0).get(0).get("value"));
    assertEquals(8, store.eventPropKeys(today(), "n".repeat(120)).size());
    assertEquals(
        List.of("v".repeat(500)),
        column(store.eventPropValues(today(), "n".repeat(120), "0" + "k".repeat(59), 10), "value"));
    // A day of them adds up the same way.
    Seed.buildDays(store, "default", NOW - DAY, NOW + 12 * HOUR);
    assertTrue(
        column(store.breakdown(q(NOW - 7 * DAY, NOW + DAY), "page", 10, 0), "value")
            .contains(path));
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void textIsComparedExactlyAndSortedByCodePointCaseAndTrailingSpacesIncluded(String kind) {
    SqlStore store = store(kind);
    List<String> values = List.of("a", "a ", "A", "b", "é", "É", "😀", "�", "a\t");
    long t = NOW - HOUR;
    for (int i = 0; i < values.size(); i++) {
      Seed.visit(
          store,
          "s" + i,
          "v" + i,
          t,
          Json.object("utmCampaign", values.get(i)),
          rows(
              row("pageview", "/", t, "x" + i),
              row("event", "Pick", t + 1, Json.object("choice", values.get(i)))));
    }
    List<String> sorted = new ArrayList<>(values);
    sorted.sort(Sql::codeOrder);
    List<Map<String, Object>> found = store.eventPropValues(today(), "Pick", "choice", 20);
    assertEquals(sorted, column(found, "value"));
    assertEquals(
        java.util.Collections.nCopies(values.size(), 1L),
        column(found, "events"),
        "no two values counted as one");
    assertEquals(sorted, column(store.breakdown(today(), "utm_campaign", 20, 0), "value"));
    assertJson(
        1,
        store.stats(today(w("utm_campaign", "is", "a "))).get("visits"),
        "a trailing space is part of the value");
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void shortLinkClicksAreNotVisitsInTheHeatmapRawOrRolledUpNorTheFirstVisit(String kind) {
    SqlStore store = store(kind);
    long day = utc(2026, 10, 5, 15);
    // A session opened only by a short link click, then a real visit.
    store
        .db()
        .run(
            "INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, events, imported) VALUES ('s1', 'default', 'v1', ?, ?, 0, 0, 0)",
            List.of(day - HOUR, day - HOUR));
    store
        .db()
        .run(
            "INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, events, imported) VALUES ('s2', 'default', 'v2', ?, ?, 1, 0, 0)",
            List.of(day, day));
    assertJson(day, store.firstOwnVisit("default"));
    assertJson(day - HOUR, store.firstSeen("default"));
    Map<String, Object> query = q(utc(2026, 10, 1, 0), utc(2026, 10, 7, 0));
    assertEquals(1, sum(store.hourly(query), "visits"), "raw");
    Seed.buildDays(store, "default", n(query.get("from")), n(query.get("to")));
    assertEquals(1, sum(store.hourly(query), "visits"), "rolled up");
  }
}
