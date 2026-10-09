package sh.runlight;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import sh.runlight.http.Fetcher;
import sh.runlight.http.Response;
import sh.runlight.http.Url;

/**
 * A site's icon, for the dashboard header: the best icon its home page links to, or /favicon.ico.
 * Fetched from the site's own configured origin (never from request input), cached in memory for a
 * day. An icon is a map of {@code body} (the bytes) and {@code type} (the media type).
 */
public final class Icon {
  private Icon() {}

  private static final long TIMEOUT_MS = 4000;
  private static final long MAX_BYTES = 256 * 1024;
  private static final long DAY = 86_400_000;

  /** A few hundred sites at most; past that the oldest go, so the cache cannot grow without end. */
  private static final int CACHE_SIZE = 500;

  private record Entry(long at, Map<String, Object> icon) {}

  private static final Map<String, Entry> CACHE = new LinkedHashMap<>();

  /** Lookups under way, so many dashboards opening at once share one. */
  private static final Map<String, CompletableFuture<Map<String, Object>>> PENDING =
      new ConcurrentHashMap<>();

  private static final Pattern LINK = Pattern.compile("<link\\b[^>]*>", Pattern.CASE_INSENSITIVE);
  private static final Pattern SPACES = Pattern.compile("[" + Js.SPACE + "]+");

  private static String attr(String tag, String name) {
    Matcher match =
        Pattern.compile(
                "\\b"
                    + name
                    + "["
                    + Js.SPACE
                    + "]*=["
                    + Js.SPACE
                    + "]*(\"([^\"]*)\"|'([^']*)'|([^"
                    + Js.SPACE
                    + ">]+))",
                Pattern.CASE_INSENSITIVE)
            .matcher(tag);
    if (!match.find()) {
      return "";
    }
    for (int i = 2; i <= 4; i++) {
      if (match.group(i) != null) {
        return Js.trim(match.group(i));
      }
    }
    return "";
  }

  /**
   * Icon URLs a page links to, best first: apple-touch-icon, then SVG and PNG icons, then any icon.
   */
  public static List<String> iconLinks(String html, String base) {
    record Found(String url, int score) {}
    List<Found> found = new ArrayList<>();
    Matcher tags = LINK.matcher(html);
    while (tags.find()) {
      String tag = tags.group();
      List<String> rel = List.of(SPACES.split(Js.lower(attr(tag, "rel")), -1));
      String href = attr(tag, "href");
      if (href.isEmpty() || !(rel.contains("icon") || rel.contains("apple-touch-icon"))) {
        continue;
      }
      Url parsed = Url.parse(href, base);
      if (parsed == null) {
        continue;
      }
      String url = parsed.href();
      // Only https, which is all the fetch below takes.
      if (!url.startsWith("https://")) {
        continue;
      }
      String type = Js.lower(attr(tag, "type"));
      int score =
          rel.contains("apple-touch-icon")
              ? 3
              : type.contains("svg") || url.endsWith(".svg")
                  ? 2
                  : type.contains("png") || url.endsWith(".png") ? 1 : 0;
      found.add(new Found(url, score));
    }
    // List.sort is stable, as Array.prototype.sort is.
    found.sort(Comparator.comparingInt((Found f) -> f.score()).reversed());
    List<String> out = new ArrayList<>();
    for (Found f : found) {
      out.add(f.url());
    }
    return out;
  }

  /** A GET of a public https address, with redirects followed only to public addresses too. */
  private static Response get(String url, Fetcher fetcher, long maxBytes, boolean truncate) {
    Map<String, Object> init =
        Json.object(
            "timeoutMs",
            TIMEOUT_MS,
            "redirects",
            3L,
            "headers",
            Map.of("user-agent", "Runlight (+https://runlight.sh)"),
            "maxBytes",
            maxBytes);
    if (truncate) {
      init.put("truncate", true);
    }
    try {
      return Safefetch.publicFetch(url, init, fetcher);
    } catch (RuntimeException e) {
      return null;
    }
  }

  private static Map<String, Object> image(String url, Fetcher fetcher) {
    // An image must arrive whole, so one longer than the cap is no use.
    Response response = get(url, fetcher, MAX_BYTES, false);
    if (response == null || !response.ok()) {
      return null;
    }
    String contentType = response.headers().get("content-type");
    String type = Js.lower(Js.trim((contentType == null ? "" : contentType).split(";", -1)[0]));
    if (!type.startsWith("image/")) {
      return null;
    }
    if (Js.toNumber(response.headers().get("content-length")) > MAX_BYTES) {
      return null;
    }
    byte[] body;
    try {
      body = response.bytes();
    } catch (RuntimeException e) {
      return null;
    }
    if (body.length == 0 || body.length > MAX_BYTES) {
      return null;
    }
    return Json.object("body", body, "type", type);
  }

  /** The site's icon, on the wall clock, or null when it has none that can be fetched. */
  public static Map<String, Object> fetchIcon(String origin, Fetcher fetcher) {
    return fetchIcon(origin, System.currentTimeMillis(), fetcher);
  }

  /**
   * The site's icon, or null when it has none that can be fetched.
   *
   * @param now milliseconds
   * @param fetcher what sends each request; null for the default
   */
  public static Map<String, Object> fetchIcon(String origin, long now, Fetcher fetcher) {
    synchronized (CACHE) {
      Entry cached = CACHE.get(origin);
      if (cached != null && now - cached.at() < (cached.icon() != null ? DAY : DAY / 24)) {
        return cached.icon();
      }
    }
    CompletableFuture<Map<String, Object>> mine = new CompletableFuture<>();
    CompletableFuture<Map<String, Object>> lookup = PENDING.putIfAbsent(origin, mine);
    if (lookup != null) {
      return lookup.join();
    }
    try {
      Map<String, Object> icon = lookUp(origin, now, fetcher);
      mine.complete(icon);
      return icon;
    } catch (RuntimeException e) {
      mine.completeExceptionally(e);
      throw e;
    } finally {
      PENDING.remove(origin, mine);
    }
  }

  private static Map<String, Object> lookUp(String origin, long now, Fetcher fetcher) {
    Map<String, Object> icon = null;
    // The head is all that is needed, so a huge page is not read to the end.
    Response page = get(origin + "/", fetcher, 200_000, true);
    String pageType = page == null ? null : page.headers().get("content-type");
    if (page != null && page.ok() && pageType != null && pageType.contains("html")) {
      String html = Js.decodeUtf8(page.bytes());
      // A Response from the Fetcher has no url of its own, so links resolve against the origin.
      List<String> links = iconLinks(html, origin);
      for (String url : links.subList(0, Math.min(4, links.size()))) {
        icon = image(url, fetcher);
        if (icon != null) {
          break;
        }
      }
    }
    if (icon == null) {
      icon = image(origin + "/favicon.ico", fetcher);
    }
    synchronized (CACHE) {
      // As a JavaScript Map's set, an origin already cached keeps its place.
      CACHE.put(origin, new Entry(now, icon));
      if (CACHE.size() > CACHE_SIZE) {
        CACHE.remove(CACHE.keySet().iterator().next());
      }
    }
    return icon;
  }

  /** Forgets every cached icon, for tests. */
  static void clearCache() {
    synchronized (CACHE) {
      CACHE.clear();
    }
  }
}
