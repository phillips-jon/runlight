package sh.runlight;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.AbstractMap;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.WeakHashMap;
import java.util.concurrent.ConcurrentHashMap;
import java.util.function.BiPredicate;
import java.util.function.Function;
import java.util.function.Supplier;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import sh.runlight.CodedError.FunnelError;
import sh.runlight.CodedError.GoalError;
import sh.runlight.CodedError.LinkError;
import sh.runlight.CodedError.SettingsError;
import sh.runlight.accounts.AccountError;
import sh.runlight.accounts.Web;
import sh.runlight.http.FetchError;
import sh.runlight.http.FetchInit;
import sh.runlight.http.Headers;
import sh.runlight.http.Request;
import sh.runlight.http.Response;
import sh.runlight.http.SearchParams;
import sh.runlight.http.Url;
import sh.runlight.importers.ImportError;
import sh.runlight.importers.Index;
import sh.runlight.importers.Visits;
import sh.runlight.mail.MailError;
import sh.runlight.mail.Transports;
import sh.runlight.store.SqlStore;

/**
 * The dashboard, its API, the tracker, the MCP server, and OAuth, under one base path, as routes.ts
 * serves them. See {@link Options} for what an app passes.
 */
public final class Routes {
  public static final String COOKIE = "runlight_token";

  /** Which implementation answers, for GET /api. */
  public static final Map<String, Object> IMPLEMENTATION =
      Collections.unmodifiableMap(
          Json.object("library", "sh.runlight:runlight", "language", "java"));

  /** API tokens start with this, so they are told apart from the main token. */
  public static final String TOKEN_PREFIX = "rl_";

  /** The header a shared dashboard sends its share id in. */
  public static final String SHARE_HEADER = "x-runlight-share";

  /** What a share can read: one site's reports, nothing that changes anything. */
  public static final List<String> SHARED_PATHS =
      List.of(
          "/api/sites",
          "/api/icon",
          "/api/realtime",
          "/api/stats",
          "/api/series",
          "/api/rhythm",
          "/api/breakdown",
          "/api/goals",
          "/api/event-props",
          "/api/export",
          "/api/funnels",
          "/api/journeys");

  /** Where the tracker's click rules go; the script ships with this string in their place. */
  private static final String RULES_PLACEHOLDER = "\"__RUNLIGHT_RULES__\"";

  /** Where the picker's one allowed receiver goes, the dashboard origin its ticket names. */
  private static final String PICK_TARGET_PLACEHOLDER = "\"__RUNLIGHT_PICK_TARGET__\"";

  /** Where the hostnames of the site its ticket names go, as JSON inside a string. */
  private static final String PICK_HOSTS_PLACEHOLDER = "\"__RUNLIGHT_PICK_HOSTS__\"";

  /** How long a picker ticket works: long enough to find the element, not to be kept. */
  public static final long PICK_TICKET_MS = 30 * 60_000L;

  /** Questions one person may put to the assistant in an hour, and at once. */
  public static final int ASK_PER_HOUR = 30;

  public static final int ASK_AT_ONCE = 2;

  /** Questions each viewer may ask a day, until an owner sets another number. */
  public static final long VIEWER_DAILY = 50;

  private static final Pattern SHARE_ID = Pattern.compile("^[a-f0-9]{32}\\z");
  private static final List<String> PATH_DIMENSIONS = List.of("page", "entry", "exit", "ai_page");

  public static final String DASHBOARD_CSP =
      "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

  /** A domain name, such as go.example.com. */
  public static final Pattern DOMAIN_NAME =
      Pattern.compile(
          "^(?=" + Js.DOT + "{1,253}\\z)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}\\z");

  private static final Pattern PRIVATE_IP =
      Pattern.compile("(^|\\.)\\d{1,3}(\\.\\d{1,3}){3}(\\.|\\z)");
  private static final Pattern PRIVATE_SUFFIX =
      Pattern.compile(
          "\\.(internal|intranet|private|local|localhost|localdomain|lan|home|corp|home\\.arpa|arpa|test|invalid|example)\\z");
  private static final String NO = "[^" + Js.SPACE + "@<>\"]+";
  private static final Pattern EMAIL = Pattern.compile("^" + NO + "@" + NO + "\\." + NO + "\\z");
  private static final Pattern ORIGIN = Pattern.compile("^https?://[^/?#" + Js.SPACE + "]+\\z");
  private static final Pattern HOME = Pattern.compile("^https?://[^" + Js.SPACE + "]+\\z");
  private static final Pattern FILENAME = Pattern.compile("filename=\"([A-Za-z0-9._-]+)\"");
  private static final Pattern ERROR_CODE = Pattern.compile("^[a-z_]{1,40}\\z");
  private static final Pattern GOAL_PAGE = Pattern.compile("^/api/goals/[a-f0-9]{24}\\z");
  private static final Pattern SITE_PATH = Pattern.compile("^/api/sites/([^/]+)\\z");
  private static final Pattern MANAGED =
      Pattern.compile("^/api/(links|link-domains|reports|goals|funnels|shares)(/|\\z)");
  private static final Pattern DOMAIN_CHECK =
      Pattern.compile("^/api/link-domains/([^/]+)/check\\z");
  private static final Pattern DOMAIN_PATH = Pattern.compile("^/api/link-domains/([^/]+)\\z");
  private static final Pattern IMPORT_PATH = Pattern.compile("^/api/links/import/([a-z]+)\\z");
  private static final Pattern LINK_PATH = Pattern.compile("^/api/links/([a-f0-9]+)\\z");
  private static final Pattern TICKET =
      Pattern.compile("^(\\d+)\\.([a-f0-9]{2,512})\\.([a-f0-9]{2,512})\\.([a-f0-9]{64})\\z");
  private static final Pattern REPORT_PATH =
      Pattern.compile("^/api/reports/([a-f0-9]{24})(/send)?\\z");
  private static final Pattern REPORT_TOKEN = Pattern.compile("^[a-f0-9]{32}\\z");
  private static final Pattern TOKEN_PATH = Pattern.compile("^/api/tokens/([a-f0-9]{24})\\z");
  private static final Pattern FUNNEL_PATH = Pattern.compile("^/api/funnels/[a-f0-9]{24}\\z");
  private static final Pattern GOAL_WRITE = Pattern.compile("^/api/goals/[^/]+\\z");
  private static final Pattern GOAL_READ = Pattern.compile("^/api/goals/([a-f0-9]{24})\\z");
  private static final Pattern THROUGH = Pattern.compile("^(\\d+):(" + Js.DOT + "+)\\z");
  private static final Pattern LANGUAGE = Pattern.compile("^[a-z]{2}\\z");
  private static final Pattern LOCALE =
      Pattern.compile("^/assets/locale\\.([a-z]{2,3})\\.([a-f0-9]+)\\.json\\z");
  private static final Pattern UNSUBSCRIBE = Pattern.compile("^/unsubscribe/([^/]+)/?\\z");
  private static final Pattern SHARE_PAGE = Pattern.compile("^/share/([^/]+)/?\\z");

  /**
   * What routes() takes, with the TypeScript names.
   *
   * <ul>
   *   <li>basePath: where the routes are mounted. Default "/runlight".
   *   <li>token: required to read stats. Send it as {@code Authorization: Bearer <token>}, or open
   *       the dashboard once with {@code ?token=<token>} and a cookie is set. Unset means
   *       RUNLIGHT_TOKEN. Without one, the dashboard and API are open only when NODE_ENV is
   *       "development", and answer 503 everywhere else. Set to null to leave them open everywhere,
   *       for example behind your own auth.
   *   <li>authorize: your own check instead of a token. True is full access, "member" changes
   *       everything but the install-wide controls (the mail service, the assistant's settings, and
   *       deleting a site), "read" reads every site's stats and changes nothing.
   *   <li>cronSecret: also accepted as a bearer token on POST /api/check. Defaults to CRON_SECRET.
   *   <li>observeKey: lets another site report AI agent fetches to POST /api/observe. Defaults to
   *       RUNLIGHT_OBSERVE_KEY.
   *   <li>signOut, signIn: links the dashboard shows. The standalone server sets them.
   *   <li>accounts: true for sign-in accounts, or a {@link Web} of your own.
   *   <li>geoCredit: credits DB-IP in the dashboard's footer.
   *   <li>origin: the address people open the app at, such as https://example.com.
   *   <li>ownHosts: more names the dashboard is reached at.
   *   <li>accountOf: the account a request comes from (internal, for the standalone server).
   *   <li>tokenMade: notes who made a token (internal).
   * </ul>
   */
  public static final class Options {
    public String basePath;
    public String token;
    public boolean tokenSet;
    public Function<Request, Object> authorize;
    public String cronSecret;
    public String observeKey;
    public String signOut;
    public String signIn;
    public Object accounts;
    public boolean geoCredit;
    public String origin;
    public Supplier<Iterable<String>> ownHosts;
    public Function<Request, String> accountOf;
    public BiPredicate<Map<String, Object>, String> tokenMade;

    public Options basePath(String value) {
      basePath = value;
      return this;
    }

    /** The token; null leaves the routes open on purpose. */
    public Options token(String value) {
      token = value;
      tokenSet = true;
      return this;
    }

    public Options authorize(Function<Request, Object> value) {
      authorize = value;
      return this;
    }

    public Options cronSecret(String value) {
      cronSecret = value;
      return this;
    }

    public Options observeKey(String value) {
      observeKey = value;
      return this;
    }

    public Options signOut(String value) {
      signOut = value;
      return this;
    }

    public Options signIn(String value) {
      signIn = value;
      return this;
    }

    /** True for sign-in accounts, or a {@link Web} of your own. */
    public Options accounts(Object value) {
      accounts = value;
      return this;
    }

    public Options geoCredit(boolean value) {
      geoCredit = value;
      return this;
    }

    public Options origin(String value) {
      origin = value;
      return this;
    }

    public Options ownHosts(Supplier<Iterable<String>> value) {
      ownHosts = value;
      return this;
    }

    public Options accountOf(Function<Request, String> value) {
      accountOf = value;
      return this;
    }

    public Options tokenMade(BiPredicate<Map<String, Object>, String> value) {
      tokenMade = value;
      return this;
    }
  }

  private final Runlight rl;
  private final String base;
  private final String token;
  private final String cronSecret;
  private final String observeKey;
  private final String origin;
  private final Options options;
  private volatile boolean warned;
  private final Web web;
  private final String signIn;
  private final String signOut;
  private final Function<Request, String> accountOf;
  private final BiPredicate<Map<String, Object>, String> tokenMade;
  private final OAuth.Context oauth;

  /** Requests from a manage token, already checked against its one site, act as the owner's. */
  private final Map<Request, Map<String, Object>> managed =
      Collections.synchronizedMap(new WeakHashMap<>());

  /** Requests from a member: full access apart from the install-wide controls. */
  private final Map<Request, Boolean> members = Collections.synchronizedMap(new WeakHashMap<>());

  /** When a sample report last went out, per report, or per site for a hub. */
  private final Map<String, Long> sampleSent = new ConcurrentHashMap<>();

  /** Questions to the assistant in the last hour, and being answered now, per person. */
  private static final class Asked {
    List<Long> at = new ArrayList<>();
    int open;
  }

  private final Map<String, Asked> asked = new LinkedHashMap<>();

  private record Script(String body, String etag, long at) {}

  /** The tracker per site, rebuilt when goals change. */
  private final Map<String, Script> trackers = new ConcurrentHashMap<>();

  private static volatile Map<String, Object> locales;

  public Routes(Runlight runlight, Options given) {
    Options options = given != null ? given : new Options();
    this.rl = runlight;
    this.options = options;
    this.base = normaliseBase(options.basePath != null ? options.basePath : "/runlight");
    // Null leaves the routes open on purpose; an unset RUNLIGHT_TOKEN is no token (""), never open.
    String envToken = Env.get("RUNLIGHT_TOKEN");
    this.token = options.tokenSet ? options.token : envToken != null ? envToken : "";
    this.cronSecret = options.cronSecret != null ? options.cronSecret : Env.get("CRON_SECRET");
    this.observeKey =
        options.observeKey != null ? options.observeKey : Env.get("RUNLIGHT_OBSERVE_KEY");
    this.origin =
        options.origin != null && !options.origin.isEmpty()
            ? new Url(options.origin).origin()
            : null;
    // A link domain leaves these paths to the app, so the dashboard stays reachable on every name.
    String mount = !base.isEmpty() ? base : "/";
    synchronized (runlight.routeBases) {
      if (!runlight.routeBases.contains(mount)) {
        runlight.routeBases.add(mount);
      }
    }

    // Accounts: the standalone server passes its own, and an app turns them on with true. Sessions
    // need a secret that outlives the process; in development without one, a made-up one does, so a
    // restart signs everyone out. An app left open on purpose (token null) is treated like
    // development here.
    boolean openSetup = token == null || (token.isEmpty() && isDevelopment());
    String accountSecret =
        runlight.secret != null ? runlight.secret : openSetup ? Hash.randomId(32) : null;
    if (options.accounts instanceof Web own) {
      this.web = own;
    } else if (Boolean.TRUE.equals(options.accounts)
        && accountSecret != null
        && !accountSecret.isEmpty()) {
      Map<String, Object> settings = new LinkedHashMap<>();
      settings.put("runlight", runlight);
      settings.put("secret", accountSecret);
      settings.put("base", base);
      settings.put("now", (java.util.function.LongSupplier) runlight::now);
      // The app's token proves who may make the first account; in development without one,
      // anyone may.
      settings.put(
          "firstAccount",
          token != null && !token.isEmpty()
              ? Json.object("token", token)
              : openSetup ? "open" : "locked");
      settings.put("forgot", "https://runlight.sh/docs/configuration/#accounts");
      if (origin != null) {
        String home = origin;
        settings.put("home", (Supplier<String>) () -> home);
      }
      this.web = new Web(settings);
    } else {
      this.web = null;
    }

    Web w = web;
    this.signIn = options.signIn != null ? options.signIn : w != null ? base + "/login" : null;
    this.signOut = options.signOut != null ? options.signOut : w != null ? base + "/logout" : null;
    this.accountOf =
        options.accountOf != null ? options.accountOf : w != null ? w::accountOf : null;
    this.tokenMade =
        options.tokenMade != null ? options.tokenMade : w != null ? w::tokenMade : null;
    Function<Request, Object> authorize = options.authorize;
    OAuth.Context context = new OAuth.Context(runlight, base, r -> Boolean.TRUE.equals(canRead(r)));
    context.isReader =
        r ->
            authorize != null
                ? "read".equals(authorize.apply(r))
                : w != null && "read".equals(w.access(r));
    if (signIn != null && !signIn.isEmpty()) {
      context.signIn = signIn;
    }
    context.accountOf = accountOf;
    context.tokenMade = tokenMade;
    this.oauth = context;
  }

  /** The accounts on the web these routes serve, or null when there are none. */
  public Web web() {
    return web;
  }

  // Helpers that need nothing of an instance.

  static String escapeHtml(String value) {
    StringBuilder out = new StringBuilder(value.length());
    for (int i = 0; i < value.length(); i++) {
      char c = value.charAt(i);
      switch (c) {
        case '&' -> out.append("&amp;");
        case '<' -> out.append("&lt;");
        case '>' -> out.append("&gt;");
        case '"' -> out.append("&quot;");
        case '\'' -> out.append("&#39;");
        default -> out.append(c);
      }
    }
    return out.toString();
  }

  /**
   * The discovery documents OAuth clients read: two of OAuth's own, and OpenID's, which some
   * clients try first.
   */
  private static boolean isOauthDocument(String path) {
    return path.startsWith("/.well-known/oauth-")
        || path.startsWith("/.well-known/openid-configuration");
  }

  private static boolean isDevelopment() {
    return "development".equals(Env.get("NODE_ENV"));
  }

  /**
   * An error the dashboard can show in its own language: code names it and params fill its
   * placeholders, while error stays the English message.
   */
  public static Response coded(String error, String code, int status) {
    return coded(error, code, status, null, Map.of());
  }

  public static Response coded(String error, String code, int status, Map<String, ?> params) {
    return coded(error, code, status, params, Map.of());
  }

  public static Response coded(
      String error, String code, int status, Map<String, ?> params, Map<String, String> headers) {
    Map<String, Object> body = Json.object("error", error, "code", code);
    if (params != null) {
      body.put("params", new LinkedHashMap<String, Object>(params));
    }
    return json(body, status, headers);
  }

  /**
   * A refusal from a check elsewhere: its own code and params when the error carries them, or else
   * fallback with its English words as detail.
   */
  private static Response refused(RuntimeException error, String fallback) {
    return refused(error, fallback, 400);
  }

  private static Response refused(RuntimeException error, String fallback, int status) {
    if (error instanceof CodedError coded && coded.code() != null) {
      return coded(error.getMessage(), coded.code(), status, paramsOf(coded));
    }
    return coded(error.getMessage(), fallback, status, Json.object("detail", error.getMessage()));
  }

  /** An error's params, an empty object when it has none, as the TypeScript's default. */
  private static Map<String, Object> paramsOf(CodedError error) {
    return error.params() == null ? Map.of() : error.params();
  }

