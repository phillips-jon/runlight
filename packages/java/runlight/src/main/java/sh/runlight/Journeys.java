package sh.runlight;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Journeys: the paths visits take through a site, page by page. Each visit's pages are read in
 * order, a page seen twice in a row (a refresh) counts once, and the path is cut to a number of
 * steps, from a start page and to an end page when those are chosen. The answer lines the paths up
 * in columns, one per step, with the flows between them, as Umami's journeys do.
 *
 * <p>Options: steps, and optionally start, end, and through (an object with step and value: only
 * paths that show this page at this step, 0-based, to follow one page).
 *
 * <p>The answer: visits; columns, each with items (the pages seen at this step, most visits first,
 * with the rest as "" for other pages), visits (that reached this step), and left (that went no
 * further); links, visits moving from a page at one step to a page at the next, "" being any other
 * page; and paths, the commonest whole paths.
 */
public final class Journeys {
  private Journeys() {}

  /**
   * How many pages of a visit to read: enough to find a start page and still have the steps after
   * it.
   */
  public static final int PAGES_PER_VISIT = 40;

  private static final int TOP = 8;

  public static Map<String, Object> journeys(
      List<Map<String, Object>> rows, Map<String, Object> options) {
    Object stepsOption = options.get("steps");
    double floor = Math.floor(stepsOption == null ? Double.NaN : Js.toNumber(stepsOption));
    int steps = (int) Math.min(Math.max(Double.isNaN(floor) || floor == 0 ? 5 : floor, 2), 8);
    // Group each visit's pages, dropping refreshes.
    Map<String, List<String>> visits = new LinkedHashMap<>();
    for (Map<String, Object> row : rows) {
      List<String> pages =
          visits.computeIfAbsent((String) row.get("session"), k -> new ArrayList<>());
      String path = (String) row.get("path");
      if (pages.isEmpty() || !pages.get(pages.size() - 1).equals(path)) {
        pages.add(path);
      }
    }
    String start = options.get("start") instanceof String s ? s : null;
    String end = options.get("end") instanceof String s ? s : null;
    Map<String, Object> through = Js.map(options.get("through"));
    List<List<String>> sequences = new ArrayList<>();
    // Visits that went on past the last step shown, so they never count as having gone no further.
    List<Boolean> cut = new ArrayList<>();
    for (List<String> all : visits.values()) {
      List<String> pages = all;
      if (start != null && !start.isEmpty()) {
        int at = pages.indexOf(start);
        if (at < 0) {
          continue;
        }
        pages = pages.subList(at, pages.size());
      }
      if (end != null && !end.isEmpty()) {
        int at = pages.indexOf(end);
        if (at < 0) {
          continue;
        }
        pages = pages.subList(0, at + 1);
      }
      boolean more = pages.size() > steps;
      pages = new ArrayList<>(pages.subList(0, Math.min(steps, pages.size())));
      if (through != null && !Js.same(at(pages, through.get("step")), through.get("value"))) {
        continue;
      }
      cut.add(more);
      sequences.add(pages);
    }

    List<Object> columns = new ArrayList<>();
    List<Set<String>> kept = new ArrayList<>();
    for (int i = 0; i < steps; i++) {
      Map<String, Long> counts = new LinkedHashMap<>();
      long reached = 0;
      long left = 0;
      for (int n = 0; n < sequences.size(); n++) {
        List<String> s = sequences.get(n);
        if (s.size() <= i) {
          continue;
        }
        reached++;
        if (s.size() == i + 1 && !cut.get(n)) {
          left++;
        }
        counts.merge(s.get(i), 1L, Long::sum);
      }
      List<Map.Entry<String, Long>> sorted = new ArrayList<>(counts.entrySet());
      sorted.sort(
          (a, b) -> {
            long d = b.getValue() - a.getValue();
            if (d != 0) {
              return d < 0 ? -1 : 1;
            }
            return Js.compare(a.getKey(), b.getKey()) < 0 ? -1 : 1;
          });
      List<Map.Entry<String, Long>> top = sorted.subList(0, Math.min(TOP, sorted.size()));
      long rest = 0;
      for (Map.Entry<String, Long> e :
          sorted.subList(Math.min(TOP, sorted.size()), sorted.size())) {
        rest += e.getValue();
      }
      Set<String> keep = new HashSet<>();
      for (Map.Entry<String, Long> e : top) {
        keep.add(e.getKey());
      }
      kept.add(keep);
      if (reached == 0) {
        break;
      }
      List<Object> items = new ArrayList<>();
      for (Map.Entry<String, Long> e : top) {
        items.add(Json.object("value", e.getKey(), "visits", e.getValue()));
      }
      if (rest != 0) {
        items.add(Json.object("value", "", "visits", rest));
      }
      columns.add(Json.object("items", items, "visits", reached, "left", left));
    }

    Map<String, Map<String, Object>> linkCounts = new LinkedHashMap<>();
    for (List<String> s : sequences) {
      for (int i = 0; i + 1 < s.size() && i + 1 < columns.size(); i++) {
        String from = kept.get(i).contains(s.get(i)) ? s.get(i) : "";
        String to = kept.get(i + 1).contains(s.get(i + 1)) ? s.get(i + 1) : "";
        String key = i + "\0" + from + "\0" + to;
        Map<String, Object> link =
            linkCounts.computeIfAbsent(
                key, k -> Json.object("step", 0L, "from", from, "to", to, "visits", 0L));
        link.put("step", (long) i);
        link.put("visits", (long) link.get("visits") + 1);
      }
    }
    List<Map<String, Object>> links = new ArrayList<>(linkCounts.values());
    // Ties go by page, as the columns and paths do, so the order never follows the visits' ids.
    links.sort(
        (a, b) -> {
          long d = (long) a.get("step") - (long) b.get("step");
          if (d != 0) {
            return d < 0 ? -1 : 1;
          }
          d = (long) b.get("visits") - (long) a.get("visits");
          if (d != 0) {
            return d < 0 ? -1 : 1;
          }
          int c = Js.compare((String) a.get("from"), (String) b.get("from"));
          return c != 0 ? c : Js.compare((String) a.get("to"), (String) b.get("to"));
        });

    Map<String, Object[]> pathCounts = new LinkedHashMap<>();
    for (List<String> s : sequences) {
      String key = String.join("\0", s);
      Object[] entry = pathCounts.computeIfAbsent(key, k -> new Object[] {k, s, 0L});
      entry[2] = (long) entry[2] + 1;
    }
    List<Object[]> paths = new ArrayList<>(pathCounts.values());
    paths.sort(
        (x, y) -> {
          long d = (long) y[2] - (long) x[2];
          if (d != 0) {
            return d < 0 ? -1 : 1;
          }
          return Js.compare((String) x[0], (String) y[0]) < 0 ? -1 : 1;
        });
    List<Object> pathOut = new ArrayList<>();
    for (Object[] p : paths.subList(0, Math.min(20, paths.size()))) {
      pathOut.add(Json.object("pages", p[1], "visits", p[2]));
    }
    return Json.object(
        "visits", (long) sequences.size(), "columns", columns, "links", links, "paths", pathOut);
  }

  /** pages[step], which is undefined for a step that is not a whole number in range. */
  private static String at(List<String> pages, Object step) {
    if (!(step instanceof Number n)) {
      return null;
    }
    double d = n.doubleValue();
    if (d != Math.floor(d) || d < 0 || d >= pages.size()) {
      return null;
    }
    return pages.get((int) d);
  }
}
