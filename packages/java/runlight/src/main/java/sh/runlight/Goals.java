package sh.runlight;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;
import sh.runlight.CodedError.GoalError;

/** Goals: checking one from the dashboard, and the click rules the tracker carries. */
public final class Goals {
  private Goals() {}

  private static final List<String> KINDS = List.of("event", "page", "click");
  private static final List<String> MODES = List.of("none", "fixed", "prop");
  private static final Pattern PROP = Pattern.compile("^[A-Za-z0-9_.-]{1,40}\\z");
  private static final Pattern CURRENCY = Pattern.compile("^[A-Z]{3}\\z");

  /**
   * A page to match, written the way paths are recorded: the path of a pasted URL, with a leading
   * slash, percent-encoded as browsers send it, so /café matches the recorded /caf%C3%A9, and with
   * a hash route kept. {@code *} stays a wildcard. Null when it is not a path or a URL.
   */
  public static String pagePattern(String input) {
    String starred = input.replace("*", "__STAR__");
    // A pattern written to start with * keeps that start, rather than gaining a slash.
    String path = Sources.recordedPath(starred.startsWith("__STAR__") ? "/" + starred : starred);
    if (path == null) {
      return null;
    }
    String pattern = path.replace("__STAR__", "*");
    return input.startsWith("*") ? pattern.replaceFirst("^/", "") : pattern;
  }

  /** String(input[key] ?? ""). */
  public static String field(Object input, String key) {
    Object value = Js.get(input, key);
    return value == null || value == Json.UNDEFINED ? "" : Js.string(value);
  }

  private static String text(Object input, String key, int max) {
    return Js.slice(Js.trim(field(input, key)), 0, max);
  }

