package sh.runlight;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import sh.runlight.CodedError.FunnelError;

/** Funnels: checking one from the dashboard. Counting is the store's funnelCounts(). */
public final class Funnels {
  private Funnels() {}

  /**
   * Checks and tidies a funnel from the dashboard: a name, and two to eight steps, each a page
   * (with * as a wildcard) or an event name.
   *
   * @throws FunnelError when the funnel is refused
   */
  public static Map<String, Object> funnelFrom(
      Object input, String site, List<Map<String, Object>> existing, long now, String id) {
    String name = Js.slice(Js.trim(Goals.field(input, "name")), 0, 80);
    if (name.isEmpty()) {
      throw new FunnelError("Give the funnel a name", "funnel_name");
    }
    for (Map<String, Object> f : existing) {
      if (!f.get("id").equals(id) && Js.lower((String) f.get("name")).equals(Js.lower(name))) {
        throw new FunnelError(
            "There is already a funnel called \"" + name + "\"",
            "funnel_exists",
            Map.of("name", name));
      }
    }
    List<Object> raw = Js.list(Js.get(input, "steps"));
    List<Object> steps = new ArrayList<>();
    for (Object item : raw == null ? List.of() : raw) {
      // Anything that is not an object reads as one with no fields.
      Object step = Js.isObject(item) ? item : Map.of();
      String kind = "event".equals(Js.get(step, "kind")) ? "event" : "page";
      String match = Js.slice(Js.trim(Goals.field(step, "match")), 0, 500);
      if (match.isEmpty()) {
        continue;
      }
      if (kind.equals("page")) {
        // A full URL is fine to paste; the path is what counts.
        String path = Goals.pagePattern(match);
        if (path == null) {
          throw new FunnelError(
              "\"" + match + "\" is not a path or a URL",
              "funnel_page_bad",
              Map.of("match", match));
        }
        match = path;
      }
      steps.add(Json.object("kind", kind, "match", match));
    }
    if (steps.size() < 2) {
      throw new FunnelError("A funnel needs at least two steps", "funnel_short");
    }
    if (steps.size() > 8) {
      throw new FunnelError("A funnel has at most eight steps", "funnel_long");
    }
    Object createdAt = now;
    for (Map<String, Object> f : existing) {
      if (f.get("id").equals(id)) {
        createdAt = f.get("createdAt");
        break;
      }
    }
    return Json.object(
        "id",
        id != null ? id : Hash.randomId(),
        "site",
        site,
        "name",
        name,
        "steps",
        steps,
        "createdAt",
        createdAt);
  }
}
