package sh.runlight.importers;

import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;
import sh.runlight.Hash;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.Sources;
import sh.runlight.http.Url;
import sh.runlight.store.SqlStore;

/**
 * Writing an imported link and its history, and the names other tools use, in Runlight's spelling.
 */
public final class Write {
  private Write() {}

  /** Domains run by the shorteners themselves. Links there stay on Runlight's own path. */
  private static final Set<String> SHORTENER_DOMAINS =
      Set.of(
          "bit.ly",
          "bitly.com",
          "j.mp",
          "dub.sh",
          "dub.co",
          "dub.link",
          "short.gy",
          "rebrand.ly",
          "rebrandly.com",
          "rb.gy");

  // Browser and system names as other tools write them, in Runlight's spelling.
  public static final Map<String, String> BROWSERS =
      Map.ofEntries(
          Map.entry("chrome", "Chrome"),
          Map.entry("crios", "Chrome"),
          Map.entry("chromium-webview", "Android WebView"),
          Map.entry("chrome webview", "Android WebView"),
          Map.entry("safari", "Safari"),
          Map.entry("ios", "Safari"),
          Map.entry("ios-webview", "Safari"),
          Map.entry("mobile safari", "Safari"),
          Map.entry("firefox", "Firefox"),
          Map.entry("fxios", "Firefox"),
          Map.entry("edge", "Edge"),
          Map.entry("edge-chromium", "Edge"),
          Map.entry("edge-ios", "Edge"),
          Map.entry("microsoft edge", "Edge"),
          Map.entry("opera", "Opera"),
          Map.entry("opera-mini", "Opera"),
          Map.entry("samsung", "Samsung Internet"),
          Map.entry("samsung internet", "Samsung Internet"),
          Map.entry("yandexbrowser", "Yandex Browser"),
          Map.entry("facebook", "Facebook"),
          Map.entry("instagram", "Instagram"),
          Map.entry("brave", "Brave"),
          Map.entry("duckduckgo", "DuckDuckGo"));

  public static final Map<String, String> SYSTEMS =
      Map.ofEntries(
          Map.entry("mac os", "macOS"),
          Map.entry("mac os x", "macOS"),
          Map.entry("macos", "macOS"),
          Map.entry("ios", "iOS"),
          Map.entry("android os", "Android"),
          Map.entry("android", "Android"),
          Map.entry("windows 10", "Windows"),
          Map.entry("windows 11", "Windows"),
          Map.entry("windows 7", "Windows"),
          Map.entry("windows", "Windows"),
          Map.entry("linux", "Linux"),
          Map.entry("chrome os", "Chrome OS"),
          Map.entry("chromium os", "Chrome OS"));

  public static final Map<String, String> DEVICES =
      Map.of(
          "desktop", "desktop",
          "laptop", "desktop",
          "mobile", "mobile",
          "smartphone", "mobile",
          "phone", "mobile",
          "tablet", "tablet");

  private static final Pattern SLUG = Pattern.compile("^[A-Za-z0-9][A-Za-z0-9_-]{0,99}\\z");
  private static final Pattern COUNTRY = Pattern.compile("^[A-Z]{2}\\z");

  public static String hexId(String value) {
    return hexId(value, 24);
  }

  public static String hexId(String value, int length) {
    return Hash.sha256(value).substring(0, length);
  }

  /** The Runlight id an imported link gets, from its source and its id there. */
  public static String importedLinkId(String source, String sourceId) {
    return hexId(source + ":" + sourceId);
  }

  /** Two destinations are the same link when they differ only by a trailing slash. */
  public static boolean sameUrl(String a, String b) {
    return trimSlash(a).equals(trimSlash(b));
  }

  private static String trimSlash(String value) {
    return value.endsWith("/") ? value.substring(0, value.length() - 1) : value;
  }

  /** The first letter in upper case, as TS's title() does. */
  public static String title(String v) {
    return v.isEmpty() ? "" : Js.upper(Js.slice(v, 0, 1)) + Js.slice(v, 1);
  }

  /**
   * A browser name in Runlight's spelling: a known one, or the name with a capital first letter.
   */
  public static String browser(String name) {
    String known = BROWSERS.get(Js.lower(name));
    return known != null ? known : title(name);
  }

  /** A system name in Runlight's spelling, or the name as given. */
  public static String system(String name) {
    String known = SYSTEMS.get(Js.lower(name));
    return known != null ? known : name;
  }

  public static String device(String name) {
    String known = DEVICES.get(Js.lower(name));
    return known != null ? known : "";
  }