  /**
   * Checks and tidies a goal from the dashboard. {@code existing} is the site's other goals, so two
   * goals cannot share a name.
   *
   * @throws GoalError when the goal is refused
   */
  public static Map<String, Object> goalFrom(
      Object input, String site, List<Map<String, Object>> existing, long now, String id) {
    String name = text(input, "name", 80);
    if (name.isEmpty()) {
      throw new GoalError("Give the goal a name", "goal_name");
    }
    for (Map<String, Object> g : existing) {
      if (!g.get("id").equals(id) && Js.lower((String) g.get("name")).equals(Js.lower(name))) {
        throw new GoalError(
            "There is already a goal called \"" + name + "\"", "goal_exists", Map.of("name", name));
      }
    }

    String kind = field(input, "kind");
    if (!KINDS.contains(kind)) {
      throw new GoalError(
          "Pick what the goal counts: an event, a page visit, or a click", "goal_kind");
    }

    String match = text(input, "match", 500);
    String clickBy = "";
    if (kind.equals("event") && match.isEmpty()) {
      throw new GoalError("Enter the event's name", "goal_event");
    }
    if (kind.equals("page")) {
      if (match.isEmpty()) {
        throw new GoalError("Enter a page path, like /thanks or /blog/*", "goal_page");
      }
      // A full URL is fine to paste; the path is what counts.
      String path = pagePattern(match);
      if (path == null) {
        throw new GoalError("That page is not a path or a URL", "goal_page_bad");
      }
      match = path;
    }
    if (kind.equals("click")) {
      clickBy = "link".equals(Js.get(input, "clickBy")) ? "link" : "selector";
      if (match.isEmpty()) {
        throw clickBy.equals("link")
            ? new GoalError("Enter the link's address, like https://buy.stripe.com/*", "goal_link")
            : new GoalError("Enter a CSS selector, like #signup or .buy-button", "goal_selector");
      }
    }

    // A click goal sends an event named after itself, so its name and an event goal's match must
    // not meet.
    List<Map<String, Object>> others = new ArrayList<>();
    for (Map<String, Object> g : existing) {
      if (!g.get("id").equals(id)) {
        others.add(g);
      }
    }
    if (kind.equals("click")) {
      for (Map<String, Object> g : others) {
        if ("event".equals(g.get("kind"))
            && Js.lower((String) g.get("match")).equals(Js.lower(name))) {
          throw new GoalError(
              "An event goal already counts events called \""
                  + name
                  + "\", so give this click goal another name",
              "goal_event_taken",
              Map.of("name", name));
        }
      }
    }
    if (kind.equals("event")) {
      for (Map<String, Object> g : others) {
        if ("click".equals(g.get("kind"))
            && Js.lower((String) g.get("name")).equals(Js.lower(match))) {
          throw new GoalError(
              "The click goal \"" + match + "\" already sends events with that name",
              "goal_click_taken",
              Map.of("match", match));
        }
      }
    }

    String mode = Js.string(Js.get(input, "valueMode"));
    String valueMode = MODES.contains(mode) ? mode : "none";
    // Page visits and click rules carry no properties, so only an event can send its own amount.
    if (valueMode.equals("prop") && !kind.equals("event")) {
      throw new GoalError(
          "Only an event goal can take its amount from the event; use a fixed amount instead",
          "goal_prop_kind");
    }
    double value = valueMode.equals("fixed") ? Js.toNumber(Js.get(input, "value")) : 0;
    if (valueMode.equals("fixed") && !(Double.isFinite(value) && value >= 0 && value < 1e9)) {
      throw new GoalError("Enter an amount, like 49 or 9.99", "goal_amount");
    }
    String valueProp = "";
    if (valueMode.equals("prop")) {
      valueProp = text(input, "valueProp", 40);
      if (valueProp.isEmpty()) {
        valueProp = "revenue";
      }
    }
    if (valueMode.equals("prop") && !PROP.matcher(valueProp).find()) {
      throw new GoalError(
          "A property name uses letters, numbers, dots, dashes, and underscores", "goal_prop_name");
    }
    String currency = Js.upper(text(input, "currency", 20));
    if (currency.isEmpty()) {
      currency = "USD";
    }
    if (!CURRENCY.matcher(currency).find()) {
      throw new GoalError("Use a three-letter currency code, like USD or EUR", "goal_currency");
    }

    Map<String, Object> before = null;
    for (Map<String, Object> g : existing) {
      if (g.get("id").equals(id)) {
        before = g;
        break;
      }
    }
    return Json.object(
        "id", id != null ? id : Hash.randomId(),
        "site", site,
        "name", name,
        "kind", kind,
        "match", match,
        "clickBy", clickBy,
        "valueMode", valueMode,
        "value", Js.num(Js.round(value * 100) / 100),
        "valueProp", valueProp,
        "currency", currency,
        "createdAt", before != null ? before.get("createdAt") : (Object) now);
  }

  /**
   * Click rules for the tracker, keyed by site id and by each of the site's hostnames (or "*" for a
   * site with none), so the script finds its own. One rule is [s for selector or h for a link, what
   * to match, the event to send].
   */
  public static Map<String, Object> clickRules(
      List<Map<String, Object>> sites, List<Map<String, Object>> goals) {
    Map<String, Object> out = new LinkedHashMap<>();
    for (Map<String, Object> site : sites) {
      List<Object> rules = new ArrayList<>();
      for (Map<String, Object> g : goals) {
        if (g.get("site").equals(site.get("id")) && "click".equals(g.get("kind"))) {
          rules.add(
              List.of("link".equals(g.get("clickBy")) ? "h" : "s", g.get("match"), g.get("name")));
        }
      }
      if (rules.isEmpty()) {
        continue;
      }
      out.put((String) site.get("id"), rules);
      List<Object> hosts = Js.list(site.get("hostnames"));
      for (Object host : hosts == null || hosts.isEmpty() ? List.<Object>of("*") : hosts) {
        out.put(((String) host).replaceFirst("^www\\.", ""), rules);
      }
    }
    return out;
  }
}