  /**
   * Whether an error is one the SDK throws as a RangeError: a setting refused, or a thing unknown.
   */
  private static boolean isRange(RuntimeException error) {
    return error instanceof SettingsError
        || error instanceof ConnectError
        || error instanceof AccountError
        || error instanceof RangeError;
  }

  public static Response json(Object body) {
    return json(body, 200, Map.of());
  }

  public static Response json(Object body, int status) {
    return json(body, status, Map.of());
  }

  public static Response json(Object body, int status, Map<String, String> headers) {
    Headers out =
        Headers.of(
            "content-type",
            "application/json; charset=utf-8",
            "cache-control",
            "no-store",
            "x-content-type-options",
            "nosniff");
    for (Map.Entry<String, String> e : headers.entrySet()) {
      out.set(e.getKey(), e.getValue());
    }
    return new Response(Json.stringify(body), status, out);
  }

  /**
   * Whether a request's body is JSON by its media type. A cross-site form or a no-cors fetch can
   * only send text/plain, urlencoded, or multipart, so a JSON media type proves the request came
   * from a page allowed to send it. A substring test would accept "text/plain; application/json",
   * which can.
   */
  public static boolean isJson(Request request) {
    String type = request.headers().get("content-type");
    return Js.lower(Js.trim((type == null ? "" : type).split(";", -1)[0]))
        .equals("application/json");
  }

  /**
   * A Host or X-Forwarded-Host value as a bare name: lowercase, with no port, no final dot, and no
   * www.
   */
  public static String hostName(String value) {
    String first = Js.lower(Js.trim(value.split(",", -1)[0]));
    String name;
    if (first.startsWith("[")) {
      int close = first.indexOf(']');
      name = close < 0 ? "" : first.substring(0, close + 1);
    } else {
      name = first.replaceFirst(":\\d*\\z", "");
    }
    return name.replaceFirst("\\.+\\z", "").replaceFirst("^www\\.", "");
  }

  /**
   * Whether a domain name is one kept for private networks or tests, or has an IPv4 address inside
   * it (as nip.io answers). The link-domain check fetches from it, so a name inside the install's
   * own network must never get that far; names that only resolve there are refused when fetched.
   */
  private static boolean privateName(String domain) {
    return PRIVATE_IP.matcher(domain).find() || PRIVATE_SUFFIX.matcher(domain).find();
  }

  /**
   * What passes for an email address: something@somewhere.tld, with no spaces, quotes, or angle
   * brackets.
   */
  private static boolean isEmail(String value) {
    return EMAIL.matcher(value).find();
  }

  /** An object's entries, or an array's as index and value, as Object.entries reads them. */
  private static List<Map.Entry<String, Object>> entriesOf(Object value) {
    if (value instanceof Map<?, ?> map) {
      return Js.entries(map);
    }
    List<Map.Entry<String, Object>> out = new ArrayList<>();
    if (value instanceof List<?> list) {
      for (int i = 0; i < list.size(); i++) {
        out.add(new AbstractMap.SimpleImmutableEntry<>(String.valueOf(i), list.get(i)));
      }
    }
    return out;
  }

  /**
   * Answers a read for a site counted by another install by asking that install, with its token and
   * its own id for the site, and handing back what it says.
   */
  private Response passThrough(Map<String, Object> remote, String path, Url url, Request request) {
    Url target = new Url(remote.get("url") + path);
    SearchParams query = target.searchParams();
    for (Map.Entry<String, String> e : url.searchParams().entries()) {
      query.append(e.getKey(), e.getValue());
    }
    query.set("site", Js.string(remote.get("site")));
    target.setSearchParams(query);
    // A change made from the hub goes on to the install with its JSON body; reads carry none.
    boolean write =
        request != null && !request.method().equals("GET") && !request.method().equals("HEAD");
    FetchInit init =
        new FetchInit()
            .method(write ? request.method() : "GET")
            .header("authorization", "Bearer " + remote.get("token"))
            // An install that answers with a redirect gets no fetch of somewhere else on its
            // behalf.
            .redirect("manual")
            // A long report or an export is worked out in full before the install sends a byte, so
            // reads get two minutes.
            .timeoutMs(write ? 30_000 : 120_000);
    if (write && Js.truthy(request.headers().get("content-type"))) {
      init.header("content-type", request.headers().get("content-type"));
    }
    if (write) {
      init.body(request.bytes());
    }
    String host = new Url(Js.string(remote.get("url"))).host();
    Response answer;
    try {
      answer = rl.fetcher.fetch(target.href(), init);
    } catch (RuntimeException error) {
      if (error instanceof FetchError f && f.timedOut()) {
        return coded(
            host + " took too long to answer. Try a shorter range.",
            "remote_slow",
            504,
            Json.object("host", host));
      }
      return coded("Could not reach " + host, "unreachable", 502, Json.object("host", host));
    }
    // What comes back is shown from this server's origin, so it is never taken as a page: JSON, or
    // a download for exports, with sniffing off and nothing allowed to run.
    boolean download =
        path.equals("/api/export")
            || (path.equals("/api/breakdown") && "csv".equals(url.searchParams().get("format")));
    String type = answer.headers().get("content-type");
    Map<String, String> back = new LinkedHashMap<>();
    back.put("cache-control", "private, no-store");
    back.put("x-content-type-options", "nosniff");
    back.put("content-security-policy", "default-src 'none'; frame-ancestors 'none'");
    back.put(
        "content-type",
        download
            ? (type != null && type.startsWith("text/csv")
                ? "text/csv; charset=utf-8"
                : "application/zip")
            : "application/json; charset=utf-8");
    if (download) {
      String disposition = answer.headers().get("content-disposition");
      Matcher m = FILENAME.matcher(disposition == null ? "" : disposition);
      back.put(
          "content-disposition",
          "attachment; filename=\"" + (m.find() ? m.group(1) : "runlight-export") + "\"");
    }
    if (answer.status() >= 300 && answer.status() < 400) {
      return coded(
          host + " answered with a redirect", "redirected", 502, Json.object("host", host));
    }
    // The install's own errors say what went wrong there; a refused token is this server's problem
    // to report.
    if (answer.status() == 401) {
      return coded(
          host + " refused the token. Connect it again from the site's settings.",
          "token_refused",
          502,
          Json.object("host", host));
    }
    // An install's own error is shown here, so it says where it came from, keeps only short text,
    // and carries its code and params for the dashboard to put in its own words.
    if (answer.status() >= 400 && !download) {
      String text;
      try {
        text = answer.text();
      } catch (RuntimeException e) {
        text = "";
      }
      Object body = null;
      if (text.length() <= 65_536) {
        Json.Parsed parsed = Json.tryParse(text);
        body = parsed.ok() && Js.isObject(parsed.value()) ? parsed.value() : null;
      }
      Object given = body == null ? null : Js.get(body, "params");
      List<String[]> params = new ArrayList<>();
      if (Js.truthy(given) && Js.isObject(given)) {
        for (Map.Entry<String, Object> e : entriesOf(given)) {
          if (e.getValue() instanceof String v) {
            params.add(new String[] {Js.slice(e.getKey(), 0, 40), Js.slice(v, 0, 200)});
          }
        }
        params = params.subList(0, Math.min(10, params.size()));
      }
      Object error = body == null ? null : Js.get(body, "error");
      Map<String, Object> out =
          Json.object(
              "error",
              host
                  + ": "
                  + (error instanceof String s
                      ? Js.slice(s, 0, 300)
                      : "answered " + answer.status()));
      Object code = body == null ? null : Js.get(body, "code");
      if (code instanceof String c && ERROR_CODE.matcher(c).find()) {
        out.put("code", c);
        Map<String, Object> fields = new LinkedHashMap<>();
        for (String[] p : params) {
          fields.put(p[0], p[1]);
        }
        out.put("params", fields);
      }
      return json(out, answer.status(), back);
    }
    return new Response(answer.bytes(), answer.status(), Headers.of(back));
  }

  /** A plain page in a visitor's language, for unsubscribing and for a share link that is gone. */
  private static Response smallPage(String lang, String body, int status) {
    return new Response(
        "<!doctype html><html lang=\""
            + lang
            + "\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><meta name=\"robots\" content=\"noindex\"><title>Runlight</title>\n"
            + "<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#f4f4f5;font:16px/1.5 -apple-system,BlinkMacSystemFont,\"Segoe UI\",Helvetica,Arial,sans-serif;color:#111827}main{max-width:420px;margin:24px;padding:32px;background:#fff;border:1px solid #e5e7eb;border-radius:14px}h1{font-size:20px;margin:0 0 12px}p{margin:0 0 20px;color:#4b5563}button{height:40px;padding:0 18px;border:0;border-radius:8px;background:#111827;color:#fff;font:inherit;font-weight:600;cursor:pointer}</style></head><body><main>"
            + body
            + "</main></body></html>",
        status,
        Headers.of(
            "content-type",
            "text/html; charset=utf-8",
            "cache-control",
            "no-store",
            "content-security-policy",
            "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'",
            "referrer-policy",
            "no-referrer"));
  }

  /** The first language a browser asks for that the dashboard speaks, else English. */
  private static String acceptedLanguage(Request request) {
    String header = request.headers().get("accept-language");
    for (String part : (header == null ? "" : header).split(",", -1)) {
      String code = Js.lower(Js.slice(Js.trim(part.split(";", -1)[0]), 0, 2));
      if (Messages.languages().contains(code)) {
        return code;
      }
    }
    return "en";
  }

  /**
   * Rows of objects as CSV, with a column for every key the first row has, in the units a
   * spreadsheet reads.
   */
  private static String rowsCsv(List<Map<String, Object>> rows, Map<String, Object> sheet) {
    List<Map<String, Object>> readable = new ArrayList<>();
    for (Map<String, Object> r : rows) {
      readable.add(sheetRow(r, sheet));
    }
    List<String> header =
        readable.isEmpty() ? List.of("value") : new ArrayList<>(Js.keys(readable.get(0)));
    List<List<Object>> lines = new ArrayList<>();
    for (Map<String, Object> r : readable) {
      List<Object> line = new ArrayList<>();
      for (String k : header) {
        line.add(r.containsKey(k) ? r.get(k) : null);
      }
      lines.add(line);
    }
    return Zip.csv(header, lines);
  }

  /**
   * One row for a spreadsheet: a bucket's start as the site's local date (and hour), rates as
   * percents, durations in seconds, and paths as people write them.
   */
  private static Map<String, Object> sheetRow(Map<String, Object> row, Map<String, Object> sheet) {
    Map<String, Object> out = new LinkedHashMap<>();
    String timezone = (String) sheet.get("timezone");
    for (Map.Entry<String, Object> e : Js.entries(row)) {
      String key = e.getKey();
      Object value = e.getValue();
      boolean number = value instanceof Number;
      if (key.equals("start") && number) {
        String hour =
            "hour".equals(sheet.get("interval"))
                ? " "
                    + String.format("%02d", Time.localWeekdayHour(Js.asLong(value), timezone)[1])
                    + ":00"
                : "";
        out.put("date", Time.localDate(Js.asLong(value), timezone) + hour);
      } else if (key.equals("bounceRate") && number) {
        out.put("bounceRatePercent", Js.num(Js.round(Js.asDouble(value) * 1000) / 10));
      } else if ((key.equals("visitDuration") || key.equals("timeOnPage")) && number) {
        out.put(key + "Seconds", Js.num(Js.round(Js.asDouble(value) / 1000)));
      } else if (key.equals("value")
          && value instanceof String s
          && PATH_DIMENSIONS.contains(Js.strOr(sheet.get("dimension"), ""))) {
        out.put("value", Sources.readablePath(s));
      } else {
        out.put(key, value);
      }
    }
    return out;
  }

  /** A file to save, never shown in the browser or kept in a shared cache. */
  private static Response download(String name, byte[] body, String type) {
    return new Response(
        body,
        200,
        Headers.of(
            "content-type",
            type,
            "content-disposition",
            "attachment; filename=\"" + name.replaceAll("[^A-Za-z0-9._-]", "-") + "\"",
            "cache-control",
            "private, no-store"));
  }

  private static boolean constantTimeEqual(String a, String b) {
    byte[] x = Js.utf8(a);
    byte[] y = Js.utf8(b);
    return x.length == y.length && MessageDigest.isEqual(x, y);
  }

  public static String cookieValue(String token) {
    return Hash.sha256("runlight-cookie:" + token);
  }

  public static String readCookie(Request request, String name) {
    String header = request.headers().get("cookie");
    for (String part : (header == null ? "" : header).split(";", -1)) {
      String[] pieces = Js.trim(part).split("=", -1);
      if (pieces[0].equals(name)) {
        return String.join("=", java.util.Arrays.asList(pieces).subList(1, pieces.length));
      }
    }
    return "";
  }

  public static String bearer(Request request) {
    String header = request.headers().get("authorization");
    if (header == null || header.length() < 7) {
      return "";
    }
    return Js.lower(header.substring(0, 7)).equals("bearer ") ? Js.trim(header.substring(7)) : "";
  }

  public static String normaliseBase(String path) {
    String trimmed = "/" + path.replaceAll("^/+|/+\\z", "");
    return trimmed.equals("/") ? "" : trimmed;
  }

  private static String escapeAttr(String value) {
    return value
        .replace("&", "&#38;")
        .replace("\"", "&#34;")
        .replace("<", "&#60;")
        .replace(">", "&#62;");
  }

  /** Each language but English, as the dashboard fetches them. */
  private static Map<String, Object> locales() {
    Map<String, Object> current = locales;
    if (current == null) {
      Map<String, Object> all =
          new LinkedHashMap<>(Js.map(Json.parse(Version.asset("locales.json"))));
      all.remove("en");
      current = all;
      locales = current;
    }
    return current;
  }

  private static String hash(String name) {
    return Js.string(Version.build().get(name));
  }

  private static String localeUrls(String base) {
    Map<String, Object> urls = new LinkedHashMap<>();
    for (String code : locales().keySet()) {
      urls.put(code, base + "/assets/locale." + code + "." + hash("localesHash") + ".json");
    }
    return Json.stringify(urls);
  }

  /** The dashboard's page, which holds no data: the API it calls checks access. */
  public static String dashboard(
      String base,
      String share,
      String signOut,
      boolean geoCredit,
      boolean accounts,
      String signIn) {
    String b = escapeAttr(base);
    String hash = hash("dashboardHash");
    String attributes =
        (!share.isEmpty() ? " data-share=\"" + escapeAttr(share) + "\"" : "")
            + (!signOut.isEmpty() ? " data-sign-out=\"" + escapeAttr(signOut) + "\"" : "")
            + (!signIn.isEmpty() ? " data-sign-in=\"" + escapeAttr(signIn) + "\"" : "")
            + (geoCredit ? " data-geo-credit=\"\"" : "")
            + (accounts ? " data-accounts=\"\"" : "");
    return "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<meta name=\"robots\" content=\"noindex\">\n<title>Runlight</title>\n"
        + "<link rel=\"icon\" href=\""
        + Brand.runlightIcon()
        + "\">\n"
        + "<link rel=\"stylesheet\" href=\""
        + b
        + "/assets/app."
        + hash
        + ".css\">\n</head>\n<body>\n"
        + "<div id=\"app\" data-base=\""
        + b
        + "\""
        + attributes
        + " data-world=\""
        + b
        + "/assets/world."
        + hash("worldHash")
        + ".json\" data-locales=\""
        + escapeAttr(localeUrls(base))
        + "\"></div>\n"
        + "<script type=\"module\" src=\""
        + b
        + "/assets/app."
        + hash
        + ".js\"></script>\n</body>\n</html>\n";
  }

  private static boolean sharedPath(String path) {
    return SHARED_PATHS.contains(path) || GOAL_PAGE.matcher(path).find();
  }

  /**
   * What a manage token, held by a Runlight hub, may read and change: one site's goals, funnels,
   * short links, link domains, email reports, and share links, along with its name, timezone, and
   * retention, and tickets for the element picker. It may read which mail service sends reports,
   * through GET /api/mail, which hides the service's keys. Never people, tokens, changes to the
   * mail service, imports, or other sites.
   */
  public static boolean managePath(String method, String path) {
    if (path.startsWith("/api/links/import")) {
      return false;
    }
    if (MANAGED.matcher(path).find()) {
      return true;
    }
    if (path.equals("/api/pick")) {
      return method.equals("POST");
    }
    if (path.equals("/api/mail")) {
      return method.equals("GET");
    }
    if (SITE_PATH.matcher(path).find()) {
      return method.equals("PATCH");
    }
    return false;
  }

  /** A dashboard's origin, which a picker ticket names. */
  private static boolean isOrigin(String value) {
    return ORIGIN.matcher(value).find();
  }

  /** decodeURIComponent, which throws on a broken escape, as the TypeScript does. */
  private static String decode(String text) {
    String decoded = Js.decodeURIComponent(text);
    if (decoded == null) {
      throw new Runlight.UriError();
    }
    return decoded;
  }

