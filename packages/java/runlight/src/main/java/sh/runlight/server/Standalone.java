package sh.runlight.server;

import com.sun.net.httpserver.HttpHandler;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.function.LongSupplier;
import java.util.function.Supplier;
import java.util.regex.Pattern;
import sh.runlight.Geo;
import sh.runlight.Hash;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.Routes;
import sh.runlight.Runlight;
import sh.runlight.accounts.Accounts;
import sh.runlight.accounts.Crypto;
import sh.runlight.accounts.Web;
import sh.runlight.http.Fetcher;
import sh.runlight.http.Headers;
import sh.runlight.http.Request;
import sh.runlight.http.Response;
import sh.runlight.http.Url;
import sh.runlight.store.SqlStore;

/**
 * The standalone server: Runlight's routes at the root of their own domain, behind a sign-in, with
 * sites managed in the dashboard and short links answered on any domain pointed at it. This is the
 * port of packages/server/src/server.ts, by way of PHP's Server/Standalone.php; {@link Config}
 * builds one from the environment or a runlight.properties, and {@code runlight serve} serves it on
 * the JDK's HTTP server through {@link #handler()}.
 *
 * <p>The names the owner and admins signed in from are kept in the database and read once, as the
 * Node server keeps them, and the scheduled check runs every five minutes in the server ({@code
 * runlight cron} runs it from a crontab instead).
 */
public final class Standalone {
  /**
   * The server's own pages, which answer as the server on every name it is reached at, a link
   * domain too.
   */
  public static final Set<String> SERVER_PATHS =
      Set.of(
          "/login",
          "/logout",
          "/setup",
          "/invite",
          "/healthz",
          "/auth.css",
          "/auth.js",
          "/api",
          "/mcp",
          "/s.js",
          "/pick.js",
          "/e",
          "/embed");

  /**
   * The most names remembered as the server's own. The first ones stay and later ones are not
   * learned, so a server reached at more names than this needs RUNLIGHT_URL to keep the rest from
   * becoming link domains.
   */
  public static final int MAX_OWN_HOSTS = 20;

  private static final Pattern ONE_SEGMENT = Pattern.compile("^/[^/]*\\z");
  private static final Pattern GO = Pattern.compile("^/go/[^/]+/?\\z");

  /**
   * What the server takes, with the TypeScript names.
   *
   * <ul>
   *   <li>store: the SqlStore (required).
   *   <li>secret: signs sessions and encrypts saved keys (required). Keep it stable.
   *   <li>token: also accepted as a bearer token on the API, for scripts. When there is no
   *       setupCode, the first account is made with it instead.
   *   <li>url: the dashboard's public address, such as https://stats.example.com. It can never
   *       become a link domain, short links never answer on it, and emails link to it whatever Host
   *       header a request carries.
   *   <li>trustProxy: true (the default), false, or the one header the proxy sets.
   *   <li>geo, geoCredit: where locations come from, and whether to credit DB-IP for them.
   *   <li>setupCode: the one-time code that unlocks /setup while no account exists; setupWhere says
   *       where it is written down, for the page that asks for it.
   *   <li>cronSecret: a bearer secret for POST /api/check, for a scheduler that calls it over HTTP.
   *   <li>observeKey: one key for every site's AI agent reports.
   *   <li>now, fetcher: the clock and outgoing requests, for tests.
   * </ul>
   */
  public static final class Options {
    public SqlStore store;
    public String secret;
    public String token;
    public String url;
    public Object trustProxy;
    public Geo.Lookup geo;
    public boolean geoCredit;
    public LongSupplier now;
    public Fetcher fetcher;
    public String setupCode;
    public String setupWhere;
    public String cronSecret;
    public String observeKey;

    public Options store(SqlStore value) {
      store = value;
      return this;
    }

    public Options secret(String value) {
      secret = value;
      return this;
    }

    public Options token(String value) {
      token = value;
      return this;
    }

    public Options url(String value) {
      url = value;
      return this;
    }

    public Options trustProxy(Object value) {
      trustProxy = value;
      return this;
    }

    public Options geo(Geo.Lookup value) {
      geo = value;
      return this;
    }

