package sh.runlight;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Function;
import sh.runlight.http.Headers;
import sh.runlight.http.Request;
import sh.runlight.http.Response;

/**
 * The MCP server at {base}/mcp: Streamable HTTP without sessions or a stream, JSON-RPC in and JSON
 * out. Every tool is a read of the HTTP API, made with the caller's own credentials, so the MCP
 * server can see exactly what the token can and nothing more.
 */
public final class Mcp {
  private Mcp() {}

  /** Newest first; a client asking for one we do not know is answered with the newest. */
  public static final List<String> PROTOCOL_VERSIONS =
      List.of("2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05");

  public static final String INSTRUCTIONS =
      "Runlight is privacy friendly web analytics. These tools read one install's numbers:"
          + " visitors, visits, pageviews, bounce rate, visit duration, where visitors came from,"
          + " what they read, goals and revenue, AI assistants that sent visitors or fetched pages,"
          + " and short links.\n"
          + "\n"
          + "Start with list_sites when you do not know the site id; every other tool defaults to"
          + " the first site. Dates are in the site's own timezone, which each answer includes."
          + " Periods: today, yesterday, 7d, 30d, 90d, month (this month so far), last_month, year"
          + " (this year so far), 12mo, all; or from and to as YYYY-MM-DD. Answers compare with the"
          + " period before unless compare is off.\n"
          + "\n"
          + "Filters narrow any report to matching visits, written dimension:op:value with op one"
          + " of is, not, contains, for example \"channel:is:Organic Search\" or"
          + " \"page:contains:/blog\". Visitors are counted per day without cookies, so a visitor"
          + " seen on two days counts twice across a long range.";

  /** Reads one API path with the caller's credentials. */
  @FunctionalInterface
  public interface ApiRead {
    Response read(String path, List<Map.Entry<String, String>> params);
  }

  /**
   * One tool: its name, title, description, and input schema as MCP lists them; request, which
   * turns the tool's arguments into the API path and query to read (a map of {@code path} and
   * {@code params}); and shape, which trims an answer before it goes back when the API's carries
   * more than an assistant needs, or null.
   */
  public record Tool(
      String name,
      String title,
      String description,
      Map<String, Object> inputSchema,
      Function<Object, Map<String, Object>> request,
      Function<Object, Object> shape) {}

  private static final List<String> RANGE_KEYS = List.of("site", "period", "from", "to", "filters");
  private static final List<String> COMPARE_KEYS =
      concat(RANGE_KEYS, List.of("compare", "compare_from", "compare_to"));

  private static final Map<String, Object> RANGE =
      Json.object(
          "site",
          Json.object(
              "type",
              "string",
              "description",
              "Site id from list_sites. Defaults to the first site."),
          "period",
          Json.object(
              "type",
              "string",
              "enum",
              List.of(
                  "today",
                  "yesterday",
                  "7d",
                  "30d",
                  "90d",
                  "month",
                  "last_month",
                  "year",
                  "12mo",
                  "all"),
              "description",
              "The date range. Defaults to 30d. Ignored when from and to are given."),
          "from",
          Json.object("type", "string", "description", "First day, YYYY-MM-DD, with to."),
          "to",
          Json.object("type", "string", "description", "Last day, YYYY-MM-DD, inclusive."),
          "filters",
          Json.object(
              "type",
              "array",
              "items",
              Json.object("type", "string"),
              "maxItems",
              (long) Query.MAX_FILTERS,
              "description",
              "Narrow to matching visits, up to "
                  + Query.MAX_FILTERS
                  + " at once, each \"dimension:op:value\" with op is, not, or contains."));

  private static final Map<String, Object> COMPARE =
      Json.object(
          "compare",
          Json.object(
              "type",
              "string",
              "enum",
              List.of("previous", "year", "custom", "off"),
              "description",
              "What to compare with. Defaults to previous, the same length of time just before."),
          "compare_from",
          Json.object(
              "type", "string", "description", "For compare custom: first day, YYYY-MM-DD."),
          "compare_to",
          Json.object(
              "type", "string", "description", "For compare custom: last day, YYYY-MM-DD."));