  /** String(body[key] ?? fallback). */
  private static String text(Map<String, Object> body, String key) {
    return text(body, key, "");
  }

  private static String text(Map<String, Object> body, String key, String fallback) {
    Object value = Js.get(body, key);
    return value == null || value == Json.UNDEFINED ? fallback : Js.string(value);
  }

  private static boolean defined(Map<String, Object> body, String key) {
    return Js.get(body, key) != Json.UNDEFINED;
  }

  /** A JSON value as the core's methods take it; undefined becomes null. */
  private static Object plain(Object value) {
    return value == Json.UNDEFINED ? null : value;
  }

  /**
   * Object.fromEntries(Object.entries(value).map(([k, v]) => [k, String(v)])) for an object, else
   * nothing.
   */
  private static Map<String, String> credentials(Object value) {
    Map<String, String> out = new LinkedHashMap<>();
    if (Js.truthy(value) && Js.isObject(value)) {
      for (Map.Entry<String, Object> e : entriesOf(value)) {
        out.put(e.getKey(), Js.string(e.getValue()));
      }
    }
    return out;
  }

  /** Math.min(1000, Math.max(1, Number(value) || fallback)). */
  private static double limit(String value, int fallback) {
    double n = Js.toNumber(value);
    n = Double.isNaN(n) || n == 0 ? fallback : n;
    return Math.min(1000, Math.max(1, n));
  }

  // The routes.

  private List<Map<String, Object>> sites() {
    return rl.sites();
  }

  private SqlStore store() {
    return rl.store;
  }

  /**
   * Whether this request acts as the owner: true, false, "read" for someone signed in who may only
   * read, such as a viewer, or "unconfigured".
   */
  private Object canRead(Request request) {
    if (managed.containsKey(request)) {
      return true;
    }
    Function<Request, Object> authorize = options.authorize;
    if (authorize != null || web != null) {
      // A script's bearer token still has full access beside the sign-ins.
      String given = bearer(request);
      if (authorize == null
          && token != null
          && !token.isEmpty()
          && !given.isEmpty()
          && constantTimeEqual(given, token)) {
        return true;
      }
      Object answer = authorize != null ? authorize.apply(request) : web.access(request);
      // A member changes things like an owner, apart from the few controls adminOnly() names.
      if ("member".equals(answer)) {
        members.put(request, true);
      }
      return "read".equals(answer)
          ? "read"
          : (Boolean) (Boolean.TRUE.equals(answer) || "member".equals(answer));
    }
    if (token == null) {
      return true;
    }
    if (token.isEmpty()) {
      // Fails closed: only a process that says it is in development runs open.
      if (!isDevelopment()) {
        return "unconfigured";
      }
      if (!warned) {
        warned = true;
        Runlight.log(
            "Runlight: no RUNLIGHT_TOKEN set, so the dashboard is open because NODE_ENV is development. Anywhere else it answers 503 until a token is set.");
      }
      return true;
    }
    String given = bearer(request);
    if (!given.isEmpty() && constantTimeEqual(given, token)) {
      return true;
    }
    String cookie = readCookie(request, COOKIE);
    return !cookie.isEmpty() && constantTimeEqual(cookie, cookieValue(token));
  }

  private boolean owner(Request request) {
    return Boolean.TRUE.equals(canRead(request));
  }

  /**
   * The controls a member cannot change: the mail service and its keys, the assistant's settings,
   * and deleting a site.
   */
  private static boolean adminOnly(String path, String method) {
    return (path.equals("/api/mail") && (method.equals("PUT") || method.equals("DELETE")))
        || (path.equals("/api/assistant") && (method.equals("PUT") || method.equals("DELETE")))
        || (path.equals("/api/assistant/limits") && method.equals("PUT"))
        || (path.equals("/api/assistant/models") && method.equals("POST"))
        || (SITE_PATH.matcher(path).find() && method.equals("DELETE"));
  }

  /** An API token from the bearer header: read-only, and maybe limited to one site. */
  private Map<String, Object> apiToken(Request request) {
    String given = bearer(request);
    if (!given.startsWith(TOKEN_PREFIX)) {
      return null;
    }
    rl.init();
    Map<String, Object> row = store().tokenByHash(Hash.sha256(given));
    if (row == null) {
      return null;
    }
    long now = rl.now();
    // At most once a minute, so a busy assistant does not write on every call.
    if (row.get("lastUsedAt") == null || now - Js.asLong(row.get("lastUsedAt")) > 60_000) {
      store().touchToken((String) row.get("id"), now);
    }
    return row;
  }

  /**
   * Who may read stats: the owner (true), an API token or a read-only sign-in (the token's map), or
   * nobody (false, or "unconfigured").
   */
  private Object reader(Request request) {
    Map<String, Object> apiToken = apiToken(request);
    if (apiToken != null) {
      return apiToken;
    }
    if (options.authorize != null || web != null) {
      Object access = canRead(request);
      // A read-only sign-in reads like an API token for every site.
      return "read".equals(access)
          ? Json.object(
              "id",
              "",
              "name",
              "",
              "site",
              "",
              "scope",
              "read",
              "hash",
              "",
              "hint",
              "",
              "createdAt",
              0L,
              "lastUsedAt",
              null)
          : (Object) Boolean.TRUE.equals(access);
    }
    Object access = canRead(request);
    return "read".equals(access) ? (Object) false : access;
  }

  private static boolean refusedReader(Object access) {
    return Boolean.FALSE.equals(access) || "unconfigured".equals(access);
  }

  /**
   * The refusal for a hub that asks for something only safe once this app knows its own address.
   */
  private static Response originNeeded() {
    return coded(
        "Set this Runlight's own address first (RUNLIGHT_URL on the server, or origin in routes()), so a connected hub can add link domains and email reports.",
        "origin_needed",
        400);
  }

  private static Response denied(Object result) {
    if ("read".equals(result)) {
      return coded("Only an owner can change this", "owner_only", 403);
    }
    return "unconfigured".equals(result)
        ? coded(
            "Set RUNLIGHT_TOKEN, or pass token or authorize to routes(). Without one, Runlight only runs open when NODE_ENV is development.",
            "token_unset",
            503)
        : coded("Unauthorized", "unauthorized", 401);
  }

  /** The site a query names, or the 404 for one that does not exist. */
  private Object querySite(Url url) {
    Map<String, Object> site = rl.site(url.searchParams().get("site"));
    return site != null ? site : coded("Unknown site", "unknown_site", 404);
  }

  @SuppressWarnings("unchecked")
  private static Map<String, Object> asMap(Object value) {
    return (Map<String, Object>) value;
  }

  /** The query, range, and comparison a read asks for, or the refusal. */
  private Object readQuery(Url url, Map<String, Object> site) {
    SearchParams params = url.searchParams();
    List<Object> filters = new ArrayList<>();
    if (params.getAll("filter").size() > Query.MAX_FILTERS) {
      return coded(
          "Use at most " + Query.MAX_FILTERS + " filters at once.",
          "filters_max",
          400,
          Json.object("max", String.valueOf(Query.MAX_FILTERS)));
    }
    for (String raw : params.getAll("filter")) {
      Map<String, Object> filter = Query.parseFilter(raw);
      if (filter == null) {
        return coded(
            "Bad filter \"" + raw + "\". Use dimension:is|not|contains:value.",
            "filter_bad",
            400,
            Json.object("filter", raw));
      }
      filters.add(filter);
    }
    String timezone = (String) site.get("timezone");
    long now = rl.now();
    String firstDate = null;
    if ("all".equals(params.get("period"))) {
      Object first = store().firstSeen((String) site.get("id"));
      if (first != null) {
        firstDate = Time.localDate(Js.asLong(first), timezone);
      }
    }
    Map<String, Object> input = new LinkedHashMap<>();
    input.put("period", params.get("period"));
    input.put("from", params.get("from"));
    input.put("to", params.get("to"));
    input.put("interval", params.get("interval"));
    Map<String, Object> range = Time.resolveRange(input, timezone, now, firstDate);
    if (range == null) {
      return coded("Bad date range. Use period, or from and to as YYYY-MM-DD.", "range_bad", 400);
    }
    Map<String, Object> query =
        Json.object(
            "site",
            site.get("id"),
            "from",
            range.get("from"),
            "to",
            range.get("to"),
            "filters",
            filters);
    // compare=false is the older spelling of off.
    String raw = params.get("compare") != null ? params.get("compare") : "previous";
    String mode = raw.equals("false") ? "off" : raw;
    if (!Time.COMPARE_MODES.contains(mode)) {
      return coded(
          "Bad compare \"" + raw + "\". Use previous, year, custom, or off.",
          "compare_bad",
          400,
          Json.object("compare", raw));
    }
    Map<String, Object> custom = new LinkedHashMap<>();
    custom.put("from", params.get("compare_from"));
    custom.put("to", params.get("compare_to"));
    Map<String, Object> compared = Time.compareRange(range, mode, timezone, custom);
    if (mode.equals("custom") && compared == null) {
      return coded(
          "Bad comparison range. Use compare_from and compare_to as YYYY-MM-DD.",
          "compare_range_bad",
          400);
    }
    Map<String, Object> out = new LinkedHashMap<>();
    out.put("query", query);
    out.put("range", range);
    out.put("compared", compared);
    return out;
  }

  /** The request's JSON object, or the refusal. */
  private static Object readJson(Request request) {
    // A form posted from another site cannot carry this content type without CORS.
    if (!isJson(request)) {
      return coded("Send JSON", "send_json", 415);
    }
    Json.Parsed parsed = Json.tryParse(request.text());
    return parsed.ok() && parsed.value() instanceof Map<?, ?>
        ? parsed.value()
        : coded("Send a JSON object", "send_object", 400);
  }

  private List<Object> ownDomains(String site) {
    List<Object> out = new ArrayList<>();
    for (Map<String, Object> d : store().linkDomains()) {
      if (site.equals(d.get("site"))) {
        out.add(d.get("domain"));
      }
    }
    return out;
  }

  private Response linksApi(Request request, String path, Url url) {
    rl.init();
    Object found = querySite(url);
    if (found instanceof Response r) {
      return r;
    }
    Map<String, Object> site = asMap(found);
    String siteId = (String) site.get("id");
    SqlStore store = store();
    String method = request.method();
    try {
      if (path.equals("/api/link-domains")) {
        if (method.equals("GET")) {
          return json(Json.object("domains", ownDomains(siteId)));
        }
        if (method.equals("POST")) {
          Object read = readJson(request);
          if (read instanceof Response r) {
            return r;
          }
          Map<String, Object> body = asMap(read);
          String domain = Js.lower(Js.trim(text(body, "domain")));
          domain = domain.replaceFirst("^https?://", "");
          domain = domain.replaceFirst("/" + Js.DOT + "*\\z", "");
          domain = domain.replaceFirst("\\.+\\z", "");
          domain = domain.replaceFirst("^www\\.", "");
          if (!DOMAIN_NAME.matcher(domain).find()) {
            return coded("That is not a domain name", "domain_invalid", 400);
          }
          if (privateName(domain) || Safefetch.resolvesPrivately(domain)) {
            return coded(
                domain + " is not a public domain name. Use one that browsers anywhere can reach.",
                "domain_not_public",
                400,
                Json.object("domain", domain));
          }
          // A link domain answers every path on it, so it must never be where the dashboard or a
          // counted site lives. The request's own Host is the caller's to choose, so the configured
          // address and the names people signed in from count too. A hub cannot know every name
          // this app answers on, so it adds none until the app knows its own address.
          if (managed.containsKey(request) && origin == null) {
            return originNeeded();
          }
          List<String> own = new ArrayList<>();
          if (origin != null) {
            own.add(new Url(origin).host());
          }
          for (String h :
              new String[] {
                request.headers().get("host"), request.headers().get("x-forwarded-host"), url.host()
              }) {
            if (Js.truthy(h)) {
              own.add(h);
            }
          }
          if (options.ownHosts != null) {
            for (String host : options.ownHosts.get()) {
              own.add(host);
            }
          }
          List<Object> taken = new ArrayList<>();
          for (String h : own) {
            taken.add(hostName(h));
          }
          for (Map<String, Object> s : sites()) {
            taken.addAll(Js.list(s.get("hostnames")));
            Map<String, Object> remote = rl.remote((String) s.get("id"));
            if (remote != null && remote.get("hostnames") instanceof List<?> l) {
              taken.addAll(l);
            }
          }
          if (taken.contains(domain)) {
            return coded(
                domain
                    + " is where this dashboard or one of your sites lives. Use a separate domain or subdomain for short links, such as go."
                    + domain
                    + ".",
                "domain_in_use",
                400,
                Json.object("domain", domain));
          }
          for (Map<String, Object> d : store.linkDomains()) {
            if (domain.equals(d.get("domain"))) {
              if (!siteId.equals(d.get("site"))) {
                return coded(
                    domain + " already belongs to another site",
                    "domain_taken",
                    409,
                    Json.object("domain", domain));
              }
              break;
            }
          }
          store.addLinkDomain(domain, siteId, rl.now());
          rl.forgetLinkDomains();
          return json(Json.object("domain", domain), 201);
        }
      }
      Matcher checkMatch = DOMAIN_CHECK.matcher(path);
      if (checkMatch.find() && method.equals("GET")) {
        String domain = decode(checkMatch.group(1));
        if (!ownDomains(siteId).contains(domain)) {
          return coded("Unknown domain", "unknown_domain", 404);
        }
        // One added before names inside private networks were refused is never fetched. What the
        // check found, as a code the dashboard says in its own words, beside the English reason.
        // Where the domain should point, for the setup steps: this server's name, and its public
        // addresses for a bare domain, which takes an A record.
        String ownHost = origin != null ? new Url(origin).hostname : url.hostname;
        Map<String, Object> target =
            Json.object(
                "host",
                ownHost,
                "addresses",
                new ArrayList<Object>(Safefetch.publicAddresses(ownHost)));
        if (!DOMAIN_NAME.matcher(domain).find() || privateName(domain)) {
          return checkResult(
              domain, target, "check_not_public", "is not a public domain name", null);
        }
        try {
          // Only a public address is fetched, whatever the name resolves to now, so the check
          // cannot be pointed into a private network.
          Response answer =
              Safefetch.publicFetch(
                  "https://" + domain + Runlight.LINK_DOMAIN_CHECK,
                  Json.object("timeoutMs", 5000L),
                  rl.fetcher);
          Object body;
          try {
            Json.Parsed parsed = Json.tryParse(answer.text());
            body = parsed.ok() && Js.isObject(parsed.value()) ? parsed.value() : null;
          } catch (RuntimeException e) {
            body = null;
          }
          if (answer.ok()
              && body != null
              && Boolean.TRUE.equals(Js.get(body, "runlight"))
              && domain.equals(Js.get(body, "domain"))) {
            return checkResult(domain, target, "", "", null);
          }
          return answer.ok()
              ? checkResult(
                  domain, target, "check_not_runlight", "answered, but not from Runlight", null)
              : checkResult(
                  domain,
                  target,
                  "check_status",
                  "answered " + answer.status(),
                  Json.object("status", String.valueOf(answer.status())));
        } catch (RuntimeException error) {
          // A refused private address answers as a closed port does, so the check tells nothing
          // about a private network.
          return error instanceof FetchError f && f.timedOut()
              ? checkResult(domain, target, "check_timeout", "timed out", null)
              : checkResult(domain, target, "check_https", "could not connect over HTTPS", null);
        }
      }

      Matcher domainMatch = DOMAIN_PATH.matcher(path);
      if (domainMatch.find() && method.equals("DELETE")) {
        String domain = decode(domainMatch.group(1));
        if (!ownDomains(siteId).contains(domain)) {
          return coded("Unknown domain", "unknown_domain", 404);
        }
        store.removeLinkDomain(domain);
        rl.forgetLinkDomains();
        return json(Json.object("ok", true));
      }

      if (path.equals("/api/links")) {
        if (method.equals("GET")) {
          Object read = readQuery(url, site);
          if (read instanceof Response r) {
            return r;
          }
          Map<String, Object> range = asMap(asMap(read).get("range"));
          List<Map<String, Object>> links =
              store.links(siteId, Js.asLong(range.get("from")), Js.asLong(range.get("to")));
          // Links on a removed domain are served from the app's own path until it is added back.
          return json(
              Json.object(
                  "prefix",
                  url.origin() + rl.linkPath,
                  "domains",
                  ownDomains(siteId),
                  "links",
                  links));
        }
        if (method.equals("POST")) {
          Object read = readJson(request);
          if (read instanceof Response r) {
            return r;
          }
          Map<String, Object> body = asMap(read);
          Map<String, Object> input = Json.object("url", text(body, "url"));
          for (String key : List.of("name", "slug", "domain")) {
            if (defined(body, key)) {
              input.put(key, Js.string(Js.get(body, key)));
            }
          }
          Map<String, Object> link = rl.links.create(siteId, input);
          return json(Json.object("link", link), 201);
        }
      }

      // One step of an import from another shortener; the page calls again with the cursor.
      Matcher importMatch = IMPORT_PATH.matcher(path);
      if (importMatch.find() && method.equals("POST")) {
        Object read = readJson(request);
        if (read instanceof Response r) {
          return r;
        }
        Map<String, Object> body = asMap(read);
        Object cursor = Js.get(body, "cursor");
        Object doneValue = Js.get(body, "done");
        double done = doneValue == Json.UNDEFINED ? Double.NaN : Js.toNumber(doneValue);
        try {
          Map<String, Object> step =
              Index.importStep(
                  rl,
                  siteId,
                  importMatch.group(1),
                  credentials(Js.get(body, "credentials")),
                  cursor instanceof String c ? c : null,
                  Double.isNaN(done) ? 0 : done);
          return json(step);
        } catch (ImportError error) {
          return refused(error, "import_failed");
        }
      }

      if (path.equals("/api/links/import") && method.equals("POST")) {
        Object read = readJson(request);
        if (read instanceof Response r) {
          return r;
        }
        Map<String, Object> body = asMap(read);
        // Rows that are not objects (null, a number) are dropped rather than failing the import.
        Object given = Js.get(body, "rows");
        if (!(given instanceof List<?> list)) {
          return coded("Send rows as a list", "rows_needed", 400);
        }
        List<Object> rows = new ArrayList<>();
        for (Object row : list) {
          if (row instanceof Map<?, ?> && rows.size() < 5000) {
            rows.add(row);
          }
        }
        return json(rl.links.importRows(siteId, rows));
      }

      Matcher linkMatch = LINK_PATH.matcher(path);
      if (linkMatch.find()) {
        String id = linkMatch.group(1);
        if (method.equals("GET")) {
          Map<String, Object> link = store.linkById(id);
          if (link == null || !siteId.equals(link.get("site"))) {
            return coded("Unknown link", "unknown_link", 404);
          }
          Object read = readQuery(url, site);
          if (read instanceof Response r) {
            return r;
          }
          Map<String, Object> range = asMap(asMap(read).get("range"));
          long from = Js.asLong(range.get("from"));
          long to = Js.asLong(range.get("to"));
          Function<String, List<Map<String, Object>>> by =
              dimension ->
                  Query.isSessionDimension(dimension)
                      ? store.linkBreakdown(siteId, id, from, to, dimension, 10)
                      : new ArrayList<>();
          List<Map<String, Object>> series =
              store.linkSeries(siteId, id, Time.buckets(range, (String) site.get("timezone")));
          long clicks = 0;
          for (Map<String, Object> p : series) {
            clicks += Js.asLong(p.get("clicks"));
          }
          Map<String, Object> answer = new LinkedHashMap<>();
          answer.put("link", link);
          answer.put("range", rangeOut(range, site));
          answer.put("clicks", clicks);
          answer.put("series", series);
          answer.put("sources", by.apply("source"));
          answer.put("referrers", by.apply("referrer"));
          answer.put("countries", by.apply("country"));
          answer.put("devices", by.apply("device"));
          answer.put("browsers", by.apply("browser"));
          return json(answer);
        }
        Map<String, Object> owned = store.linkById(id);
        if (owned == null || !siteId.equals(owned.get("site"))) {
          return coded("Unknown link", "unknown_link", 404);
        }
        if (method.equals("PATCH")) {
          Object read = readJson(request);
          if (read instanceof Response r) {
            return r;
          }
          Map<String, Object> body = asMap(read);
          Map<String, Object> patch = new LinkedHashMap<>();
          for (String key : List.of("url", "name", "slug", "domain")) {
            if (defined(body, key)) {
              patch.put(key, Js.string(Js.get(body, key)));
            }
          }
          return json(Json.object("link", rl.links.update(id, patch)));
        }
        if (method.equals("DELETE")) {
          rl.links.remove(id);
          return json(Json.object("ok", true));
        }
      }
    } catch (LinkError error) {
      return coded(error.getMessage(), error.code(), 400, paramsOf(error));
    } catch (RangeError error) {
      return coded(error.getMessage(), "unknown_link", 404);
    }
    return coded("Not found", "not_found", 404);
  }

