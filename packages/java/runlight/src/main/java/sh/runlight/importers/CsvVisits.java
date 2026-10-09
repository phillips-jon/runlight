package sh.runlight.importers;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.http.Url;

/**
 * Visit history from a CSV file, in one of two shapes: Umami's data export (one row per pageview or
 * event, as in its website_event table) or Runlight's own, documented on the dashboard docs page.
 * The dashboard reads the file, sorts it with rowTime, and sends it in batches; the server turns
 * each row into a hit with csvHit. Nothing here touches a database.
 *
 * <p>A format is "umami" or "runlight". A hit is an ImportedHit map (see {@link Visits}).
 */
public final class CsvVisits {
  private CsvVisits() {}

  /** At most this many rows in one request. */
  public static final int CSV_BATCH = 2000;

  private static final Pattern UNIX = Pattern.compile("^\\d+(\\.\\d+)?\\z");
  private static final Pattern ZONED = Pattern.compile("[zZ]|[+-]\\d\\d:?\\d\\d\\z");
  private static final Pattern TIMED = Pattern.compile("T\\d");
  private static final Pattern SCHEME =
      Pattern.compile("^[a-z][a-z0-9+.-]*://", Pattern.CASE_INSENSITIVE);

  /** Which shape a file is, from its header row (lower case, as the dashboard reads it). */
  public static String csvFormat(List<String> columns) {
    if (columns.contains("created_at") && columns.contains("url_path")) {
      return "umami";
    }
    if (columns.contains("time") && (columns.contains("path") || columns.contains("url"))) {
      return "runlight";
    }
    return null;
  }

  /**
   * A row's time in milliseconds, or NaN. ISO 8601 with or without a zone, "2024-05-01 12:34:56"
   * (both read as UTC when no zone is given, as Umami writes them), or a Unix time in seconds or
   * milliseconds.
   */
  public static double rowTime(Map<String, String> row, String format) {
    String raw = format.equals("umami") ? row.get("created_at") : row.get("time");
    String text = raw == null ? "" : Js.trim(raw);
    if (text.isEmpty()) {
      return Double.NaN;
    }
    if (UNIX.matcher(text).find()) {
      double n = Js.toNumber(text);
      return n < 1e12 ? Js.round(n * 1000) : Js.round(n);
    }
    String iso = text.replaceFirst(" ", "T");
    return Http.parseDate(
        ZONED.matcher(iso).find() || !TIMED.matcher(iso).find() ? iso : iso + "Z");
  }

  private static String cell(Map<String, String> row, String... names) {
    for (String n : names) {
      String value = row.get(n);
      if (value != null && !Js.trim(value).isEmpty()) {
        return Js.trim(value);
      }
    }
    return "";
  }

  /**
   * A row with no visitor is its own visit, keyed by its whole content so a second import gives it
   * the same ids.
   */
  private static String ownKey(Map<String, String> row) {
    List<Object> entries = new ArrayList<>();
    for (Map.Entry<String, Object> e : Js.entries(row)) {
      entries.add(Json.array(e.getKey(), e.getValue()));
    }
    entries.sort(
        (a, b) -> Js.compare((String) Js.list(a).get(0), (String) Js.list(b).get(0)) < 0 ? -1 : 1);
    return "row:" + Json.stringify(entries);
  }

  /** A referrer as a full address: a bare domain gains https://. */
  private static String fullReferrer(String value) {
    return value.isEmpty() ? "" : SCHEME.matcher(value).find() ? value : "https://" + value;
  }

  /**
   * One row as a hit and the namespace its ids are made in ({@code {ns, hit}}), or null for a row
   * that is not a pageview or a named event, or has no time. Umami rows use the namespace the Umami
   * API import does, so the same visits brought in both ways get the same ids.
   */
  public static Map<String, Object> csvHit(Map<String, String> row, String format) {
    double ts = rowTime(row, format);
    if (Double.isNaN(ts) || Double.isInfinite(ts)) {
      return null;
    }
    if (format.equals("umami")) {
      String type = cell(row, "event_type");
      type = !type.isEmpty() ? type : "1";
      String name = cell(row, "event_name");
      if (!type.equals("1") && !(type.equals("2") && !name.isEmpty())) {
        return null;
      }
      String website = cell(row, "website_id");
      String domain = cell(row, "referrer_domain");
      String query = cell(row, "referrer_query");
      String referrerPath = cell(row, "referrer_path");
      String key = cell(row, "session_id", "visit_id");
      String path = cell(row, "url_path");
      return Json.object(
          "ns",
          !website.isEmpty() ? "umami-visits:" + website : "umami-csv",
          "hit",
          Json.object(
              "ts", Js.num(ts),
              "key", !key.isEmpty() ? key : ownKey(row),
              "kind", type.equals("1") ? "pageview" : "event",
              "hostname", cell(row, "hostname"),
              "path", !path.isEmpty() ? path : "/",
              "query", cell(row, "url_query"),
              "referrer",
                  domain.isEmpty()
                      ? ""
                      : "https://"
                          + domain
                          + (!referrerPath.isEmpty() ? referrerPath : "/")
                          + (!query.isEmpty() ? "?" + query.replaceFirst("^\\?", "") : ""),
              "title", cell(row, "page_title"),
              "name", type.equals("2") ? name : "",
              "country", cell(row, "country"),
              "region", cell(row, "subdivision1", "region"),
              "city", cell(row, "city"),
              "browser", cell(row, "browser"),
              "os", cell(row, "os"),
              "device", cell(row, "device"),
              "screen", cell(row, "screen"),
              "language", cell(row, "language")));
    }
    // Runlight's own shape: a full url, or a path (with its query) and a hostname.
    String hostname = cell(row, "hostname");
    String path = cell(row, "path");
    String query = "";
    String url = cell(row, "url");
    if (!url.isEmpty()) {
      Url u = Url.parse(SCHEME.matcher(url).find() ? url : "https://" + url);
      if (u == null) {
        return null;
      }
      hostname = !hostname.isEmpty() ? hostname : u.hostname;
      path = u.pathname;
      query = Js.slice(u.search, 1);
    } else {
      int at = path.indexOf('?');
      if (at >= 0) {
        query = path.substring(at + 1);
        path = path.substring(0, at);
      }
    }
    if (!path.startsWith("/")) {
      path = "/" + path;
    }
    String name = cell(row, "event");
    String visitor = cell(row, "visitor");
    return Json.object(
        "ns",
        "csv",
        "hit",
        Json.object(
            "ts", Js.num(ts),
            // Without a visitor column every row is its own visit.
            "key", !visitor.isEmpty() ? visitor : ownKey(row),
            "kind", !name.isEmpty() ? "event" : "pageview",
            "hostname", hostname,
            "path", path,
            "query", query,
            "referrer", fullReferrer(cell(row, "referrer")),
            "title", cell(row, "title"),
            "name", name,
            "country", cell(row, "country"),
            "region", cell(row, "region"),
            "city", cell(row, "city"),
            "browser", cell(row, "browser"),
            "os", cell(row, "os"),
            "device", cell(row, "device"),
            "screen", cell(row, "screen"),
            "language", cell(row, "language")));
  }
}