    public Options geoCredit(boolean value) {
      geoCredit = value;
      return this;
    }

    public Options now(LongSupplier value) {
      now = value;
      return this;
    }

    public Options fetcher(Fetcher value) {
      fetcher = value;
      return this;
    }

    public Options setupCode(String value) {
      setupCode = value;
      return this;
    }

    public Options setupWhere(String value) {
      setupWhere = value;
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
  }

  public final Runlight runlight;
  public final Accounts accounts;
  public final Web web;
  public final Routes routes;
  private final SqlStore store;
  private final String token;
  private final Object trustProxy;
  private final Url publicUrl;
  private final String publicHost;
  private List<String> ownHosts;

  public Standalone(Options options) {
    this.store = options.store;
    LongSupplier now = options.now != null ? options.now : System::currentTimeMillis;
    this.token = options.token != null && !options.token.isEmpty() ? options.token : null;
    this.trustProxy = options.trustProxy != null ? options.trustProxy : true;
    this.publicUrl = options.url != null && !options.url.isEmpty() ? new Url(options.url) : null;
    this.publicHost = publicUrl != null ? Routes.hostName(publicUrl.host()) : null;

    Runlight.Options settings =
        new Runlight.Options().store(store).managedSites(true).secret(options.secret).now(now);
    // Unset stays unset, so the library's default applies and it can warn when nothing sits in
    // front.
    if (options.trustProxy != null) {
      settings.trustProxy(options.trustProxy);
    }
    if (options.geo != null) {
      settings.geo(options.geo);
    }
    if (options.fetcher != null) {
      settings.fetcher(options.fetcher);
    }
    Runlight rl = new Runlight(settings);
    this.runlight = rl;

    // Accounts, shared with apps that turn them on. The first one is made with the one-time code,
    // or with the token when there is no code, and emails link to the public address, or else the
    // first name the owner or an admin signed in from.
    String code = options.setupCode;
    Map<String, Object> web = new LinkedHashMap<>();
    web.put("runlight", rl);
    web.put("secret", options.secret);
    web.put("base", "");
    web.put("now", now);
    web.put(
        "firstAccount",
        code != null && !code.isEmpty()
            ? Json.object("code", code)
            : token != null ? Json.object("token", token) : "locked");
    web.put(
        "home",
        (Supplier<String>)
            () -> {
              if (publicUrl != null) {
                return publicUrl.origin();
              }
              List<String> known = knownHosts();
              return known.isEmpty() ? null : "https://" + known.get(0);
            });
    web.put("forgot", "https://runlight.sh/docs/java/#forgotten-passwords");
    if (options.setupWhere != null) {
      web.put("setupWhere", options.setupWhere);
    }
    this.web = new Web(web);
    this.accounts = this.web.accounts();

    Routes.Options routes =
        new Routes.Options()
            .basePath("")
            // Without a secret of its own, the cron route is never needed: the server runs the
            // check itself.
            .cronSecret(
                options.cronSecret != null && !options.cronSecret.isEmpty()
                    ? options.cronSecret
                    : Hash.randomId(32))
            .observeKey(options.observeKey != null ? options.observeKey : "")
            .signOut("/logout")
            .signIn("/login")
            .geoCredit(options.geoCredit)
            .accounts(this.web)
            .authorize(this::authorize)
            .ownHosts(this::knownHosts);
    if (publicUrl != null) {
      routes.origin(publicUrl.origin());
    }
    this.routes = rl.routes(routes);
  }

  private Object authorize(Request request) {
    String auth = request.headers().get("authorization");
    auth = auth == null ? "" : auth;
    if (token != null
        && Js.lower(auth).startsWith("bearer ")
        && Crypto.sameText(Js.trim(auth.substring(7)), token)) {
      return true;
    }
    Object access = web.access(request);
    if (Boolean.TRUE.equals(access)) {
      learnHost(request);
    }
    return access;
  }