  private static Response checkResult(
      String domain,
      Map<String, Object> target,
      String code,
      String reason,
      Map<String, Object> params) {
    Map<String, Object> out =
        Json.object(
            "domain", domain, "working", code.isEmpty(), "reason", reason, "target", target);
    if (!code.isEmpty()) {
      out.put("code", code);
      if (params != null) {
        out.put("params", params);
      }
    }
    return json(out);
  }

  private static Map<String, Object> rangeOut(Map<String, Object> range, Map<String, Object> site) {
    return Json.object(
        "from",
        range.get("fromDate"),
        "to",
        range.get("toDate"),
        "interval",
        range.get("interval"),
        "timezone",
        site.get("timezone"));
  }

  /** The key picker tickets are signed with, made on first use and kept in the database. */
  private String pickKey() {
    rl.init();
    String saved = store().setting("pick-key");
    if (saved != null && !saved.isEmpty()) {
      return saved;
    }
    String made = Hash.randomId(32);
    store().setSetting("pick-key", made);
    return made;
  }

  /**
   * A ticket that lets the picker, on site's pages, send its choice to origin, the dashboard that
   * asked, for half an hour.
   */
  private String pickTicket(String origin, String site) {
    HexFormat hex = HexFormat.of();
    String payload =
        (rl.now() + PICK_TICKET_MS)
            + "."
            + hex.formatHex(Js.utf8(site))
            + "."
            + hex.formatHex(Js.utf8(origin));
    return payload + "." + Hash.hmac(pickKey(), payload);
  }

  /**
   * The dashboard origin and site a picker ticket names, or null when it is not one this install
   * signed or has run out.
   */
  private Map<String, Object> pickTarget(String ticket) {
    Matcher parts = TICKET.matcher(ticket);
    if (!parts.find() || Js.toNumber(parts.group(1)) < rl.now()) {
      return null;
    }
    if (!constantTimeEqual(
        parts.group(4),
        Hash.hmac(pickKey(), parts.group(1) + "." + parts.group(2) + "." + parts.group(3)))) {
      return null;
    }
    String origin = unhex(parts.group(3));
    return isOrigin(origin) ? Json.object("origin", origin, "site", unhex(parts.group(2))) : null;
  }

  private static String unhex(String text) {
    String even = text.substring(0, text.length() - text.length() % 2);
    return new String(HexFormat.of().parseHex(even), StandardCharsets.UTF_8);
  }

  /**
   * The tracker with click rules inside, rebuilt when goals change. With ?site= it carries only
   * that site's rules, so one site's visitors never see another site's domains or goals. The
   * standalone server's snippet always names the site; without a name it serves no rules, and an
   * app's own install, whose sites all belong to one owner, serves every site's.
   */
  private Script trackerScript(String siteId) {
    String key = siteId != null ? siteId : "";
    Script cached = trackers.get(key);
    if (cached != null && rl.now() - cached.at() < 60_000) {
      return cached;
    }
    rl.init();
    List<Map<String, Object>> sites = new ArrayList<>();
    if (siteId != null) {
      for (Map<String, Object> s : sites()) {
        if (siteId.equals(s.get("id"))) {
          sites.add(s);
        }
      }
    } else if (!rl.managedSites) {
      sites = sites();
    }
    String rules = Json.stringify(Goals.clickRules(sites, store().goals(null)));
    String tracker = Version.asset("tracker.js");
    int at = tracker.indexOf(RULES_PLACEHOLDER);
    String body =
        at < 0
            ? tracker
            : tracker.substring(0, at) + rules + tracker.substring(at + RULES_PLACEHOLDER.length());
    Script script =
        new Script(
            body,
            "\"" + hash("trackerHash") + "-" + Hash.sha256(rules).substring(0, 8) + "\"",
            rl.now());
    // One entry per site at most; a query naming no real site gets the empty script without
    // filling the map.
    if (siteId == null || !sites.isEmpty()) {
      trackers.put(key, script);
    }
    return script;
  }

  private Response goalWrites(Request request, String path, Url url) {
    rl.init();
    Object found = querySite(url);
    if (found instanceof Response r) {
      return r;
    }
    Map<String, Object> site = asMap(found);
    List<Map<String, Object>> existing = store().goals((String) site.get("id"));
    String id = path.equals("/api/goals") ? null : decode(path.substring("/api/goals/".length()));
    Map<String, Object> before = null;
    for (Map<String, Object> g : existing) {
      if (g.get("id").equals(id)) {
        before = g;
      }
    }
    if (id != null && before == null) {
      return coded("Unknown goal", "unknown_goal", 404);
    }
    trackers.clear();
    if (request.method().equals("DELETE")) {
      store().deleteGoal(id);
      return json(Json.object("ok", true));
    }
    Object read = readJson(request);
    if (read instanceof Response r) {
      return r;
    }
    try {
      Map<String, Object> goal =
          Goals.goalFrom(read, (String) site.get("id"), existing, rl.now(), id);
      store().saveGoal(goal, before);
      return json(Json.object("goal", goal), id != null && !id.isEmpty() ? 200 : 201);
    } catch (GoalError error) {
      return refused(error, "goal_invalid");
    }
  }

  private static Map<String, Object> reportView(Map<String, Object> r) {
    return Json.object(
        "id", r.get("id"),
        "site", r.get("site"),
        "email", r.get("email"),
        "frequency", r.get("frequency"),
        "lang", r.get("lang"),
        "lastSentAt", r.get("lastSentAt"),
        "createdAt", r.get("createdAt"));
  }

  private static Map<String, Object> service(Object id) {
    for (Map<String, Object> s : Transports.SERVICES) {
      if (s.get("id").equals(id)) {
        return s;
      }
    }
    return null;
  }

  @SuppressWarnings("unchecked")
  private static List<Map<String, Object>> fields(Map<String, Object> service) {
    return service == null ? List.of() : (List<Map<String, Object>>) service.get("fields");
  }

  private Response mailApi(Request request, String path, Url url) {
    rl.init();
    String method = request.method();
    try {
      if (path.equals("/api/mail")) {
        if (method.equals("GET")) {
          Map<String, Object> settings = rl.mailSettings();
          Map<String, Object> service = service(settings == null ? null : settings.get("service"));
          // Secret fields come back only as "saved", never as their value.
          Map<String, Object> fields = new LinkedHashMap<>();
          List<Object> saved = new ArrayList<>();
          for (Map<String, Object> f : fields(service)) {
            String name = (String) f.get("name");
            Object value = settings.get(name);
            if (Js.truthy(f.get("secret"))) {
              if (Js.truthy(value)) {
                saved.add(name);
              }
            } else {
              fields.put(name, value == null ? "" : Js.string(value));
            }
          }
          // A hub with a manage token learns which service sends the reports and from where,
          // nothing more.
          boolean viaManage = managed.containsKey(request);
          Map<String, Object> out = new LinkedHashMap<>();
          out.put("source", settings == null ? null : settings.get("source"));
          out.put("service", orEmpty(settings, "service"));
          out.put("from", orEmpty(settings, "from"));
          out.put("fromName", orEmpty(settings, "fromName"));
          out.put("fields", viaManage ? new LinkedHashMap<>() : fields);
          out.put("saved", viaManage ? new ArrayList<>() : saved);
          out.put("encrypted", rl.secret != null);
          out.put("services", Transports.SERVICES);
          return json(out);
        }
        if (method.equals("PUT")) {
          Object read = readJson(request);
          if (read instanceof Response r) {
            return r;
          }
          rl.saveMailSettings(asMap(read));
          return json(Json.object("ok", true));
        }
        if (method.equals("DELETE")) {
          rl.saveMailSettings(null);
          return json(Json.object("ok", true));
        }
        return coded("Method not allowed", "method_not_allowed", 405);
      }

      if (path.equals("/api/mail/test") && method.equals("POST")) {
        Object read = readJson(request);
        if (read instanceof Response r) {
          return r;
        }
        Map<String, Object> body = asMap(read);
        String to = Js.trim(text(body, "to"));
        if (!isEmail(to)) {
          return coded("Enter an email address to send the test to", "test_email", 400);
        }
        Map<String, Object> settings = rl.mailSettings();
        if (settings == null) {
          return coded("Set up a mail service first", "mail_unset", 400);
        }
        Messages.Translator t = Messages.translator(text(body, "lang", "en"));
        Map<String, Object> service = service(settings.get("service"));
        String name = service == null ? "" : (String) service.get("name");
        String said = t.t("email.test.body", Json.object("service", name));
        rl.sendMail(
            Json.object(
                "to",
                to,
                "subject",
                t.t("email.test.subject"),
                "text",
                said,
                "html",
                "<p style=\"font-family:sans-serif;font-size:15px\">" + escapeHtml(said) + "</p>"));
        return json(Json.object("ok", true));
      }

      Object found = querySite(url);
      if (found instanceof Response r) {
        return r;
      }
      Map<String, Object> site = asMap(found);
      String siteId = (String) site.get("id");

      if (path.equals("/api/reports")) {
        if (method.equals("GET")) {
          List<Object> reports = new ArrayList<>();
          for (Map<String, Object> r : store().reports(siteId)) {
            reports.add(reportView(r));
          }
          return json(Json.object("reports", reports, "languages", Messages.languages()));
        }
        if (method.equals("POST")) {
          Object read = readJson(request);
          if (read instanceof Response r) {
            return r;
          }
          Map<String, Object> body = asMap(read);
          String email = Js.lower(Js.trim(text(body, "email")));
          if (!isEmail(email)) {
            return coded("Enter an email address", "email_invalid", 400);
          }
          String frequency = "monthly".equals(Js.get(body, "frequency")) ? "monthly" : "weekly";
          List<Map<String, Object>> existing = store().reports(siteId);
          for (Map<String, Object> r : existing) {
            if (email.equals(r.get("email")) && frequency.equals(r.get("frequency"))) {
              return coded(
                  email + " already gets the " + frequency + " report",
                  "report_exists",
                  400,
                  Json.object("email", email));
            }
          }
          if (existing.size() >= 50) {
            return coded("A site can send to at most 50 addresses", "report_limit", 400);
          }
          // Links in the email point back to the configured address, or else to this dashboard as
          // the browser sees it. A report made from a hub needs the configured address, where its
          // unsubscribe link answers, since the Host its request names is the hub's to choose.
          if (managed.containsKey(request) && origin == null) {
            return originNeeded();
          }
          String given = origin != null ? "" : text(body, "origin");
          String home =
              HOME.matcher(given).find()
                  ? given.replaceFirst("/+\\z", "")
                  : (origin != null ? origin : url.origin()) + base;
          // A period already due counts as sent, so a report added mid-week first goes out on the
          // next Monday, as the form says.
          long now = rl.now();
          Map<String, Object> due =
              Reports.lastPeriod(frequency, now, (String) site.get("timezone"));
          String lang = Js.string(Js.get(body, "lang"));
          Map<String, Object> report = new LinkedHashMap<>();
          report.put("id", Hash.randomId());
          report.put("site", siteId);
          report.put("email", email);
          report.put("frequency", frequency);
          report.put("lang", Messages.languages().contains(lang) ? lang : "en");
          report.put("token", Hash.randomId(16));
          report.put("origin", home);
          report.put("lastPeriod", now >= Js.asLong(due.get("dueAt")) ? due.get("key") : "");
          report.put("lastSentAt", null);
          report.put("createdAt", now);
          store().insertReport(report);
          return json(Json.object("report", reportView(report)), 201);
        }
        return coded("Method not allowed", "method_not_allowed", 405);
      }

      Matcher match = REPORT_PATH.matcher(path);
      boolean matched = match.find();
      Map<String, Object> report = matched ? store().reportBy("id", match.group(1)) : null;
      if (report == null || !siteId.equals(report.get("site"))) {
        return coded("Unknown report", "unknown_report", 404);
      }
      boolean send = match.group(2) != null;
      if (send && method.equals("POST")) {
        // A sample at most once a minute per report, so the send button cannot be used to flood an
        // inbox. A hub sends one every ten minutes for the whole site, so adding reports again
        // does not start a new count.
        boolean viaHub = managed.containsKey(request);
        String key = viaHub ? "site:" + siteId : (String) report.get("id");
        long wait = viaHub ? 600_000 : 60_000;
        synchronized (sampleSent) {
          long last = sampleSent.getOrDefault(key, 0L);
          if (rl.now() - last < wait) {
            return viaHub
                ? coded(
                    "A connected hub can send one sample every ten minutes. Wait a few minutes and try again.",
                    "sample_soon_hub",
                    429)
                : coded(
                    "A sample went out a moment ago. Wait a minute and try again.",
                    "sample_soon",
                    429);
          }
          sampleSent.put(key, rl.now());
        }
        rl.deliverReport(report, site);
        return json(Json.object("ok", true));
      }
      if (!send && method.equals("DELETE")) {
        store().deleteReport((String) report.get("id"));
        return json(Json.object("ok", true));
      }
      return coded("Method not allowed", "method_not_allowed", 405);
    } catch (MailError error) {
      return coded(error.getMessage(), error.code(), 400, paramsOf(error));
    }
  }

  private static Object orEmpty(Map<String, Object> settings, String key) {
    return settings == null || settings.get(key) == null ? "" : settings.get(key);
  }