  private static List<String> concat(List<String> a, List<String> b) {
    List<String> out = new ArrayList<>(a);
    out.addAll(b);
    return List.copyOf(out);
  }

  /** An object of the given properties maps' entries in order, then name and value pairs. */
  private static Map<String, Object> props(List<Map<String, Object>> spread, Object... pairs) {
    Map<String, Object> out = new LinkedHashMap<>();
    for (Map<String, Object> part : spread) {
      out.putAll(part);
    }
    out.putAll(Json.object(pairs));
    return out;
  }

  private static List<Map.Entry<String, String>> rangeParams(Object args, List<String> keys) {
    List<Map.Entry<String, String>> params = new ArrayList<>();
    for (String key : keys) {
      Object value = Js.get(args, key);
      if (key.equals("filters")) {
        if (value instanceof List<?> list) {
          for (Object f : list) {
            params.add(Map.entry("filter", Js.string(f)));
          }
        }
      } else if (value != Json.UNDEFINED && value != null && !"".equals(value)) {
        params.add(Map.entry(key, Js.string(value)));
      }
    }
    return params;
  }

  private static Map<String, Object> call(String path, List<Map.Entry<String, String>> params) {
    return Json.object("path", path, "params", params);
  }

  private static Function<Object, Map<String, Object>> read(String path, List<String> keys) {
    return args -> call(path, rangeParams(args, keys));
  }

  private static Function<Object, Map<String, Object>> read(
      String path, List<String> keys, Function<Object, List<Map.Entry<String, String>>> extra) {
    return args -> {
      List<Map.Entry<String, String>> params = rangeParams(args, keys);
      params.addAll(extra.apply(args));
      return call(path, params);
    };
  }

  /** String(Math.min(100, Math.max(1, Number(value) || fallback))). */
  private static String limit(Object value, int fallback) {
    double n = Js.toNumber(value);
    if (!Js.truthy(n)) {
      n = fallback;
    }
    return Js.string(Js.num(Math.min(100, Math.max(1, n))));
  }

  private static List<String> plus(List<String> keys, String... more) {
    return concat(keys, List.of(more));
  }

  /** The tools, in the order MCP lists them. */
  public static final List<Tool> TOOLS = tools();