  /** The name a request came in on, read as link domains read it. */
  private String hostOf(Request request) {
    String forwarded =
        !Boolean.FALSE.equals(trustProxy) ? request.headers().get("x-forwarded-host") : null;
    String given = forwarded != null ? forwarded : request.headers().get("host");
    return Routes.hostName(given != null ? given : new Url(request.url()).host());
  }

  private List<String> savedHosts() {
    runlight.init();
    String saved = store.setting("server-hosts");
    Json.Parsed parsed = Json.tryParse(saved == null ? "[]" : saved);
    List<String> out = new ArrayList<>();
    if (parsed.ok() && parsed.value() instanceof List<?> list) {
      for (Object host : list) {
        if (host instanceof String s) {
          out.add(s);
        }
      }
    }
    return out;
  }

  /**
   * The names the owner and admins signed in from, kept in the database, so a link domain can never
   * be one of them even when whoever adds it picks another Host header.
   */
  private synchronized List<String> knownHosts() {
    if (ownHosts == null) {
      ownHosts = List.copyOf(savedHosts());
    }
    return ownHosts;
  }

  /**
   * Only the owner and admins teach the server its names, since anyone else could fill the list
   * with made-up ones, and only real domain names. Names that are already link domains are left
   * out.
   */
  private synchronized void learnHost(Request request) {
    String host = hostOf(request);
    List<String> known = new ArrayList<>(knownHosts());
    if (!Routes.DOMAIN_NAME.matcher(host).find()
        || known.contains(host)
        || known.size() >= MAX_OWN_HOSTS) {
      return;
    }
    for (Map<String, Object> domain : store.linkDomains()) {
      if (host.equals(domain.get("domain"))) {
        return;
      }
    }
    // Another copy of the server may have saved names since this one read them.
    for (String saved : savedHosts()) {
      if (!known.contains(saved)) {
        known.add(saved);
      }
    }
    known.add(host);
    ownHosts = List.copyOf(known.subList(0, Math.min(known.size(), MAX_OWN_HOSTS)));
    store.setSetting("server-hosts", Json.stringify(new ArrayList<Object>(ownHosts)));
  }

  /** The answer to one request, from the connection's address the request carries. */
  public Response handle(Request request) {
    return handle(request, Json.object("ip", request.remoteAddress()));
  }

  /**
   * The answer to one request, with the context the adapter knows: ip, the connection's address.
   */
  public Response handle(Request request, Map<String, Object> context) {
    String path = new Url(request.url()).pathname;
    try {
      // A domain pointed at this server for short links answers at its root, with links one
      // segment deep. The server's own pages and its public address never answer as links, and "/"
      // stays the dashboard for someone signed in, so a link domain added on the dashboard's own
      // name can always be removed again.
      boolean linkable =
          path.equals(Runlight.LINK_DOMAIN_CHECK)
              || (ONE_SEGMENT.matcher(path).find()
                  && !SERVER_PATHS.contains(path)
                  && !(path.equals("/") && web.signedIn(request) != null));
      if (linkable && !(publicHost != null && hostOf(request).equals(publicHost))) {
        Response linked = runlight.linkDomainResponse(request, context);
        if (linked != null) {
          return linked;
        }
      }
      if (path.equals("/healthz")) {
        return new Response(
            "ok", 200, Headers.of("content-type", "text/plain", "cache-control", "no-store"));
      }
      if (request.method().equals("GET") && GO.matcher(path).find()) {
        return runlight.linkHandler().apply(request);
      }
      // Everything else, the sign-in pages and People included, is the routes'.
      return routes.handle(request, context);
    } catch (RuntimeException error) {
      System.err.println("Runlight: " + error);
      return Routes.coded("Internal error", "internal", 500);
    }
  }

  /**
   * The server as an {@link HttpHandler} for the JDK's HTTP server, mounted at "/": each request
   * answered by {@link #handle(Request, Map)}, then the work left after answering (a retention
   * change's deletions) once the visitor has the answer.
   */
  public HttpHandler handler() {
    return JdkServer.handler(this::handle, runlight::idle);
  }

  /** The scheduled work: salts, email reports that are due, retention, and rollups. */
  public Map<String, Object> check() {
    Map<String, Object> result = runlight.check();
    runlight.idle();
    return result;
  }
}