  /**
   * A plain page for unsubscribing: a button, so a link scanner opening the URL changes nothing.
   */
  private Response unsubscribePage(Request request, String token) {
    rl.init();
    Map<String, Object> report =
        REPORT_TOKEN.matcher(token).find() ? store().reportBy("token", token) : null;
    Map<String, Object> site = report != null ? rl.site((String) report.get("site")) : null;
    Messages.Translator t =
        Messages.translator(report != null ? (String) report.get("lang") : "en");
    String lang = t.lang();
    if (report == null || site == null) {
      return smallPage(
          lang,
          "<h1>"
              + escapeHtml(t.t("email.unsub.goneTitle"))
              + "</h1><p>"
              + escapeHtml(t.t("email.unsub.gone"))
              + "</p>",
          404);
    }
    if (request.method().equals("POST")) {
      store().deleteReport((String) report.get("id"));
      return smallPage(
          lang,
          "<h1>"
              + escapeHtml(t.t("email.unsub.doneTitle"))
              + "</h1><p>"
              + escapeHtml(
                  t.t(
                      "email.unsub.done",
                      Json.object("site", site.get("name"), "email", report.get("email"))))
              + "</p>",
          200);
    }
    return smallPage(
        lang,
        "<h1>"
            + escapeHtml(t.t("email.unsub.title", Json.object("site", site.get("name"))))
            + "</h1><p>"
            + escapeHtml(t.t("email.unsub.body", Json.object("email", report.get("email"))))
            + "</p><form method=\"post\"><button type=\"submit\">"
            + escapeHtml(t.t("email.unsubscribe"))
            + "</button></form>",
        200);
  }

  private Map<String, Object> shareView(Map<String, Object> share) {
    Map<String, Object> out = new LinkedHashMap<>(share);
    out.put("path", base + "/share/" + share.get("id"));
    return out;
  }

  private Response sharesApi(Request request, String path, Url url) {
    rl.init();
    Object found = querySite(url);
    if (found instanceof Response r) {
      return r;
    }
    Map<String, Object> site = asMap(found);
    String method = request.method();

    if (path.equals("/api/shares")) {
      if (method.equals("GET")) {
        List<Object> shares = new ArrayList<>();
        for (Map<String, Object> share : store().shares((String) site.get("id"))) {
          shares.add(shareView(share));
        }
        return json(Json.object("shares", shares));
      }
      if (method.equals("POST")) {
        Object read = readJson(request);
        if (read instanceof Response r) {
          return r;
        }
        Map<String, Object> share =
            Json.object(
                "id",
                Hash.randomId(16),
                "site",
                site.get("id"),
                "name",
                Js.slice(Js.trim(text(asMap(read), "name")), 0, 100),
                "createdAt",
                rl.now());
        store().insertShare(share);
        return json(Json.object("share", shareView(share)), 201);
      }
      return coded("Method not allowed", "method_not_allowed", 405);
    }

    String id = decode(path.substring("/api/shares/".length()));
    Map<String, Object> share = SHARE_ID.matcher(id).find() ? store().shareById(id) : null;
    if (share == null || !site.get("id").equals(share.get("site"))) {
      return coded("Unknown share", "unknown_share", 404);
    }
    if (method.equals("PATCH")) {
      Object read = readJson(request);
      if (read instanceof Response r) {
        return r;
      }
      String name = Js.slice(Js.trim(text(asMap(read), "name")), 0, 100);
      store().renameShare((String) share.get("id"), name);
      Map<String, Object> renamed = new LinkedHashMap<>(share);
      renamed.put("name", name);
      return json(Json.object("share", shareView(renamed)));
    }
    if (method.equals("DELETE")) {
      store().deleteShare((String) share.get("id"));
      return json(Json.object("ok", true));
    }
    return coded("Method not allowed", "method_not_allowed", 405);
  }

  /** How many questions each viewer may ask the assistant a day, as an owner set it. */
  private Object viewerDaily() {
    String saved = store().setting("assistant-viewer-daily");
    return saved == null ? (Object) VIEWER_DAILY : Js.num(Js.toNumber(saved));
  }

  /**
   * Counts a question to the assistant, which spends the owner's AI credit, or refuses it: past
   * thirty an hour or two at once for anyone, and past the owner's daily number for a viewer.
   * Returns how to finish, or the refusal.
   */
  private Object askTurn(String who, boolean owner) {
    long now = rl.now();
    Asked mine;
    synchronized (asked) {
      mine = asked.computeIfAbsent(who, key -> new Asked());
      mine.at.removeIf(at -> now - at >= 3_600_000);
      if (mine.at.size() >= ASK_PER_HOUR || mine.open >= ASK_AT_ONCE) {
        return coded(
            "You have asked a lot in a short time. Wait a little and ask again.",
            "assistant_soon",
            429);
      }
    }
    if (!owner) {
      Object limit = viewerDaily();
      String day = "assistant-asked:" + Time.isoString(now).substring(0, 10);
      String stored = store().setting(day);
      Map<String, Object> counts =
          new LinkedHashMap<>(Js.map(Json.parse(stored != null ? stored : "{}")));
      double count = counts.containsKey(who) ? Js.asDouble(counts.get(who)) : 0;
      if (count >= Js.asDouble(limit)) {
        return coded(
            "Viewers can ask " + Js.string(limit) + " questions a day. Ask again tomorrow.",
            "assistant_daily",
            429,
            Json.object("limit", Js.string(limit)));
      }
      counts.put(who, Js.num(count + 1));
      store().setSetting(day, Json.stringify(counts));
      for (Map<String, Object> entry : store().settingsStartingWith("assistant-asked:")) {
        if (!day.equals(entry.get("key"))) {
          store().setSetting((String) entry.get("key"), null);
        }
      }
    }
    synchronized (asked) {
      mine.at.add(now);
      mine.open++;
      asked.put(who, mine);
      // People who stopped asking are dropped, so the map holds only the last hour's.
      if (asked.size() > 1000) {
        asked
            .values()
            .removeIf(
                value ->
                    value.open == 0 && value.at.stream().noneMatch(at -> now - at < 3_600_000));
      }
    }
    Runnable finish =
        () -> {
          synchronized (asked) {
            mine.open--;
          }
        };
    return finish;
  }

  private Response tokensApi(Request request, String path) {
    rl.init();
    String method = request.method();
    if (path.equals("/api/tokens") && method.equals("GET")) {
      List<Object> tokens = new ArrayList<>();
      for (Map<String, Object> t : store().tokens()) {
        tokens.add(tokenView(t));
      }
      return json(Json.object("tokens", tokens));
    }
    if (path.equals("/api/tokens") && method.equals("POST")) {
      Object read = readJson(request);
      if (read instanceof Response r) {
        return r;
      }
      Map<String, Object> body = asMap(read);
      String name = Js.slice(Js.trim(text(body, "name")), 0, 100);
      if (name.isEmpty()) {
        return coded("Name the token", "token_name", 400);
      }
      String site = text(body, "site");
      if (!site.isEmpty() && rl.site(site) == null) {
        return coded("Unknown site", "unknown_site", 404);
      }
      String scope = "manage".equals(Js.get(body, "scope")) ? "manage" : "read";
      if (scope.equals("manage") && site.isEmpty()) {
        return coded(
            "A token that changes settings is for one site. Pick the site.", "token_site", 400);
      }
      String secret = TOKEN_PREFIX + Hash.randomId(20);
      Map<String, Object> row = new LinkedHashMap<>();
      row.put("id", Hash.randomId());
      row.put("name", name);
      row.put("site", site);
      row.put("scope", scope);
      row.put("hash", Hash.sha256(secret));
      row.put("hint", secret.substring(secret.length() - 4));
      row.put("createdAt", rl.now());
      row.put("lastUsedAt", null);
      store().insertToken(row);
      String by = accountOf != null ? accountOf.apply(request) : null;
      if (by != null && !by.isEmpty() && tokenMade != null && !tokenMade.test(row, by)) {
        store().deleteToken((String) row.get("id"));
        return denied("read");
      }
      // The only time the token is ever shown.
      return json(Json.object("token", tokenView(row), "secret", secret), 201);
    }
    Matcher match = TOKEN_PATH.matcher(path);
    if (match.find() && method.equals("DELETE")) {
      return store().deleteToken(match.group(1))
          ? json(Json.object("ok", true))
          : coded("Unknown token", "unknown_token", 404);
    }
    return coded("Not found", "not_found", 404);
  }

  private static Map<String, Object> tokenView(Map<String, Object> t) {
    return Json.object(
        "id", t.get("id"),
        "name", t.get("name"),
        "site", t.get("site"),
        "scope", t.get("scope"),
        "hint", t.get("hint"),
        "createdAt", t.get("createdAt"),
        "lastUsedAt", t.get("lastUsedAt"));
  }

  /**
   * A request for one API path, with the asker's own headers, as the MCP server and the assistant
   * read it.
   */
  private Mcp.ApiRead readApi(Request request, Url url, String defaultSite) {
    Headers headers = new Headers(request.headers());
    for (String name : List.of("content-type", "content-length", SHARE_HEADER)) {
      headers.delete(name);
    }
    return (apiPath, params) -> {
      Url target = new Url(base + apiPath, url.origin());
      SearchParams query = target.searchParams();
      for (Map.Entry<String, String> e : params) {
        query.append(e.getKey(), e.getValue());
      }
      // A tool that names no site reads the one on screen, not the install's first.
      if (defaultSite != null && !apiPath.equals("/api/sites") && !query.has("site")) {
        query.set("site", defaultSite);
      }
      target.setSearchParams(query);
      return api(new Request(target.href(), "GET", headers, new byte[0], ""), apiPath, target);
    };
  }