  @SuppressWarnings("unchecked")
  private static List<Tool> tools() {
    Map<String, Object> site = (Map<String, Object>) RANGE.get("site");
    return List.of(
        new Tool(
            "list_sites",
            "List sites",
            "Every site this token can read, with its id, name, hostnames, timezone, and when it"
                + " last had a visit.",
            Json.object("type", "object", "properties", new LinkedHashMap<String, Object>()),
            args -> call("/api/sites", new ArrayList<>()),
            null),
        new Tool(
            "get_stats",
            "Headline numbers",
            "Visitors, visits, pageviews, views per visit, bounce rate (0 to 1), and visit duration"
                + " (milliseconds) for a range, with the comparison range's numbers as previous.",
            Json.object("type", "object", "properties", props(List.of(RANGE, COMPARE))),
            read("/api/stats", COMPARE_KEYS),
            null),
        new Tool(
            "get_timeseries",
            "Numbers over time",
            "The headline numbers for each hour, day, week, or month of a range, with the"
                + " comparison range's points lined up by position.",
            Json.object(
                "type",
                "object",
                "properties",
                props(
                    List.of(RANGE, COMPARE),
                    "interval",
                    Json.object(
                        "type",
                        "string",
                        "enum",
                        List.of("hour", "day", "week", "month"),
                        "description",
                        "Chosen from the range when left out."))),
            read("/api/series", plus(COMPARE_KEYS, "interval")),
            null),
        new Tool(
            "get_breakdown",
            "Top values of a dimension",
            "Rows for one dimension, most visitors first: pages, entry and exit pages, referrers,"
                + " sources, channels (Direct, Organic Search, Social, AI, and so on), UTM tags,"
                + " countries, regions, cities, browsers, operating systems, devices, screens,"
                + " languages, custom events, and AI agents that fetched pages (ai_agent,"
                + " ai_page).",
            Json.object(
                "type",
                "object",
                "properties",
                props(
                    List.of(RANGE),
                    "dimension",
                    Json.object("type", "string", "enum", Query.DIMENSIONS),
                    "limit",
                    Json.object(
                        "type",
                        "integer",
                        "minimum",
                        1L,
                        "maximum",
                        100L,
                        "description",
                        "Rows to return. Defaults to 10."),
                    "page",
                    Json.object(
                        "type",
                        "integer",
                        "minimum",
                        1L,
                        "description",
                        "For more rows: 2 is the next limit rows.")),
                "required",
                List.of("dimension")),
            read(
                "/api/breakdown",
                plus(RANGE_KEYS, "dimension", "page"),
                args -> List.of(Map.entry("limit", limit(Js.get(args, "limit"), 10)))),
            null),
        new Tool(
            "list_funnels",
            "Funnels",
            "Every funnel with how many visits reached each step in order within the same visit."
                + " Divide a step by the one before it for that step's conversion rate.",
            Json.object("type", "object", "properties", props(List.of(RANGE))),
            read("/api/funnels", RANGE_KEYS),
            null),
        new Tool(
            "get_event_properties",
            "An event's properties",
            "The properties sent with one custom event and the values each took, most common"
                + " first. Automatic events have their own: \"Outbound link\" and \"File download\""
                + " carry url, and \"404\" carries path. Leave key out to see every property name"
                + " and the values of the most used one.",
            Json.object(
                "type",
                "object",
                "properties",
                props(
                    List.of(RANGE),
                    "event",
                    Json.object(
                        "type",
                        "string",
                        "description",
                        "The event's name, as get_breakdown with dimension event lists it."),
                    "key",
                    Json.object(
                        "type",
                        "string",
                        "description",
                        "Which property. Defaults to the most used one."),
                    "limit",
                    Json.object(
                        "type",
                        "integer",
                        "minimum",
                        1L,
                        "maximum",
                        100L,
                        "description",
                        "Values to return. Defaults to 25.")),
                "required",
                List.of("event")),
            read(
                "/api/event-props",
                plus(RANGE_KEYS, "event", "key"),
                args -> List.of(Map.entry("limit", limit(Js.get(args, "limit"), 25)))),
            null),
        new Tool(
            "get_visit_times",
            "When people visit",
            "Visits by weekday and hour in the site's timezone: grid[weekday][hour], Monday first,"
                + " hours 0 to 23.",
            Json.object("type", "object", "properties", props(List.of(RANGE))),
            read("/api/rhythm", RANGE_KEYS),
            body ->
                Json.object(
                    "site",
                    prop(body, "site"),
                    "range",
                    Js.get(body, "range"),
                    "weekdays",
                    List.of("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"),
                    "grid",
                    Js.get(body, "grid"))),
        new Tool(
            "get_realtime",
            "Right now",
            "People on the site in the last five minutes, the pages they are reading, where they"
                + " came from, their countries, and the latest activity.",
            Json.object("type", "object", "properties", Json.object("site", site)),
            read("/api/realtime", List.of("site")),
            null),
        new Tool(
            "list_goals",
            "Goals and conversions",
            "Every goal with its conversions, converted visitors, conversion rate (0 to 1), and"
                + " revenue for a range, with the comparison range's numbers as previous.",
            Json.object("type", "object", "properties", props(List.of(RANGE, COMPARE))),
            read("/api/goals", COMPARE_KEYS),
            null),
        new Tool(
            "get_goal",
            "One goal in detail",
            "One goal's conversions over time and by channel, source, and page. Find the goal_id"
                + " with list_goals.",
            Json.object(
                "type",
                "object",
                "properties",
                props(List.of(RANGE), "goal_id", Json.object("type", "string")),
                "required",
                List.of("goal_id")),
            args -> {
              Object id = Js.get(args, "goal_id");
              return call(
                  "/api/goals/"
                      + Js.encodeURIComponent(
                          Js.string(id == null || id == Json.UNDEFINED ? "" : id)),
                  rangeParams(args, RANGE_KEYS));
            },
            null),
        new Tool(
            "get_journeys",
            "Paths through the site",
            "The paths visits take, page by page: the top pages at each step, how many went no"
                + " further, the flows between steps, and the commonest whole paths. A refresh"
                + " counts once. start and end follow only paths from or to a page.",
            Json.object(
                "type",
                "object",
                "properties",
                props(
                    List.of(RANGE),
                    "steps",
                    Json.object(
                        "type",
                        "integer",
                        "minimum",
                        2L,
                        "maximum",
                        8L,
                        "description",
                        "How many pages of each path. Defaults to 5."),
                    "start",
                    Json.object(
                        "type",
                        "string",
                        "description",
                        "Only paths from this page, such as /pricing."),
                    "end",
                    Json.object(
                        "type",
                        "string",
                        "description",
                        "Only paths that reach this page, cut there."))),
            read("/api/journeys", plus(RANGE_KEYS, "steps", "start", "end")),
            null),
        new Tool(
            "list_links",
            "Short links",
            "Every short link with its destination and its clicks in the range.",
            Json.object(
                "type",
                "object",
                "properties",
                Json.object(
                    "site",
                    site,
                    "period",
                    RANGE.get("period"),
                    "from",
                    RANGE.get("from"),
                    "to",
                    RANGE.get("to"))),
            read("/api/links", List.of("site", "period", "from", "to")),
            null));
  }