  /** A field of a foreign click as text, "" where it is missing, as `c.field || ""` reads it. */
  private static String str(Map<String, Object> c, String key) {
    Object value = c.get(key);
    return Js.truthy(value) ? Js.string(value) : "";
  }

  /** A field as `c.field ?? ""` reads it, as text. */
  private static String nullish(Map<String, Object> c, String key) {
    Object value = c.get(key);
    return value == null || value == Json.UNDEFINED ? "" : Js.string(value);
  }

  /** Why a link was or was not written. */
  private static Map<String, Object> result(String status) {
    return Json.object("status", status, "clicks", 0L);
  }

  /**
   * Writes one link and its history in a single transaction: the link (and its branded domain),
   * then each click as a visit like a live one, or daily counts as clicks without visitors. Ids
   * come from the source's own ids, so importing again skips what is already there.
   *
   * @param foreign a ForeignLink
   * @param history {@code clicks} (ForeignClicks) and {@code daily} (DailyClicks), each optional
   * @return {@code status} ("created", "skipped", or "failed"), {@code clicks}, and for a failure
   *     {@code reason}, {@code code}, and {@code params}
   */
  public static Map<String, Object> writeLink(
      Host runlight,
      String site,
      String source,
      Map<String, Object> foreign,
      Map<String, Object> history) {
    String sourceId = Js.string(foreign.get("sourceId"));
    String id = importedLinkId(source, sourceId);
    SqlStore main = runlight.store();
    if (main.linkById(id) != null) {
      return result("skipped");
    }
    String slug = Js.string(foreign.get("slug"));
    String url = Js.string(foreign.get("url"));
    Map<String, Object> taken = main.linkBySlug(slug);
    // The same slug to the same place is this link, brought in earlier some other way.
    if (taken != null && sameUrl((String) taken.get("url"), url)) {
      return result("skipped");
    }
    if (taken != null) {
      Map<String, Object> failed = result("failed");
      failed.put("reason", "/" + slug + " is already used by \"" + taken.get("name") + "\"");
      failed.put("code", "import_slug_taken");
      failed.put("params", Json.object("slug", slug, "name", taken.get("name")));
      return failed;
    }
    if (!SLUG.matcher(slug).find()) {
      Map<String, Object> failed = result("failed");
      failed.put("reason", "/" + slug + " has characters Runlight slugs cannot use");
      failed.put("code", "import_slug_bad");
      failed.put("params", Json.object("slug", slug));
      return failed;
    }

    String domain = Sources.stripWww(str(foreign, "domain"));
    if (SHORTENER_DOMAINS.contains(domain)) {
      domain = "";
    }
    String linkDomain = domain;
    long now = runlight.now();
    long[] clicks = {0};
    // Nothing in the transaction is one link's own problem (those are checked above),
    // so a failure in it is the database's, and it stops the import rather than marking the link.
    main.transaction(
        store -> {
          // On a database without transactions (D1), a failed earlier try can have left
          // some of this link's clicks behind. Clear them, then write the link row last,
          // so a link only counts as imported once all of its history is in.
          store
              .db()
              .run(
                  "DELETE FROM rl_sessions WHERE id IN (SELECT DISTINCT session FROM rl_events WHERE link = ? AND session <> '')",
                  List.of(id));
          store.db().run("DELETE FROM rl_events WHERE link = ?", List.of(id));

          Set<String> made = new HashSet<>();
          List<Object> clickList = Js.list(history.get("clicks"));
          for (Object item : clickList == null ? List.of() : clickList) {
            Map<String, Object> c = Js.map(item);
            if (!Js.isFinite(c.get("ts"))) {
              continue;
            }
            long ts = Js.asLong(c.get("ts"));
            Object visit = c.get("visit");
            String visitKey =
                visit == null || visit == Json.UNDEFINED ? ts + ":" + clicks[0] : Js.string(visit);
            String session = hexId(source + ":" + sourceId + ":" + visitKey);
            // A visitor id lasts one day at most, as every other visitor id does.
            String visitor =
                hexId(source + ":" + visitKey + ":" + Http.isoString(ts).substring(0, 10), 16);
            String path = str(c, "path");
            if (made.add(session)) {
              store.db().run("DELETE FROM rl_sessions WHERE id = ?", List.of(session));
              String host = !linkDomain.isEmpty() ? linkDomain : "link.invalid";
              String query = str(c, "query");
              Url parsed =
                  Url.parse(
                      "https://"
                          + host
                          + (!path.isEmpty() ? path : "/" + slug)
                          + (!query.isEmpty() ? "?" + query.replaceFirst("^\\?", "") : ""));
              Map<String, Object> page =
                  Sources.parsePage(
                      parsed != null ? parsed : new Url("https://" + host + "/" + slug));
              String country = Js.slice(Js.upper(str(c, "country")), 0, 2);
              String rawRegion = str(c, "region");
              String region =
                  !rawRegion.isEmpty()
                      ? Js.slice(
                          Js.upper(rawRegion.contains("-") ? rawRegion : country + "-" + rawRegion),
                          0,
                          10)
                      : "";
              Map<String, Object> utm = Js.map(page.get("utm"));
              Map<String, Object> row =
                  Json.object(
                      "id", session,
                      "site", site,
                      "visitor", visitor,
                      "startedAt", ts,
                      "hostname", page.get("hostname"));
              row.putAll(Sources.attribute(page, nullish(c, "referrer"), List.of()));
              row.put("utmSource", utm.get("source"));
              row.put("utmMedium", utm.get("medium"));
              row.put("utmCampaign", utm.get("campaign"));
              row.put("utmTerm", utm.get("term"));
              row.put("utmContent", utm.get("content"));
              row.put("country", COUNTRY.matcher(country).find() ? country : "");
              row.put("region", !country.isEmpty() ? region : "");
              row.put("city", Js.slice(str(c, "city"), 0, 100));
              row.put("browser", browser(str(c, "browser")));
              row.put("browserVersion", "");
              row.put("os", system(str(c, "os")));
              row.put("osVersion", "");
              row.put("device", device(str(c, "device")));
              row.put("screen", nullish(c, "screen"));
              row.put("language", nullish(c, "language"));
              store.insertSession(row);
              store.db().run("UPDATE rl_sessions SET imported = 1 WHERE id = ?", List.of(session));
            }
            String clickPath = !path.isEmpty() ? path : "/" + slug;
            store.touchSession(session, ts, "click", clickPath);
            store.insertEvent(
                event(
                    site,
                    ts,
                    visitor,
                    session,
                    Js.slice(clickPath, 0, 1000),
                    linkDomain,
                    slug,
                    null,
                    id));
            clicks[0]++;
          }

          // Counts without detail: clicks spread through each day, with no visitor or visit.
          List<Object> dailyList = Js.list(history.get("daily"));
          for (Object item : dailyList == null ? List.of() : dailyList) {
            Map<String, Object> d = Js.map(item);
            double start = Http.parseDate(Js.string(d.get("day")) + "T00:00:00Z");
            double count = Js.toNumber(d.get("clicks"));
            if (Double.isNaN(start) || !(count > 0)) {
              continue;
            }
            double n = Math.min(count, 1_000_000);
            for (int i = 0; i < n; i++) {
              store.insertEvent(
                  event(
                      site,
                      (long) start + (long) Math.floor(((i + 0.5) / n) * 86_400_000),
                      "",
                      "",
                      "/" + slug,
                      linkDomain,
                      slug,
                      Json.object("imported", "daily"),
                      id));
              clicks[0]++;
            }
          }
          if (!linkDomain.isEmpty()) {
            store.addLinkDomain(linkDomain, site, now);
          }
          String name = Js.truthy(foreign.get("name")) ? Js.string(foreign.get("name")) : slug;
          Object createdAt = foreign.get("createdAt");
          long created = Js.truthy(createdAt) ? Js.asLong(createdAt) : now;
          store.insertLink(
              Json.object(
                  "id", id,
                  "site", site,
                  "domain", linkDomain,
                  "slug", slug,
                  "name", Js.slice(name, 0, 100),
                  "url", url,
                  "createdAt", created,
                  "updatedAt", created));
          return null;
        });
    if (!domain.isEmpty()) {
      runlight.forgetLinkDomains();
    }
    return Json.object("status", "created", "clicks", clicks[0]);
  }

  /** A click row. */
  private static Map<String, Object> event(
      String site,
      long ts,
      String visitor,
      String session,
      String path,
      String hostname,
      String name,
      Object props,
      String link) {
    return Json.object(
        "site", site,
        "ts", ts,
        "kind", "click",
        "visitor", visitor,
        "session", session,
        "pageview", "",
        "path", path,
        "hostname", hostname,
        "title", "",
        "name", name,
        "props", props,
        "engagedMs", 0L,
        "scroll", null,
        "link", link);
  }
}