  private Response api(Request request, String path, Url url) {
    Runlight rl = this.rl;
    String method = request.method();
    // A write must be JSON, which a form on another page cannot send, even the writes that carry
    // no body. That holds without a cookie too, since a browser also sends Basic credentials or
    // comes from an allowed address on its own. A bearer token is never sent by the browser on its
    // own, so it needs no check.
    if (!List.of("GET", "HEAD", "OPTIONS", "DELETE").contains(method)
        && bearer(request).isEmpty()
        && !isJson(request)) {
      return coded("Send JSON", "send_json", 415);
    }
    if (path.equals("/api") && method.equals("GET")) {
      Map<String, Object> about =
          Json.object(
              "name", "runlight", "version", Version.version(), "api", Version.apiVersion());
      about.putAll(IMPLEMENTATION);
      return json(about);
    }

    // A hub asks what its token may do before offering to change anything.
    if (path.equals("/api/token") && method.equals("GET")) {
      Map<String, Object> token = apiToken(request);
      if (token == null) {
        return denied(false);
      }
      return json(Json.object("scope", token.get("scope"), "site", token.get("site")));
    }
    // A token can delete itself, which a hub does when it disconnects a site or gets a new token.
    if (path.equals("/api/token") && method.equals("DELETE")) {
      Map<String, Object> token = apiToken(request);
      if (token == null) {
        return denied(false);
      }
      store().deleteToken((String) token.get("id"));
      return json(Json.object("ok", true));
    }

    // Connecting another Runlight through its consent page, so nobody copies a token.
    if (path.equals("/api/sites/connect") && method.equals("POST")) {
      Object access = canRead(request);
      if (!Boolean.TRUE.equals(access)) {
        return denied(access);
      }
      rl.init();
      if (!rl.managedSites) {
        return coded("Sites are set in code", "sites_in_code", 400);
      }
      Object read = readJson(request);
      if (read instanceof Response r) {
        return r;
      }
      Map<String, Object> body = asMap(read);
      Object site = Js.get(body, "site");
      Object given = Js.get(body, "url");
      try {
        return json(
            Json.object(
                "authorize",
                Connect.startConnect(
                    rl.store,
                    rl.fetcher,
                    rl::now,
                    given == Json.UNDEFINED ? null : given,
                    url.origin() + base + "/api/sites/connect/done",
                    site instanceof String s ? s : "")));
      } catch (ConnectError error) {
        return coded(
            error.getMessage(),
            error.code().equals("unreachable") ? "unreachable" : "connect_" + error.code(),
            400,
            paramsOf(error));
      } catch (RuntimeException error) {
        if (isRange(error)) {
          return refused(error, "connect_failed");
        }
        throw error;
      }
    }
    if (path.equals("/api/sites/connect/done") && method.equals("GET")) {
      String home = !base.isEmpty() ? base : "/";
      Object access = canRead(request);
      if (!Boolean.TRUE.equals(access)) {
        return new Response(
            new byte[0], 303, Headers.of("location", home, "cache-control", "no-store"));
      }
      rl.init();
      String to;
      try {
        String id =
            Connect.finishConnect(rl.store, rl.fetcher, rl::now, rl::addSite, url.searchParams());
        // The site's settings open with a word that the connection worked, which a reconnection
        // otherwise lacks.
        to = home + "?site=" + Js.encodeURIComponent(id) + "&settings=general&connected=1";
      } catch (RuntimeException error) {
        if (!isRange(error)) {
          throw error;
        }
        // A code, never the message: the dashboard shows its own words for it, so a link cannot
        // put text there.
        to = home + "?connect_error=" + (error instanceof ConnectError c ? c.code() : "failed");
      }
      return new Response(
          new byte[0], 303, Headers.of("location", to, "cache-control", "no-store"));
    }

    Map<String, Object> token = bearer(request).startsWith(TOKEN_PREFIX) ? apiToken(request) : null;
    if (token != null && "manage".equals(token.get("scope")) && managePath(method, path)) {
      String asked = url.searchParams().get("site");
      Matcher siteMatch = SITE_PATH.matcher(path);
      boolean isSite = siteMatch.find();
      if ((asked != null && !asked.isEmpty() && !asked.equals(token.get("site")))
          || (isSite && !decode(siteMatch.group(1)).equals(token.get("site")))) {
        return coded("Unknown site", "unknown_site", 404);
      }
      if (isSite && isJson(request)) {
        // Where a site lives stays with its owner: a hub may rename it, never move it.
        Json.Parsed parsed = Json.tryParse(request.text());
        if (parsed.ok()
            && Js.truthy(parsed.value())
            && Js.isObject(parsed.value())
            && Js.get(parsed.value(), "hostnames") != Json.UNDEFINED) {
          return coded("A connected hub cannot change a site's domains", "hub_domains", 403);
        }
      }
      url = new Url(url.href());
      SearchParams query = url.searchParams();
      query.set("site", Js.string(token.get("site")));
      url.setSearchParams(query);
      managed.put(request, token);
    }
    // A token this install made that tries a change it may not make is known, just not allowed, as
    // for a viewer.
    if (token != null
        && !managed.containsKey(request)
        && !List.of("GET", "HEAD", "OPTIONS").contains(method)) {
      return "manage".equals(token.get("scope"))
          ? coded("A manage token changes only its own site's settings", "token_manage_only", 403)
          : coded("API tokens can only read", "token_read_only", 403);
    }

    // A page another site served to an AI agent, reported by a CMS plugin.
    if (path.equals("/api/observe") && method.equals("POST")) {
      return observeApi(request);
    }

    // GET too: Vercel Cron calls with GET and the cron secret as a bearer token.
    if (path.equals("/api/check") && (method.equals("POST") || method.equals("GET"))) {
      String given = bearer(request);
      boolean allowed =
          (cronSecret != null
                  && !cronSecret.isEmpty()
                  && !given.isEmpty()
                  && constantTimeEqual(given, cronSecret))
              || owner(request);
      if (!allowed) {
        return coded("Unauthorized", "unauthorized", 401);
      }
      return json(rl.check());
    }

    // A site counted by another install is read there. Its settings change there too, through
    // this server when the install gave a manage token, and only by an owner here.
    String asked = url.searchParams().get("site");
    Map<String, Object> connected = asked != null && !asked.isEmpty() ? rl.remote(asked) : null;
    if (connected != null
        && "manage".equals(connected.get("scope"))
        && managePath(method, path)
        && !(method.equals("GET") && sharedPath(path))) {
      Object access = canRead(request);
      if (!Boolean.TRUE.equals(access)) {
        return denied(access);
      }
      if (!method.equals("GET")) {
        rl.forgetRemoteInfo(asked);
      }
      return passThrough(connected, path, url, request);
    }
    if (connected != null
        && !(method.equals("GET") && (sharedPath(path) || path.equals("/api/links")))) {
      return coded(
          "This site is counted by its own Runlight. Connect it again from its settings to change it from here.",
          "site_remote",
          400);
    }

    // Visit history from Umami: list the account's websites, then import one a step at a time.
    if ((path.equals("/api/import/umami/websites") || path.equals("/api/import/umami/visits"))
        && method.equals("POST")) {
      Object access = canRead(request);
      if (!Boolean.TRUE.equals(access)) {
        return denied(access);
      }
      Object read = readJson(request);
      if (read instanceof Response r) {
        return r;
      }
      Map<String, Object> body = asMap(read);
      Map<String, String> credentials = credentials(Js.get(body, "credentials"));
      try {
        if (path.equals("/api/import/umami/websites")) {
          return json(Json.object("websites", Visits.umamiWebsites(credentials, rl.fetcher)));
        }
        rl.init();
        Object found = querySite(url);
        if (found instanceof Response r) {
          return r;
        }
        Object cursor = Js.get(body, "cursor");
        return json(
            Visits.importUmamiVisits(
                rl,
                (String) asMap(found).get("id"),
                credentials,
                text(body, "website"),
                cursor instanceof String c ? c : null));
      } catch (ImportError error) {
        return refused(error, "import_failed");
      }
    }

    // Visit history from a CSV file, a batch at a time.
    if (path.equals("/api/import/csv/visits") && method.equals("POST")) {
      Object access = canRead(request);
      if (!Boolean.TRUE.equals(access)) {
        return denied(access);
      }
      Object read = readJson(request);
      if (read instanceof Response r) {
        return r;
      }
      rl.init();
      Object found = querySite(url);
      if (found instanceof Response r) {
        return r;
      }
      try {
        return json(
            Visits.importCsvVisits(
                rl, (String) asMap(found).get("id"), plain(Js.get(asMap(read), "rows"))));
      } catch (ImportError error) {
        return refused(error, "import_failed");
      }
    }

    // Each site's key for CMS plugins reporting AI agent fetches: made on first ask, replaced on
    // request.
    if ((path.equals("/api/observe-key") && method.equals("GET"))
        || (path.equals("/api/observe-key/new") && method.equals("POST"))) {
      Object access = canRead(request);
      if (!Boolean.TRUE.equals(access)) {
        return denied(access);
      }
      rl.init();
      Object found = querySite(url);
      if (found instanceof Response r) {
        return r;
      }
      String name = "observe-key:" + asMap(found).get("id");
      String key = path.endsWith("/new") ? null : store().setting(name);
      if (key == null || key.isEmpty()) {
        key = "rlo_" + Hash.randomId(20);
        store().setSetting(name, key);
      }
      return json(Json.object("key", key));
    }

    // Making, changing, and deleting funnels; reading them is with the other reports.
    if ((path.equals("/api/funnels") && method.equals("POST"))
        || (FUNNEL_PATH.matcher(path).find()
            && (method.equals("PATCH") || method.equals("DELETE")))) {
      Object access = canRead(request);
      if (!Boolean.TRUE.equals(access)) {
        return denied(access);
      }
      rl.init();
      Object found = querySite(url);
      if (found instanceof Response r) {
        return r;
      }
      Map<String, Object> site = asMap(found);
      List<Map<String, Object>> existing = store().funnels((String) site.get("id"));
      String id = path.equals("/api/funnels") ? null : path.substring("/api/funnels/".length());
      if (id != null && existing.stream().noneMatch(f -> id.equals(f.get("id")))) {
        return coded("Unknown funnel", "unknown_funnel", 404);
      }
      if (method.equals("DELETE")) {
        store().deleteFunnel(id);
        return json(Json.object("ok", true));
      }
      Object read = readJson(request);
      if (read instanceof Response r) {
        return r;
      }
      try {
        Map<String, Object> funnel =
            Funnels.funnelFrom(read, (String) site.get("id"), existing, rl.now(), id);
        store().saveFunnel(funnel);
        return json(Json.object("funnel", funnel), id != null ? 200 : 201);
      } catch (FunnelError error) {
        return refused(error, "funnel_invalid");
      }
    }

    // The assistant: an owner sets it up; anyone signed in to the dashboard can ask it.
    if (path.equals("/api/assistant")) {
      Object self = canRead(request);
      // A member uses the assistant like anyone else, but its settings are for owners and admins.
      boolean owner = Boolean.TRUE.equals(self) && !members.containsKey(request);
      if (method.equals("GET")) {
        Object access = reader(request);
        if (refusedReader(access)) {
          return denied(access);
        }
        // Only people at the dashboard, never an API token or a share, so nobody spends the
        // owner's AI credit from outside.
        if (access instanceof Map<?, ?> t && !"".equals(t.get("id"))) {
          return coded("Only the dashboard can use the assistant", "assistant_dashboard", 403);
        }
        rl.init();
        Map<String, Object> settings = rl.assistantSettings();
        if (!owner) {
          return json(Json.object("configured", settings != null));
        }
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("configured", settings != null);
        out.put("viewerDaily", viewerDaily());
        out.put("provider", orEmpty(settings, "provider"));
        out.put("model", orEmpty(settings, "model"));
        out.put("baseUrl", orEmpty(settings, "baseUrl"));
        out.put("keySaved", settings != null && Js.truthy(settings.get("key")));
        out.put("encrypted", rl.secret != null);
        out.put("providers", Assistant.PROVIDERS);
        return json(out);
      }
      if (!owner) {
        return Boolean.TRUE.equals(self)
            ? coded("Only an owner or admin can change this", "admin_only", 403)
            : denied(self);
      }
      rl.init();
      if (method.equals("DELETE")) {
        rl.saveAssistantSettings(null);
        return json(Json.object("ok", true));
      }
      if (method.equals("PUT")) {
        Object read = readJson(request);
        if (read instanceof Response r) {
          return r;
        }
        try {
          rl.saveAssistantSettings(asMap(read));
          return json(Json.object("ok", true));
        } catch (RuntimeException error) {
          if (isRange(error)) {
            return refused(error, "assistant_invalid");
          }
          throw error;
        }
      }
      return coded("Method not allowed", "method_not_allowed", 405);
    }
    // How many questions each viewer may ask a day; 0 keeps the assistant for owners.
    if (path.equals("/api/assistant/limits") && method.equals("PUT")) {
      Object access = canRead(request);
      if (!Boolean.TRUE.equals(access)) {
        return denied(access);
      }
      rl.init();
      Object read = readJson(request);
      if (read instanceof Response r) {
        return r;
      }
      Object value = Js.get(asMap(read), "viewerDaily");
      double daily = value == Json.UNDEFINED ? Double.NaN : Js.toNumber(value);
      if (!Js.isInteger(daily) || daily < 0 || daily > 1000) {
        return coded("Use a whole number from 0 to 1,000", "assistant_limit", 400);
      }
      Object whole = Js.num(daily);
      store().setSetting("assistant-viewer-daily", Js.string(whole));
      return json(Json.object("viewerDaily", whole));
    }
    // The models a service offers, for the setup form's dropdown. The key can be the one already
    // saved.
    if (path.equals("/api/assistant/models") && method.equals("POST")) {
      Object access = canRead(request);
      if (!Boolean.TRUE.equals(access)) {
        return denied(access);
      }
      rl.init();
      Object read = readJson(request);
      if (read instanceof Response r) {
        return r;
      }
      Map<String, Object> body = asMap(read);
      String provider = text(body, "provider");
      Map<String, Object> saved = rl.assistantSettings();
      String baseUrl = Js.trim(text(body, "baseUrl")).replaceFirst("/+\\z", "");
      // The saved key only for the address it was saved with.
      boolean sameAddress =
          saved != null
              && provider.equals(saved.get("provider"))
              && (Js.truthy(saved.get("baseUrl")) ? saved.get("baseUrl") : "").equals(baseUrl);
      String key = Js.trim(text(body, "key"));
      if (key.isEmpty()) {
        key = sameAddress ? Js.string(saved.get("key")) : "";
      }
      try {
        return json(
            Json.object(
                "models",
                Assistant.listModels(
                    Json.object(
                        "provider",
                        provider,
                        "baseUrl",
                        Js.trim(text(body, "baseUrl")),
                        "key",
                        key),
                    rl.fetcher)));
      } catch (AssistantError error) {
        return refused(error, "assistant_failed");
      }
    }
    if (path.equals("/api/assistant/chat") && method.equals("POST")) {
      return chat(request, url);
    }

    // Only the owner manages tokens: an API token cannot make or revoke one.
    if (path.equals("/api/tokens") || path.startsWith("/api/tokens/")) {
      Object access = canRead(request);
      if (!Boolean.TRUE.equals(access)) {
        return denied(access);
      }
      return tokensApi(request, path);
    }

    if (connected != null && path.equals("/api/links")) {
      Object access = reader(request);
      if (refusedReader(access)) {
        return denied(access);
      }
      // A token limited to one site reads only that site's links, here as everywhere else.
      if (access instanceof Map<?, ?> t
          && !"".equals(t.get("site"))
          && !asked.equals(t.get("site"))) {
        return coded("Unknown site", "unknown_site", 404);
      }
      return passThrough(connected, path, url, null);
    }

    // An API token, or someone signed in to read, may list links and see each one's clicks, but
    // not change them.
    if (method.equals("GET") && (path.equals("/api/links") || LINK_PATH.matcher(path).find())) {
      Object access = reader(request);
      if (refusedReader(access)) {
        return denied(access);
      }
      if (access instanceof Map<?, ?> t) {
        rl.init();
        String only = (String) t.get("site");
        String named = url.searchParams().get("site");
        Map<String, Object> site = rl.site(named != null ? named : !only.isEmpty() ? only : null);
        if (site == null || (!only.isEmpty() && !only.equals(site.get("id")))) {
          return coded("Unknown site", "unknown_site", 404);
        }
        Url scoped = new Url(url.href());
        SearchParams query = scoped.searchParams();
        query.set("site", (String) site.get("id"));
        scoped.setSearchParams(query);
        return linksApi(request, path, scoped);
      }
    }

    if (path.equals("/api/links")
        || path.startsWith("/api/links/")
        || path.equals("/api/link-domains")
        || path.startsWith("/api/link-domains/")) {
      Object access = canRead(request);
      if (!Boolean.TRUE.equals(access)) {
        return denied(access);
      }
      return linksApi(request, path, url);
    }

    if (path.equals("/api/mail")
        || path.equals("/api/mail/test")
        || path.equals("/api/reports")
        || path.startsWith("/api/reports/")) {
      Object access = canRead(request);
      if (!Boolean.TRUE.equals(access)) {
        return denied(access);
      }
      return mailApi(request, path, url);
    }

    // A ticket for the element picker, naming the dashboard it may send its choice to. A hub asks
    // the install that serves the site's script, with its own origin, since that install signs
    // what the script will trust.
    if (path.equals("/api/pick") && method.equals("POST")) {
      Object access = canRead(request);
      if (!Boolean.TRUE.equals(access)) {
        return denied(access);
      }
      rl.init();
      Object found = querySite(url);
      if (found instanceof Response r) {
        return r;
      }
      Object read = readJson(request);
      if (read instanceof Response r) {
        return r;
      }
      String pickOrigin = text(asMap(read), "origin");
      if (!isOrigin(pickOrigin)) {
        return coded(
            "Send the dashboard's origin, such as https://stats.example.com", "pick_origin", 400);
      }
      // A hub's ticket only ever sends to the hub it connected from, never to an origin it names
      // now.
      Map<String, Object> hub = managed.get(request);
      if (hub != null && !pickOrigin.equals(store().setting("token-origin:" + hub.get("id")))) {
        return coded(
            "This hub's address is not the one it connected from. Connect the site again from here.",
            "pick_hub",
            403);
      }
      return json(Json.object("ticket", pickTicket(pickOrigin, (String) asMap(found).get("id"))));
    }

    if ((path.equals("/api/goals") && method.equals("POST"))
        || (GOAL_WRITE.matcher(path).find()
            && (method.equals("PATCH") || method.equals("DELETE")))) {
      Object access = canRead(request);
      if (!Boolean.TRUE.equals(access)) {
        return denied(access);
      }
      return goalWrites(request, path, url);
    }

    if (path.equals("/api/shares") || path.startsWith("/api/shares/")) {
      Object access = canRead(request);
      if (!Boolean.TRUE.equals(access)) {
        return denied(access);
      }
      return sharesApi(request, path, url);
    }

    // Adding and deleting sites, when they are managed in the dashboard.
    if (path.equals("/api/sites") && method.equals("POST")) {
      Object access = canRead(request);
      if (!Boolean.TRUE.equals(access)) {
        return denied(access);
      }
      Object read = readJson(request);
      if (read instanceof Response r) {
        return r;
      }
      try {
        return json(Json.object("site", rl.addSite(asMap(read))), 201);
      } catch (RuntimeException error) {
        if (isRange(error)) {
          return refused(error, "site_invalid");
        }
        throw error;
      }
    }

    Matcher siteMatch = SITE_PATH.matcher(path);
    boolean isSite = siteMatch.find();
    if (isSite && method.equals("DELETE")) {
      Object access = canRead(request);
      if (!Boolean.TRUE.equals(access)) {
        return denied(access);
      }
      try {
        rl.deleteSite(decode(siteMatch.group(1)));
        return json(Json.object("ok", true));
      } catch (RuntimeException error) {
        if (!isRange(error)) {
          throw error;
        }
        return "Unknown site".equals(error.getMessage())
            ? coded(error.getMessage(), "unknown_site", 404)
            : refused(error, "site_invalid");
      }
    }
    if (isSite && method.equals("PATCH")) {
      return patchSite(request, siteMatch.group(1), url);
    }

    if (!method.equals("GET")) {
      return coded("Method not allowed", "method_not_allowed", 405);
    }
    return reports(request, path, url);
  }

  private Response observeApi(Request request) {
    Runlight rl = this.rl;
    String given = bearer(request);
    // The install-wide key and the owner's access can report for any site.
    boolean anySite =
        (observeKey != null
                && !observeKey.isEmpty()
                && !given.isEmpty()
                && constantTimeEqual(given, observeKey))
            || owner(request);
    if (!anySite && given.isEmpty()) {
      return coded("Unauthorized", "unauthorized", 401);
    }
    Object read = readJson(request);
    if (read instanceof Response r) {
      return r;
    }
    Map<String, Object> body = asMap(read);
    // One fetch as { url, userAgent, at? }, or up to 500 as { fetches: [...] } from a log reader.
    Object fetches = Js.get(body, "fetches");
    boolean batch = fetches instanceof List<?>;
    List<?> list = batch ? (List<?>) fetches : List.of(body);
    if (list.size() > 500) {
      return coded("Send at most 500 fetches at a time", "observe_many", 413);
    }
    record Page(Url page, String userAgent, Double at) {}
    List<Page> pages = new ArrayList<>();
    for (Object item : list) {
      Function<String, Object> field =
          key -> item instanceof Map<?, ?> ? Js.get(item, key) : Json.UNDEFINED;
      Object raw = field.apply("url");
      Url page = Url.parse(raw == null || raw == Json.UNDEFINED ? "" : Js.string(raw));
      if (page == null || (!page.protocol.equals("https:") && !page.protocol.equals("http:"))) {
        return coded("Send the page's url", "observe_url", 400);
      }
      Object at = field.apply("at");
      double when =
          at instanceof Number n
              ? n.doubleValue()
              : at instanceof String s ? sh.runlight.importers.Http.parseDate(s) : Double.NaN;
      Object agent = field.apply("userAgent");
      pages.add(
          new Page(
              page,
              Js.slice(agent == null || agent == Json.UNDEFINED ? "" : Js.string(agent), 0, 500),
              Double.isFinite(when) ? when : null));
    }
    rl.init();
    List<Page> keep = pages;
    if (!anySite) {
      // A site's own key reports only pages on that site's domains. Pages elsewhere in a batch
      // (another host in the same log, say) are skipped, not a reason to refuse the rest.
      String keySite = null;
      for (Map<String, Object> site : sites()) {
        String key = store().setting("observe-key:" + site.get("id"));
        if (key != null && !key.isEmpty() && constantTimeEqual(given, key)) {
          keySite = (String) site.get("id");
        }
      }
      if (keySite == null) {
        return coded("Unauthorized", "unauthorized", 401);
      }
      keep = new ArrayList<>();
      for (Page p : pages) {
        Map<String, Object> site = rl.siteFor(p.page().hostname);
        if (site != null && keySite.equals(site.get("id"))) {
          keep.add(p);
        }
      }
      // A single report for another site's page is a misconfigured plugin, which should hear
      // about it.
      if (!batch && keep.isEmpty()) {
        return coded("Unauthorized", "unauthorized", 401);
      }
    }
    long recorded = 0;
    for (Page p : keep) {
      Request fetch =
          new Request(
              p.page().href(), "GET", Headers.of("user-agent", p.userAgent()), new byte[0], "");
      if (rl.observe(fetch, p.at())) {
        recorded++;
      }
    }
    // A single report, as the CMS plugins send, needs no answer; a batch learns what was kept.
    if (!batch) {
      return new Response(new byte[0], 204, new Headers());
    }
    return json(Json.object("recorded", recorded, "skipped", pages.size() - recorded));
  }