  /**
   * value[key] where JavaScript would throw a TypeError reading a property of null or undefined.
   */
  static Object prop(Object value, String key) {
    if (value == null || value == Json.UNDEFINED) {
      throw new IllegalArgumentException(
          "Cannot read properties of " + Js.string(value) + " (reading '" + key + "')");
    }
    return Js.get(value, key);
  }

  private static Map<String, Object> rpcError(Object id, int code, String message) {
    return Json.object(
        "jsonrpc",
        "2.0",
        "id",
        id == null || id == Json.UNDEFINED ? null : id,
        "error",
        Json.object("code", (long) code, "message", message));
  }

  /**
   * Runs one tool by name, as the MCP server does; the dashboard's assistant calls it too.
   *
   * @param params name and arguments
   * @return content, a list of one text part, and isError when the API refused
   * @throws McpError for an unknown tool
   */
  public static Map<String, Object> callTool(Object params, ApiRead readApi) {
    Object name = Js.get(params, "name");
    Tool tool = null;
    for (Tool one : TOOLS) {
      if (one.name().equals(name)) {
        tool = one;
        break;
      }
    }
    if (tool == null) {
      throw new McpError("Unknown tool \"" + Js.string(name) + "\"", -32602);
    }
    Object given = Js.get(params, "arguments");
    Object args = Js.truthy(given) && Js.isObject(given) ? given : new LinkedHashMap<>();
    Map<String, Object> request = tool.request().apply(args);
    @SuppressWarnings("unchecked")
    List<Map.Entry<String, String>> query = (List<Map.Entry<String, String>>) request.get("params");
    Response answer = readApi.read((String) request.get("path"), query);
    Json.Parsed parsed = Json.tryParse(answer.text());
    Object body = parsed.ok() ? parsed.value() : new LinkedHashMap<String, Object>();
    // Any body that is not an object (null included) carries no words of its own.
    Object object = body instanceof Map<?, ?> ? body : null;
    if (!answer.ok()) {
      Object error = object == null ? null : prop(object, "error");
      return Json.object(
          "content",
          List.of(
              Json.object(
                  "type",
                  "text",
                  "text",
                  Js.string(
                      error == null || error == Json.UNDEFINED
                          ? "Runlight answered " + answer.status()
                          : error))),
          "isError",
          true);
    }
    return Json.object(
        "content",
        List.of(
            Json.object(
                "type",
                "text",
                "text",
                Json.stringify(
                    tool.shape() != null && object != null ? tool.shape().apply(object) : body))));
  }