  private Response chat(Request request, Url url) {
    Runlight rl = this.rl;
    Object access = reader(request);
    if (refusedReader(access)) {
      return denied(access);
    }
    if (access instanceof Map<?, ?> t && !"".equals(t.get("id"))) {
      return coded("Only the dashboard can use the assistant", "assistant_dashboard", 403);
    }
    if (request.headers().get(SHARE_HEADER) != null) {
      return coded("Not available on a shared dashboard", "share_not_available", 403);
    }
    rl.init();
    Map<String, Object> settings = rl.assistantSettings();
    if (settings == null) {
      return coded(
          "The assistant is not set up yet. An owner can set it up in Settings, AI Assistant.",
          "assistant_unset",
          400);
    }
    Object read = readJson(request);
    if (read instanceof Response r) {
      return r;
    }
    Map<String, Object> body = asMap(read);
    String siteId = text(body, "site");
    Map<String, Object> site = rl.site(!siteId.isEmpty() ? siteId : null);
    if (site == null) {
      return coded("Unknown site", "unknown_site", 404);
    }
    List<Map<String, Object>> messages = new ArrayList<>();
    if (Js.get(body, "messages") instanceof List<?> given) {
      for (Object m : given) {
        if (m instanceof Map<?, ?> message
            && ("user".equals(message.get("role")) || "assistant".equals(message.get("role")))
            && message.get("content") instanceof String content) {
          messages.add(Json.object("role", message.get("role"), "content", content));
        }
      }
    }
    if (messages.isEmpty() || !"user".equals(messages.get(messages.size() - 1).get("role"))) {
      return coded("Ask a question", "question_needed", 400);
    }
    boolean owner = Boolean.TRUE.equals(access);
    String who = accountOf != null ? accountOf.apply(request) : null;
    Object turn = askTurn(who != null ? who : owner ? "owner" : "viewer", owner);
    if (turn instanceof Response r) {
      return r;
    }
    String language = Js.string(Js.get(body, "language"));
    try {
      Map<String, Object> answer =
          Assistant.chat(
              settings,
              messages,
              Json.object(
                  "site",
                  Json.object(
                      "id",
                      site.get("id"),
                      "name",
                      site.get("name"),
                      "timezone",
                      site.get("timezone")),
                  "today",
                  Time.localDate(rl.now(), (String) site.get("timezone")),
                  "view",
                  Js.slice(text(body, "view", "the last 30 days"), 0, 200),
                  "language",
                  LANGUAGE.matcher(language).find() ? language : "en"),
              // Each tool reads the HTTP API with the asker's own headers, as the MCP server does.
              readApi(request, url, (String) site.get("id")),
              rl.fetcher,
              rl::now,
              null);
      return json(answer);
    } catch (AssistantError error) {
      return refused(error, "assistant_failed", 502);
    } finally {
      ((Runnable) turn).run();
    }
  }

  private Response patchSite(Request request, String rawId, Url url) {
    Runlight rl = this.rl;
    Object access = canRead(request);
    if (!Boolean.TRUE.equals(access)) {
      return denied(access);
    }
    // A form posted from another site cannot carry this content type without CORS.
    Object read = readJson(request);
    if (read instanceof Response r) {
      return r;
    }
    Map<String, Object> body = asMap(read);
    rl.init();
    // Every field is checked before any changes, since a shorter retention deletes visits at once.
    if (defined(body, "name")) {
      String name = Js.trim(Js.string(Js.get(body, "name")));
      if (!(!name.isEmpty() && name.length() <= 80)) {
        return coded("A site name is 1 to 80 characters", "site_name", 400);
      }
    }
    if (defined(body, "timezone") && !Time.isTimezone(Js.string(Js.get(body, "timezone")))) {
      String timezone = Js.string(Js.get(body, "timezone"));
      return coded(
          "Unknown timezone \"" + timezone + "\"",
          "unknown_timezone",
          400,
          Json.object("timezone", timezone));
    }
    Object retention = Js.get(body, "retentionMonths");
    if (retention != Json.UNDEFINED && retention != null && retentionChoice(retention) == null) {
      String months = String.join(", ", Js.strings(Runlight.RETENTION_MONTHS));
      return coded(
          "Keep visits for " + months + " months, or forever",
          "retention_bad",
          400,
          Json.object("months", months));
    }
    try {
      String id = decode(rawId);
      Map<String, Object> remote = rl.remote(id);
      // How long a connected site keeps visits, and the timezone its days follow, are the
      // install's settings: this server passes them on, and changes its own row only once the
      // install took them.
      Map<String, Object> forward = new LinkedHashMap<>();
      if (retention != Json.UNDEFINED) {
        forward.put("retentionMonths", retention);
      }
      Map<String, Object> current = rl.site(id);
      if (defined(body, "timezone")
          && !Js.string(Js.get(body, "timezone"))
              .equals(current == null ? null : current.get("timezone"))) {
        forward.put("timezone", Js.string(Js.get(body, "timezone")));
      }
      if (remote != null && !forward.isEmpty()) {
        if (!"manage".equals(remote.get("scope"))) {
          return coded("Connect this site again to change it from here", "connect_again", 400);
        }
        Response answer =
            passThrough(
                remote,
                "/api/sites/" + Js.encodeURIComponent(Js.string(remote.get("site"))),
                new Url(url.href()),
                new Request(
                    request.url(),
                    "PATCH",
                    Headers.of("content-type", "application/json"),
                    Json.stringify(forward)));
        if (!answer.ok()) {
          return answer;
        }
        rl.forgetRemoteInfo(id);
      } else if (remote == null && retention != Json.UNDEFINED) {
        rl.setRetention(id, retention == null ? null : Js.num(Js.toNumber(retention)));
      }
      Map<String, Object> patch = new LinkedHashMap<>();
      if (defined(body, "name")) {
        patch.put("name", Js.string(Js.get(body, "name")));
      }
      if (defined(body, "timezone")) {
        patch.put("timezone", Js.string(Js.get(body, "timezone")));
      }
      if (defined(body, "hostnames") && rl.managedSites) {
        patch.put("hostnames", plain(Js.get(body, "hostnames")));
      }
      Map<String, Object> site = new LinkedHashMap<>(rl.updateSite(decode(rawId), patch));
      // A connected site answers as the list shows it, so the dashboard keeps its install and
      // domains.
      if (remote != null) {
        site.put("remote", remote.get("url"));
        site.put("remoteSite", remote.get("site"));
        site.put("manage", "manage".equals(remote.get("scope")));
        site.put("hostnames", remote.get("hostnames"));
      }
      return json(Json.object("site", site));
    } catch (RuntimeException error) {
      if (!isRange(error)) {
        throw error;
      }
      return "Unknown site".equals(error.getMessage())
          ? coded(error.getMessage(), "unknown_site", 404)
          : refused(error, "site_invalid");
    }
  }

  /** Number(value) as one of the retention choices compares it, or null when it is none. */
  private static Long retentionChoice(Object value) {
    double n = Js.toNumber(value);
    for (Long months : Runlight.RETENTION_MONTHS) {
      if (months == n) {
        return months;
      }
    }
    return null;
  }

  /** The reads: sites, stats, and every report, for the owner, a token, a viewer, or a share. */
  private Response reports(Request request, String path, Url url) {
    Runlight rl = this.rl;
    SqlStore store = store();
    SearchParams params = url.searchParams();
    rl.init();
    // A shared dashboard sees exactly what its visitors see, even for someone signed in.
    String shareId = request.headers().get(SHARE_HEADER);
    Map<String, Object> shared = null;
    // The one site a share or a site's API token may read; null for every site.
    String only = null;
    if (shareId != null) {
      shared = SHARE_ID.matcher(shareId).find() ? store.shareById(shareId) : null;
      if (shared == null) {
        return coded("This share link no longer works", "share_gone", 404);
      }
      if (!sharedPath(path)) {
        return coded("Not available on a shared dashboard", "share_not_available", 403);
      }
      only = (String) shared.get("site");
    } else {
      Object access = reader(request);
      if (refusedReader(access)) {
        return denied(access);
      }
      if (!Boolean.TRUE.equals(access)) {
        if (!sharedPath(path)) {
          return coded("API tokens can only read", "token_read_only", 403);
        }
        String tokenSite = (String) asMap(access).get("site");
        only = !tokenSite.isEmpty() ? tokenSite : null;
      }
    }

    if (path.equals("/api/sites")) {
      List<Object> sites = new ArrayList<>();
      for (Map<String, Object> site : sites()) {
        if (only != null && !only.equals(site.get("id"))) {
          continue;
        }
        String id = (String) site.get("id");
        Map<String, Object> remote = rl.remote(id);
        Map<String, Object> row = new LinkedHashMap<>(site);
        // A connected install's address, so the dashboard can say where the site is counted. Its
        // domains as the install reported them, for the goal picker; tracker hits never match them
        // here.
        if (remote != null && shared == null) {
          row.put("remote", remote.get("url"));
          row.put("remoteSite", remote.get("site"));
          row.put("manage", "manage".equals(remote.get("scope")));
          row.put("hostnames", remote.get("hostnames"));
        }
        // Hostnames say where the site lives; a share shows only its name.
        if (shared != null) {
          row.put("hostnames", new ArrayList<>());
        }
        row.put("lastSeen", remote != null ? rl.remoteLastSeen(id) : store.lastSeen(id));
        // Left out for a connected install that cannot be reached, so nobody reads "forever" by
        // mistake.
        if (shared == null) {
          row.put(
              "retentionMonths",
              remote != null ? field(rl.remoteInfo(id), "retentionMonths") : rl.retention(id));
        }
        // Whether a connected install still takes this server's token, so the dashboard offers to
        // connect it again only when it no longer does.
        if (remote != null && shared == null) {
          row.put("connection", field(rl.remoteInfo(id), "connection"));
        }
        sites.add(row);
      }
      // A share never learns how the install is run.
      return json(
          shared != null
              ? Json.object("sites", sites)
              : Json.object("sites", sites, "managed", rl.managedSites));
    }

    Map<String, Object> site;
    if (shared != null) {
      site = rl.site((String) shared.get("site"));
    } else if (only != null) {
      site = rl.site(params.get("site") != null ? params.get("site") : only);
    } else {
      Object found = querySite(url);
      if (found instanceof Response r) {
        return r;
      }
      site = asMap(found);
    }
    if (site == null || (only != null && !only.equals(site.get("id")))) {
      return coded("Unknown site", "unknown_site", 404);
    }
    String siteId = (String) site.get("id");
    String timezone = (String) site.get("timezone");
    Map<String, Object> remote = rl.remote(siteId);
    if (remote != null) {
      return passThrough(remote, path, url, request);
    }

    if (path.equals("/api/icon")) {
      List<Object> hostnames = Js.list(site.get("hostnames"));
      Object host = hostnames == null || hostnames.isEmpty() ? null : hostnames.get(0);
      // Only a site's own domain, never the request's Host header, which a caller can write.
      Map<String, Object> icon =
          host instanceof String h && !h.isEmpty()
              ? Icon.fetchIcon("https://" + h, rl.now(), rl.fetcher)
              : null;
      if (icon == null) {
        return coded(
            "No icon", "icon_none", 404, null, Map.of("cache-control", "private, max-age=3600"));
      }
      return new Response(
          (byte[]) icon.get("body"),
          200,
          Headers.of(
              "content-type",
              (String) icon.get("type"),
              "cache-control",
              "private, max-age=86400",
              // An SVG served from this origin must never run script.
              "content-security-policy",
              "default-src 'none'; style-src 'unsafe-inline'; sandbox",
              "x-content-type-options",
              "nosniff"));
    }

    if (path.equals("/api/realtime")) {
      return json(store.realtime(siteId, rl.now()));
    }

    Object read = readQuery(url, site);
    if (read instanceof Response r) {
      return r;
    }
    Map<String, Object> query = asMap(asMap(read).get("query"));
    Map<String, Object> range = asMap(asMap(read).get("range"));
    Map<String, Object> compared = asMap(asMap(read).get("compared"));
    Map<String, Object> out = rangeOut(range, site);
    Object compareOut =
        compared != null
            ? Json.object("from", compared.get("fromDate"), "to", compared.get("toDate"))
            : Json.UNDEFINED;
    Map<String, Object> before = null;
    if (compared != null) {
      before = new LinkedHashMap<>();
      before.put("from", compared.get("from"));
      before.put("to", compared.get("to"));
      for (Map.Entry<String, Object> e : query.entrySet()) {
        before.putIfAbsent(e.getKey(), e.getValue());
      }
    }

    if (path.equals("/api/stats")) {
      Map<String, Object> stats = store.stats(query);
      Object previous = before != null ? store.stats(before) : Json.UNDEFINED;
      return json(
          Json.object(
              "site",
              siteId,
              "range",
              out,
              "compare",
              compareOut,
              "stats",
              stats,
              "previous",
              previous));
    }

    if (path.equals("/api/goals")) {
      List<Map<String, Object>> goals = store.goals(siteId);
      double visitors = Js.asDouble(store.visitors(query));
      double previousVisitors = before != null ? Js.asDouble(store.visitors(before)) : 0;
      // Every goal in one pass for the range, and one more for the comparison.
      Map<String, Map<String, Object>> nowAll = store.goalTotalsAll(query, goals);
      Map<String, Map<String, Object>> beforeAll =
          before != null ? store.goalTotalsAll(before, goals) : null;
      List<Object> rows = new ArrayList<>();
      for (Map<String, Object> goal : goals) {
        Map<String, Object> now = nowAll.get(goal.get("id"));
        Map<String, Object> then = beforeAll != null ? beforeAll.get(goal.get("id")) : null;
        Map<String, Object> row = new LinkedHashMap<>(goal);
        row.putAll(now);
        row.put("rate", visitors != 0 ? Js.num(Js.asDouble(now.get("visitors")) / visitors) : 0L);
        if (then != null) {
          Map<String, Object> earlier = new LinkedHashMap<>(then);
          earlier.put(
              "rate",
              previousVisitors != 0
                  ? Js.num(Js.asDouble(then.get("visitors")) / previousVisitors)
                  : 0L);
          row.put("previous", earlier);
        } else {
          row.put("previous", Json.UNDEFINED);
        }
        rows.add(row);
      }
      return json(
          Json.object(
              "site",
              siteId,
              "range",
              out,
              "compare",
              compareOut,
              "visitors",
              Js.num(visitors),
              "goals",
              rows));
    }

    Matcher goalMatch = GOAL_READ.matcher(path);
    if (goalMatch.find()) {
      Map<String, Object> goal = store.goalById(goalMatch.group(1));
      if (goal == null || !siteId.equals(goal.get("site"))) {
        return coded("Unknown goal", "unknown_goal", 404);
      }
      double visitors = Js.asDouble(store.visitors(query));
      Map<String, Object> totals = new LinkedHashMap<>(store.goalTotals(query, goal));
      List<Map<String, Object>> series =
          store.goalSeries(query, goal, Time.buckets(range, timezone));
      List<Map<String, Object>> sources = store.goalBreakdown(query, goal, "source");
      List<Map<String, Object>> channels = store.goalBreakdown(query, goal, "channel");
      List<Map<String, Object>> pages = store.goalBreakdown(query, goal, "path");
      totals.put(
          "rate", visitors != 0 ? Js.num(Js.asDouble(totals.get("visitors")) / visitors) : 0L);
      return json(
          Json.object(
              "site",
              siteId,
              "range",
              out,
              "goal",
              goal,
              "totals",
              totals,
              "series",
              series,
              "sources",
              sources,
              "channels",
              channels,
              "pages",
              pages));
    }

    if (path.equals("/api/series")) {
      List<Map<String, Object>> points = store.series(query, Time.buckets(range, timezone));
      // Comparison points line up with the main ones by position.
      Object previous = Json.UNDEFINED;
      if (compared != null) {
        List<Map<String, Object>> earlier = store.series(query, Time.buckets(compared, timezone));
        previous = new ArrayList<>(earlier.subList(0, Math.min(earlier.size(), points.size())));
      }
      return json(
          Json.object(
              "site",
              siteId,
              "range",
              out,
              "compare",
              compareOut,
              "points",
              points,
              "previous",
              previous));
    }

    if (path.equals("/api/rhythm")) {
      // Visits per weekday and hour, plus each cell's details for its tooltip. Visitors are summed
      // over the hours folded into a cell, so someone who came on two Tuesdays at 2pm counts twice
      // there.
      double[][][] cells = new double[7][24][4];
      for (Map<String, Object> row : store.hourly(query)) {
        int[] at =
            Time.localWeekdayHour((long) (Js.asDouble(row.get("quarter")) * 900_000), timezone);
        double[] cell = cells[at[0]][at[1]];
        cell[0] += Js.asDouble(row.get("visits"));
        cell[1] += Js.asDouble(row.get("visitors"));
        cell[2] += Js.asDouble(row.get("pageviews"));
        cell[3] += Js.asDouble(row.get("bounced"));
      }
      List<Object> grid = new ArrayList<>();
      List<Object> details = new ArrayList<>();
      for (double[][] day : cells) {
        List<Object> gridDay = new ArrayList<>();
        List<Object> detailDay = new ArrayList<>();
        for (double[] c : day) {
          gridDay.add(Js.num(c[0]));
          detailDay.add(
              Json.object(
                  "visits", Js.num(c[0]),
                  "visitors", Js.num(c[1]),
                  "pageviews", Js.num(c[2]),
                  "bounceRate", c[0] != 0 ? Js.num(c[3] / c[0]) : 0L));
        }
        grid.add(gridDay);
        details.add(detailDay);
      }
      return json(Json.object("site", siteId, "range", out, "grid", grid, "cells", details));
    }

    if (path.equals("/api/journeys")) {
      String throughParam = params.get("through");
      Matcher through = THROUGH.matcher(throughParam == null ? "" : throughParam);
      boolean hasThrough = through.find();
      // Journeys reads the newest visits up to a cap; say when it was reached.
      Map<String, Object> pages = store.journeyPages(query, Journeys.PAGES_PER_VISIT);
      Map<String, Object> journeyOptions = new LinkedHashMap<>();
      String steps = params.get("steps");
      journeyOptions.put("steps", Js.num(Js.toNumber(steps != null ? steps : (Object) 5L)));
      if (Js.truthy(params.get("start"))) {
        journeyOptions.put("start", params.get("start"));
      }
      if (Js.truthy(params.get("end"))) {
        journeyOptions.put("end", params.get("end"));
      }
      if (hasThrough) {
        journeyOptions.put(
            "through",
            Json.object("step", Js.num(Js.toNumber(through.group(1))), "value", through.group(2)));
      }
      @SuppressWarnings("unchecked")
      List<Map<String, Object>> rows = (List<Map<String, Object>>) pages.get("rows");
      Map<String, Object> answer = Json.object("site", siteId, "range", out);
      answer.putAll(Journeys.journeys(rows, journeyOptions));
      if (Js.truthy(pages.get("sampled"))) {
        answer.put("sampled", (long) SqlStore.JOURNEY_VISITS);
      }
      return json(answer);
    }

    if (path.equals("/api/funnels")) {
      // One funnel at a time, so a page of funnels never takes every database connection at once.
      List<Object> rows = new ArrayList<>();
      for (Map<String, Object> funnel : store.funnels(siteId)) {
        List<Object> counts = store.funnelCounts(query, funnel);
        List<Object> steps = new ArrayList<>();
        List<Object> given = Js.list(funnel.get("steps"));
        for (int i = 0; i < given.size(); i++) {
          Map<String, Object> step = new LinkedHashMap<>(Js.map(given.get(i)));
          step.put("visits", counts.get(i));
          steps.add(step);
        }
        Map<String, Object> row = new LinkedHashMap<>(funnel);
        row.put("steps", steps);
        rows.add(row);
      }
      return json(Json.object("site", siteId, "range", out, "funnels", rows));
    }

    if (path.equals("/api/event-props")) {
      String event = params.get("event") != null ? params.get("event") : "";
      if (event.isEmpty()) {
        return coded("Name the event", "event_needed", 400);
      }
      List<Map<String, Object>> keys = store.eventPropKeys(query, event);
      String asked = params.get("key");
      // A property name goes into a JSON path on SQLite, so quotes and backslashes are refused.
      if (asked != null
          && (asked.isEmpty()
              || asked.length() > 64
              || asked.indexOf('"') >= 0
              || asked.indexOf('\\') >= 0)) {
        return coded("Bad property name", "property_bad", 400);
      }
      Object key = asked != null ? asked : keys.isEmpty() ? null : keys.get(0).get("key");
      double limit = limit(params.get("limit"), 100);
      List<Map<String, Object>> rows =
          key instanceof String k && !k.isEmpty()
              ? store.eventPropValues(query, event, k, (int) limit)
              : new ArrayList<>();
      return json(
          Json.object(
              "site", siteId, "range", out, "event", event, "keys", keys, "key", key, "rows",
              rows));
    }

    if (path.equals("/api/breakdown")) {
      String dimension = params.get("dimension") != null ? params.get("dimension") : "";
      if (!Query.isDimension(dimension)) {
        return coded(
            "Unknown dimension \"" + dimension + "\"",
            "unknown_dimension",
            400,
            Json.object("dimension", dimension));
      }
      double limit = limit(params.get("limit"), 10);
      double page = Js.toNumber(params.get("page"));
      page = Math.max(1, Double.isNaN(page) || page == 0 ? 1 : page);
      List<Map<String, Object>> rows =
          store.breakdown(query, dimension, (int) limit, (int) ((page - 1) * limit));
      if ("csv".equals(params.get("format"))) {
        return download(
            siteId
                + "-"
                + dimension
                + "-"
                + range.get("fromDate")
                + "-"
                + range.get("toDate")
                + ".csv",
            Js.utf8(rowsCsv(rows, Json.object("timezone", timezone, "dimension", dimension))),
            "text/csv; charset=utf-8");
      }
      return json(Json.object("site", siteId, "range", out, "dimension", dimension, "rows", rows));
    }

    // Everything the dashboard shows for a view, as a ZIP of CSV files.
    if (path.equals("/api/export")) {
      List<Map<String, Object>> files = new ArrayList<>();
      Map<String, Object> stats = store.stats(query);
      Map<String, Object> previous = before != null ? store.stats(before) : null;
      Map<String, Object> sheet = Json.object("timezone", timezone);
      Map<String, Object> now = sheetRow(stats, sheet);
      Map<String, Object> then = previous != null ? sheetRow(previous, sheet) : null;
      List<List<Object>> overview = new ArrayList<>();
      for (Map.Entry<String, Object> e : Js.entries(now)) {
        List<Object> line = new ArrayList<>();
        line.add(e.getKey());
        line.add(e.getValue());
        if (then != null) {
          line.add(then.get(e.getKey()));
        }
        overview.add(line);
      }
      files.add(
          Json.object(
              "name",
              "overview.csv",
              "text",
              Zip.csv(
                  then != null
                      ? List.of("metric", "value", "previous")
                      : List.of("metric", "value"),
                  overview)));
      List<Map<String, Object>> points = store.series(query, Time.buckets(range, timezone));
      files.add(
          Json.object(
              "name",
              "over-time.csv",
              "text",
              rowsCsv(
                  points, Json.object("timezone", timezone, "interval", range.get("interval")))));
      for (String dimension : Query.DIMENSIONS) {
        List<Map<String, Object>> rows = store.breakdown(query, dimension, 1000, 0);
        if (!rows.isEmpty()) {
          files.add(
              Json.object(
                  "name",
                  dimension + ".csv",
                  "text",
                  rowsCsv(rows, Json.object("timezone", timezone, "dimension", dimension))));
        }
      }
      List<Map<String, Object>> goals = store.goals(siteId);
      if (!goals.isEmpty()) {
        Map<String, Map<String, Object>> totals = store.goalTotalsAll(query, goals);
        List<List<Object>> lines = new ArrayList<>();
        for (Map<String, Object> g : goals) {
          Map<String, Object> t = totals.get(g.get("id"));
          lines.add(
              java.util.Arrays.asList(
                  g.get("name"),
                  t.get("conversions"),
                  t.get("visitors"),
                  t.get("revenue"),
                  g.get("currency")));
        }
        files.add(
            Json.object(
                "name",
                "goals.csv",
                "text",
                Zip.csv(List.of("goal", "conversions", "visitors", "revenue", "currency"), lines)));
      }
      return download(
          siteId + "-" + range.get("fromDate") + "-" + range.get("toDate") + ".zip",
          Zip.zip(files, rl.now()),
          "application/zip");
    }

    return coded("Not found", "not_found", 404);
  }