  /** The answer to one message, or null for a notification. */
  private static Map<String, Object> answer(Object message, ApiRead readApi) {
    // A batch element that is not an object is an invalid request, answered with a null id.
    if (!(message instanceof Map<?, ?>)) {
      return rpcError(null, -32600, "Invalid request");
    }
    Object id = prop(message, "id");
    boolean isNotification = id == Json.UNDEFINED;
    Object method = Js.get(message, "method");
    if (!"2.0".equals(Js.get(message, "jsonrpc")) || !(method instanceof String name)) {
      return isNotification ? null : rpcError(id, -32600, "Invalid request");
    }
    // A notification is never answered, so it never runs anything either.
    if (isNotification) {
      return null;
    }
    Object given = Js.get(message, "params");
    Object params = Js.truthy(given) && Js.isObject(given) ? given : new LinkedHashMap<>();
    try {
      Map<String, Object> result;
      switch (name) {
        case "initialize" -> {
          Object asked = Js.get(params, "protocolVersion");
          String version = Js.string(asked == null || asked == Json.UNDEFINED ? "" : asked);
          result =
              Json.object(
                  "protocolVersion",
                  PROTOCOL_VERSIONS.contains(version) ? version : PROTOCOL_VERSIONS.get(0),
                  "capabilities",
                  Json.object("tools", Json.object("listChanged", false)),
                  "serverInfo",
                  Json.object(
                      "name", "runlight", "title", "Runlight", "version", Version.version()),
                  "instructions",
                  INSTRUCTIONS);
        }
        case "ping" -> result = new LinkedHashMap<>();
        case "tools/list" -> {
          List<Object> tools = new ArrayList<>();
          for (Tool t : TOOLS) {
            tools.add(
                Json.object(
                    "name",
                    t.name(),
                    "title",
                    t.title(),
                    "description",
                    t.description(),
                    "inputSchema",
                    t.inputSchema(),
                    "annotations",
                    Json.object("readOnlyHint", true, "openWorldHint", false)));
          }
          result = Json.object("tools", tools);
        }
        case "tools/call" -> result = callTool(params, readApi);
        default -> {
          return rpcError(id, -32601, "Unknown method \"" + name + "\"");
        }
      }
      return Json.object("jsonrpc", "2.0", "id", id, "result", result);
    } catch (RuntimeException error) {
      return error instanceof McpError e && e.code() != 0
          ? rpcError(id, e.code(), e.getMessage())
          : rpcError(id, -32603, "Internal error");
    }
  }

  private static Headers jsonHeaders() {
    return Headers.of(
        "content-type", "application/json; charset=utf-8", "cache-control", "no-store");
  }

  /** Answers one POST to the MCP endpoint, already authorised. */
  public static Response mcpResponse(Request request, ApiRead readApi) {
    Json.Parsed parsed = Json.tryParse(request.text());
    Object body = parsed.ok() ? parsed.value() : Json.UNDEFINED;
    if (!Js.isObject(body)) {
      return new Response(
          Json.stringify(rpcError(null, -32700, "Send a JSON-RPC message")), 400, jsonHeaders());
    }
    // Batches were in the 2025-03-26 protocol; answering them costs nothing.
    if (body instanceof List<?> batch) {
      List<Object> answers = new ArrayList<>();
      for (Object message : batch) {
        Map<String, Object> one = answer(message, readApi);
        if (one != null) {
          answers.add(one);
        }
      }
      return answers.isEmpty()
          ? new Response("", 202)
          : new Response(Json.stringify(answers), 200, jsonHeaders());
    }
    Map<String, Object> one = answer(body, readApi);
    return one != null
        ? new Response(Json.stringify(one), 200, jsonHeaders())
        : new Response("", 202);
  }
}