  /** A field of a remote's info, or undefined when there is none, which JSON leaves out. */
  private static Object field(Map<String, Object> info, String key) {
    return info != null && info.containsKey(key) ? info.get(key) : Json.UNDEFINED;
  }

  /**
   * Answers one request under the base path: the dashboard and its assets, the tracker, the API,
   * MCP, OAuth, accounts, and the small pages, as the TypeScript handler does.
   */
  public Response handle(Request request) {
    return handle(request, Map.of());
  }

  /** Answers one request, with the context the adapter knows: ip, the connection's address. */
  public Response handle(Request request, Map<String, Object> context) {
    Url url = new Url(request.url());
    // OAuth clients look for these at the site's root; an app routes them here when it wants
    // OAuth.
    if (!base.isEmpty() && isOauthDocument(url.pathname)) {
      try {
        Response answer = OAuth.oauthResponse(oauth, request, url.pathname, url, context);
        return answer != null ? answer : coded("Not found", "not_found", 404);
      } catch (RuntimeException error) {
        logError(error);
        return coded("Internal error", "internal", 500);
      }
    }
    if (!base.isEmpty() && !url.pathname.equals(base) && !url.pathname.startsWith(base + "/")) {
      return coded("Not found", "not_found", 404);
    }
    String path = url.pathname.substring(base.length());
    path = path.isEmpty() ? "/" : path;
    try {
      return route(request, path, url, context);
    } catch (RuntimeException error) {
      logError(error);
      return coded("Internal error", "internal", 500);
    }
  }

  private static void logError(Throwable error) {
    java.io.StringWriter trace = new java.io.StringWriter();
    error.printStackTrace(new java.io.PrintWriter(trace));
    Runlight.log("Runlight: " + trace);
  }

  private static Response asset(String name, String type, String cache) {
    return new Response(
        Version.assetBytes(name), 200, Headers.of("content-type", type, "cache-control", cache));
  }

  private Response route(Request request, String path, Url url, Map<String, Object> context) {
    Runlight rl = this.rl;
    String method = request.method();
    // Checked before any route, so a connected site's pass-through to its install is held to it
    // too.
    if (adminOnly(path, method) && owner(request) && members.containsKey(request)) {
      return coded("Only an owner or admin can change this", "admin_only", 403);
    }
    // Sign-in, setup, invites, and the Account and People APIs, and the dashboard sends anyone
    // signed out to sign in.
    if (web != null) {
      Response answered = web.handle(request, path, context);
      if (answered != null) {
        return answered;
      }
    }
    if (path.equals("/s.js") && method.equals("GET")) {
      Script script = trackerScript(url.searchParams().get("site"));
      Headers headers =
          Headers.of(
              "content-type",
              "application/javascript; charset=utf-8",
              // Short, so a new click goal reaches visitors within minutes; the etag makes rechecks
              // cheap.
              "cache-control",
              "public, max-age=300",
              "etag",
              script.etag());
      if (script.etag().equals(request.headers().get("if-none-match"))) {
        return new Response(new byte[0], 304, headers);
      }
      return new Response(script.body(), 200, headers);
    }

    if (path.equals("/pick.js") && method.equals("GET")) {
      // The picker sends what it picked only to the dashboard its ticket names; without a good
      // ticket it does nothing. It also runs only on the pages of the site the ticket names.
      String ticket = url.searchParams().get("runlight_ticket");
      Map<String, Object> target = pickTarget(ticket != null ? ticket : "");
      if (target != null) {
        rl.init();
      }
      Object hosts;
      if (target != null) {
        Map<String, Object> site = rl.site((String) target.get("site"));
        hosts = site != null ? site.get("hostnames") : null;
      } else {
        hosts = new ArrayList<>();
      }
      String script =
          replaceOnce(
              Version.asset("picker.js"),
              PICK_TARGET_PLACEHOLDER,
              Json.stringify(hosts != null && target != null ? target.get("origin") : ""));
      script =
          replaceOnce(
              script,
              PICK_HOSTS_PLACEHOLDER,
              Json.stringify(Json.stringify(hosts != null ? hosts : new ArrayList<>())));
      return new Response(
          script,
          200,
          Headers.of(
              "content-type",
              "application/javascript; charset=utf-8",
              "cache-control",
              "no-store"));
    }

    if (path.equals("/assets/world." + hash("worldHash") + ".json") && method.equals("GET")) {
      return asset(
          "world.json", "application/json; charset=utf-8", "public, max-age=31536000, immutable");
    }

    Matcher locale = LOCALE.matcher(path);
    if (locale.find()
        && locale.group(2).equals(hash("localesHash"))
        && Js.truthy(locales().get(locale.group(1)))
        && method.equals("GET")) {
      return new Response(
          (String) locales().get(locale.group(1)),
          200,
          Headers.of(
              "content-type",
              "application/json; charset=utf-8",
              "cache-control",
              "public, max-age=31536000, immutable"));
    }

    if (path.startsWith("/assets/app.") && method.equals("GET")) {
      String hash = hash("dashboardHash");
      String name =
          path.equals("/assets/app." + hash + ".js")
              ? "dashboard.js"
              : path.equals("/assets/app." + hash + ".css") ? "dashboard.css" : null;
      if (name == null) {
        return coded("Not found", "not_found", 404);
      }
      return asset(
          name,
          path.endsWith(".js")
              ? "application/javascript; charset=utf-8"
              : "text/css; charset=utf-8",
          "public, max-age=31536000, immutable");
    }

    if (path.equals("/e")) {
      if (method.equals("OPTIONS")) {
        return new Response(
            new byte[0],
            204,
            Headers.of(
                "access-control-allow-origin",
                "*",
                "access-control-allow-methods",
                "POST",
                "access-control-max-age",
                "86400"));
      }
      if (!method.equals("POST")) {
        return coded("Method not allowed", "method_not_allowed", 405);
      }
      try {
        rl.collect(request, context);
      } catch (RuntimeException error) {
        Runlight.log("Runlight: could not record an event " + error);
      }
      // The same answer whatever happened, so the endpoint reveals nothing.
      return new Response(new byte[0], 202, Headers.of("access-control-allow-origin", "*"));
    }

    if (path.equals("/api") || path.startsWith("/api/")) {
      return api(request, path, url);
    }

    if (path.startsWith("/oauth/") || isOauthDocument(path)) {
      Response answer = OAuth.oauthResponse(oauth, request, path, url, context);
      if (answer != null) {
        return answer;
      }
    }

    if (path.equals("/mcp")) {
      // No server-sent stream and no sessions: every message is one POST.
      if (!method.equals("POST")) {
        return coded(
            "Method not allowed", "method_not_allowed", 405, null, Map.of("allow", "POST"));
      }
      Object access = reader(request);
      if (refusedReader(access)) {
        Response refused = denied(access);
        // Points an OAuth client at the metadata that starts the sign-in.
        refused
            .headers()
            .set(
                "www-authenticate",
                "Bearer realm=\"runlight\", resource_metadata=\""
                    + OAuth.resourceMetadataUrl(url.origin(), base)
                    + "\"");
        return refused;
      }
      // Each tool reads the HTTP API with the caller's own headers, so it sees what they may.
      return Mcp.mcpResponse(request, readApi(request, url, null));
    }

    Matcher unsubscribe = UNSUBSCRIBE.matcher(path);
    if (unsubscribe.find() && (method.equals("GET") || method.equals("POST"))) {
      return unsubscribePage(request, unsubscribe.group(1));
    }

    Matcher sharePage = SHARE_PAGE.matcher(path);
    if (sharePage.find() && method.equals("GET")) {
      rl.init();
      String id = sharePage.group(1);
      Map<String, Object> share = SHARE_ID.matcher(id).find() ? store().shareById(id) : null;
      if (share == null) {
        Messages.Translator t = Messages.translator(acceptedLanguage(request));
        return smallPage(
            t.lang(),
            "<h1>"
                + escapeHtml(t.t("share.goneTitle"))
                + "</h1><p>"
                + escapeHtml(t.t("share.gone"))
                + "</p>",
            404);
      }
      return new Response(
          dashboard(base, (String) share.get("id"), "", options.geoCredit, false, ""),
          200,
          Headers.of(
              "content-type",
              "text/html; charset=utf-8",
              "cache-control",
              "no-store",
              "content-security-policy",
              DASHBOARD_CSP,
              "x-frame-options",
              "DENY",
              // The share id is the key; never send it on to another site.
              "referrer-policy",
              "no-referrer",
              "x-robots-tag",
              "noindex"));
    }

    if ((path.equals("/") || path.isEmpty()) && method.equals("GET")) {
      String given = url.searchParams().get("token");
      if (given != null
          && !given.isEmpty()
          && token != null
          && !token.isEmpty()
          && constantTimeEqual(given, token)) {
        Url clean = url.copy();
        SearchParams query = clean.searchParams();
        query.delete("token");
        clean.setSearchParams(query);
        String secure = clean.protocol.equals("https:") ? "; Secure" : "";
        return new Response(
            new byte[0],
            303,
            Headers.of(
                "location",
                clean.pathname + clean.search,
                "set-cookie",
                COOKIE
                    + "="
                    + cookieValue(token)
                    + "; Path="
                    + (!base.isEmpty() ? base : "/")
                    + "; HttpOnly; SameSite=Lax; Max-Age=2592000"
                    + secure));
      }
      // The page itself holds no data; the API it calls checks access and the page explains how to
      // sign in when it is refused.
      return new Response(
          dashboard(
              base,
              "",
              signOut != null ? signOut : "",
              options.geoCredit,
              web != null,
              signIn != null ? signIn : ""),
          200,
          Headers.of(
              "content-type",
              "text/html; charset=utf-8",
              "cache-control",
              "no-store",
              "content-security-policy",
              DASHBOARD_CSP,
              "x-frame-options",
              "DENY",
              "referrer-policy",
              "same-origin"));
    }

    return coded("Not found", "not_found", 404);
  }

  /**
   * text.replace(search, () => value): the first match only, nothing in value read as a pattern.
   */
  private static String replaceOnce(String text, String search, String value) {
    int at = text.indexOf(search);
    return at < 0 ? text : text.substring(0, at) + value + text.substring(at + search.length());
  }
}
