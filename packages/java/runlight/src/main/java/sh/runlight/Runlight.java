package sh.runlight;

import java.text.Collator;
import java.time.LocalDate;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.locks.ReentrantLock;
import java.util.function.Function;
import java.util.function.LongSupplier;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import sh.runlight.CodedError.SettingsError;
import sh.runlight.http.BodyTooLong;
import sh.runlight.http.Fetcher;
import sh.runlight.http.Headers;
import sh.runlight.http.JdkFetcher;
import sh.runlight.http.Request;
import sh.runlight.http.Response;
import sh.runlight.http.Url;
import sh.runlight.mail.MailError;
import sh.runlight.mail.Secret;
import sh.runlight.mail.Transports;
import sh.runlight.store.SqlStore;

/**
 * Runlight in an app: the sites it counts, the tracker endpoint's work, short links, email reports,
 * and the scheduled upkeep. A port of the TypeScript SDK's runlight.ts.
 *
 * <p>A site is a map of id, name, hostnames, and timezone, as the SDK's SiteRow. TS runs some work
 * after answering or on timers. Here the retention a settings change asks for runs in {@link
 * #idle()}, which an adapter calls once the answer is sent, and everything else in {@link
 * #check()}.
 *
 * <p>One Runlight serves many threads at once: the tracker, links, and the dashboard may all call
 * it together.
 */
public final class Runlight
    implements sh.runlight.accounts.Web.Host, OAuth.Install, sh.runlight.importers.Host {
  /** A path on every link domain that answers when the domain reaches this Runlight. */
  public static final String LINK_DOMAIN_CHECK = "/.well-known/runlight-link-domain";

  /** The choices for how long a site keeps its visits. */
  public static final List<Long> RETENTION_MONTHS = List.of(6L, 12L, 24L, 36L, 60L);

  /** Thirty minutes without a request ends a session. */
  public static final long SESSION_IDLE_MS = 30 * 60 * 1000L;

  /**
   * What passes for an email address: something@somewhere.tld, with no spaces, quotes, or angle
   * brackets.
   */
  public static final Pattern EMAIL =
      Pattern.compile(
          "^[^" + Js.SPACE + "@<>\"]+@[^" + Js.SPACE + "@<>\"]+\\.[^" + Js.SPACE + "@<>\"]+\\z");

  /**
   * Raised whenever what a rolled-up day holds changes. 2: the heatmap counts visits only. 3: a
   * page counts the views that can report time.
   */
  private static final int ROLLUP_VERSION = 3;

  /** Days of rollups built per site in one scheduled check, and how long after a day ends. */
  private static final int ROLLUP_BATCH = 10;

  /** The most a connected install's list of sites may weigh; a real one is a few kilobytes. */
  private static final long REMOTE_MAX_BYTES = 2 * 1024 * 1024;

  /**
   * On a database that caps statements per request (Cloudflare D1), fewer days a check, about 30
   * statements.
   */
  private static final int METERED_ROLLUP_BATCH = 4;

  private static final long ROLLUP_DELAY_MS = 2 * 3_600_000L;

  private static final Pattern SITE_ID =
      Pattern.compile("^[a-z0-9][a-z0-9._-]{0,63}\\z", Pattern.CASE_INSENSITIVE);
  private static final Pattern DOMAIN =
      Pattern.compile(
          "^(?=" + Js.DOT + "{1,253}\\z)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}\\z");
  private static final Pattern PAGE_EXTENSION =
      Pattern.compile("\\.([a-z0-9]+)\\z", Pattern.CASE_INSENSITIVE);
  private static final Pattern BUSY =
      Pattern.compile(
          "timeout exceeded when trying to connect|connection timeout|no MySQL connection was free|SQLITE_BUSY|database is locked",
          Pattern.CASE_INSENSITIVE);

  /**
   * How a Runlight is set up, with the TypeScript option names.
   *
   * <ul>
   *   <li>store: the SqlStore (required), such as {@code Stores.sqlite("./data/runlight.db")}.
   *   <li>site: the site this install counts, a map of id, name, hostnames, and timezone. Ignored
   *       when sites is given. id is a stable id stored with every row, default "default".
   *       hostnames are the hostnames that belong to the site, without www; with one site, empty
   *       means any hostname, and with several, each site needs at least one. timezone is an IANA
   *       timezone for reports, such as "Europe/London", default "UTC".
   *   <li>sites: several sites in one install, told apart by hostname.
   *   <li>managedSites: sites are added, changed, and deleted in the dashboard and kept in the
   *       database, as the standalone server does. site and sites are ignored.
   *   <li>geo: a location for an IP when the platform sends no location headers.
   *   <li>trustProxy: true (default), false, or one of "x-forwarded-for", "x-real-ip",
   *       "cf-connecting-ip". Read the client IP from forwarding headers: the last X-Forwarded-For
   *       entry, which the nearest proxy wrote, then X-Real-IP, then CF-Connecting-IP. Name one of
   *       them to read only that header. False reads only the connection's address.
   *   <li>linkPath: where short links on the app's own domain live, as {linkPath}/{slug}. Default
   *       "/go".
   *   <li>mail: the mail service for email reports, in code (a Transports config plus from and
   *       fromName). When set, the dashboard shows it and cannot change it.
   *   <li>secret: encrypts the keys kept in the database. Default the RUNLIGHT_SECRET environment
   *       variable, then RUNLIGHT_TOKEN.
   *   <li>rateLimit: tracker requests allowed per visitor address per minute. Default 120; false or
   *       0 turns the limit off.
   *   <li>localInstalls: lets a connected install be at http://localhost or http://127.0.0.1, for
   *       trying a hub and an app on one machine. Default false: otherwise anyone who can add a
   *       site could have this server ask services on its own machine, so other installs must be
   *       public https addresses.
   *   <li>now: the clock in milliseconds. For tests.
   *   <li>fetcher: the Fetcher every outgoing request goes through. Default {@link JdkFetcher}.
   * </ul>
   */
  public static final class Options {
    public SqlStore store;
    public Map<String, Object> site;
    public List<Map<String, Object>> sites;
    public boolean managedSites;
    public Geo.Lookup geo;
    public Object trustProxy = true;
    public Object rateLimit = 120L;
    public boolean localInstalls;
    public String linkPath = "/go";
    public Map<String, Object> mail;
    public String secret;
    public LongSupplier now;
    public Fetcher fetcher;

    public Options store(SqlStore value) {
      store = value;
      return this;
    }

    public Options site(Map<String, Object> value) {
      site = value;
      return this;
    }

    public Options sites(List<Map<String, Object>> value) {
      sites = value;
      return this;
    }

    public Options managedSites(boolean value) {
      managedSites = value;
      return this;
    }

    public Options geo(Geo.Lookup value) {
      geo = value;
      return this;
    }

    /** True, false, or the name of the one header to read. */
    public Options trustProxy(Object value) {
      trustProxy = value;
      return this;
    }

    /** Requests per minute per address, or false for no limit. */
    public Options rateLimit(Object value) {
      rateLimit = value;
      return this;
    }

    public Options localInstalls(boolean value) {
      localInstalls = value;
      return this;
    }

    public Options linkPath(String value) {
      linkPath = value;
      return this;
    }

    public Options mail(Map<String, Object> value) {
      mail = value;
      return this;
    }

    public Options secret(String value) {
      secret = value;
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
  }

  public final SqlStore store;

  /** Whether sites are managed in the dashboard. */
  public final boolean managedSites;

  /** Short links: create, change, delete, and import. */
  public final Links links;

  /** Where links on the app's own domain are served, such as "/go". */
  public final String linkPath;

  /**
   * Encrypts the keys kept in the database; null leaves them readable, and the dashboard says so.
   */
  public final String secret;

  /**
   * Whether a connected install may be on this machine, at http://localhost or http://127.0.0.1.
   */
  public final boolean localInstalls;

  /** Every outgoing request goes through it. */
  public final Fetcher fetcher;

  /**
   * Where routes() serves the dashboard and API, which a link domain leaves alone, without repeats.
   * Middleware often runs apart from the routes, where none were made, so the default "/runlight"
   * stands in there.
   */
  public final List<String> routeBases = new CopyOnWriteArrayList<>();

  /** The sites as configured in code, or as kept in the database when they are managed. */
  private volatile List<Map<String, Object>> configured;

  /** Sites counted by another Runlight install, read through its API with the token it gave. */
  private volatile Map<String, Map<String, Object>> remotes = Map.of();

  private final Map<String, Map<String, Object>> remoteSeen = new ConcurrentHashMap<>();
  private volatile Map<String, Map<String, Object>> overrides = Map.of();
  private final Geo.Lookup geo;
  private final Object trustProxy;
  private final RateLimit limit;
  private final LongSupplier clock;
  private volatile boolean ready;
  private final ReentrantLock checking = new ReentrantLock();

  /** When planner statistics were last gathered. */
  private long optimizedAt;

  private record LinkDomains(long at, Set<String> domains) {}

  private volatile LinkDomains linkDomainCache;

  private record Salts(String day, String today, String yesterday) {}

  /** Each timezone's salts for its current day, so a lookup is a map read until midnight there. */
  private final Map<String, Salts> salts = new ConcurrentHashMap<>();

  private final Map<String, Object> mailInCode;

  /** Retention work asked for and not yet done: a site's id, or "" for every site. */
  private final ConcurrentLinkedQueue<String> pruning = new ConcurrentLinkedQueue<>();

  /** Work to do once the answer is sent, such as an email whose timing must not show in it. */
  private final ConcurrentLinkedQueue<Runnable> later = new ConcurrentLinkedQueue<>();

  /**
   * Locks taken per visitor, so one visitor's pageview and the event right after find one session.
   */
  private final Object[] turns = new Object[64];

  public Runlight(Options options) {
    if (options == null || options.store == null) {
      throw new IllegalArgumentException(
          "Runlight: pass a store, such as Stores.sqlite(\"./data/runlight.db\")");
    }
    this.store = options.store;
    this.managedSites = options.managedSites;
    List<Map<String, Object>> given =
        managedSites
            ? List.of()
            : options.sites != null && !options.sites.isEmpty()
                ? options.sites
                : Collections.singletonList(options.site == null ? Map.of() : options.site);
    List<Map<String, Object>> rows = new ArrayList<>();
    for (int i = 0; i < given.size(); i++) {
      rows.add(siteRow(given.get(i), i));
    }
    if (rows.size() > 1) {
      for (Map<String, Object> site : rows) {
        if (hostnames(site).isEmpty()) {
          throw new IllegalArgumentException(
              "Runlight: with several sites, give each one its hostnames");
        }
      }
    }
    Set<Object> ids = new LinkedHashSet<>();
    for (Map<String, Object> site : rows) {
      ids.add(site.get("id"));
    }
    if (ids.size() != rows.size()) {
      throw new IllegalArgumentException("Runlight: two sites share an id");
    }
    this.configured = List.copyOf(rows);
    this.geo = options.geo;
    this.trustProxy = options.trustProxy == null ? (Object) true : options.trustProxy;
    Object perMinute = options.rateLimit == null ? (Object) 120L : options.rateLimit;
    // false, 0, or anything that is not a positive number means no limit, never a limit of nothing.
    double number = Boolean.FALSE.equals(perMinute) ? Double.NaN : Js.toNumber(perMinute);
    this.clock = options.now != null ? options.now : System::currentTimeMillis;
    this.limit =
        !(number > 0)
            ? null
            : new RateLimit((long) Math.min(Long.MAX_VALUE, Math.floor(number)), this::now);
    this.fetcher = options.fetcher != null ? options.fetcher : new JdkFetcher();
    this.links = new Links(store, this::init, this::now);
    this.linkPath =
        "/" + (options.linkPath == null ? "/go" : options.linkPath).replaceAll("^/+|/+\\z", "");
    this.mailInCode = options.mail;
    String secretFromEnv = Env.get("RUNLIGHT_SECRET");
    this.localInstalls = options.localInstalls;
    this.secret =
        options.secret != null
            ? options.secret
            : secretFromEnv != null ? secretFromEnv : Env.get("RUNLIGHT_TOKEN");
    for (int i = 0; i < turns.length; i++) {
      turns[i] = new Object();
    }
  }

  private static Map<String, Object> siteRow(Map<String, Object> options, int index) {
    Object tz = options.get("timezone");
    String timezone = tz == null ? "UTC" : Js.string(tz);
    if (!Time.isTimezone(timezone)) {
      throw new IllegalArgumentException("Runlight: unknown timezone \"" + timezone + "\"");
    }
    Object given = options.get("id");
    String id = given != null ? Js.string(given) : index == 0 ? "default" : "";
    if (id.isEmpty() || !SITE_ID.matcher(id).matches()) {
      throw new IllegalArgumentException(
          "Runlight: site id \"" + id + "\" must be letters, digits, dots, dashes, or underscores");
    }
    List<Object> listed = Js.list(options.get("hostnames"));
    List<Object> hostnames = new ArrayList<>();
    if (listed != null) {
      for (Object h : listed) {
        hostnames.add(Sources.stripWww(Js.string(h)));
      }
    }
    Object name = options.get("name");
    return Json.object(
        "id",
        id,
        "name",
        name != null
            ? Js.string(name)
            : listed != null && !listed.isEmpty() ? Js.string(listed.get(0)) : "My site",
        "hostnames",
        hostnames,
        "timezone",
        timezone);
  }

  @SuppressWarnings("unchecked")
  private static List<String> hostnames(Map<String, Object> site) {
    Object list = site.get("hostnames");
    return list instanceof List<?> l ? (List<String>) l : List.of();
  }

  private static String id(Map<String, Object> site) {
    return (String) site.get("id");
  }

  private static String timezone(Map<String, Object> site) {
    return (String) site.get("timezone");
  }

  private static String name(Map<String, Object> site) {
    return (String) site.get("name");
  }

  @Override
  public SqlStore store() {
    return store;
  }

  @Override
  public Fetcher fetcher() {
    return fetcher;
  }

  /** The clock, in milliseconds. */
  @Override
  public long now() {
    return clock.getAsLong();
  }

  /** The mail service: from code, or as saved in the dashboard. Null when there is none. */
  @Override
  public Map<String, Object> mailSettings() {
    if (mailInCode != null) {
      Map<String, Object> out = new LinkedHashMap<>(mailInCode);
      out.put("source", "code");
      return out;
    }
    init();
    String sealed = store.setting("mail");
    if (sealed == null || sealed.isEmpty()) {
      return null;
    }
    String opened = Secret.unseal(sealed, secret);
    if (opened == null || opened.isEmpty()) {
      return null;
    }
    Map<String, Object> out = new LinkedHashMap<>(Js.map(Json.parse(opened)));
    out.put("source", "dashboard");
    return out;
  }

  /**
   * Saves the mail service from the dashboard. A secret field left blank keeps the saved value, so
   * the browser never needs to see it.
   */
  public void saveMailSettings(Map<String, Object> input) {
    if (mailInCode != null) {
      throw new MailError("The mail service is set in code", "mail_in_code", Map.of());
    }
    if (input == null) {
      store.setSetting("mail", null);
      return;
    }
    Map<String, Object> before = mailSettings();
    Map<String, Object> service = null;
    for (Map<String, Object> s : Transports.SERVICES) {
      if (s.get("id").equals(input.get("service"))) {
        service = s;
        break;
      }
    }
    if (service == null) {
      throw new MailError("Pick a mail service", "mail_service", Map.of());
    }
    List<Map<String, Object>> fields = maps(service.get("fields"));
    Map<String, Object> settings = new LinkedHashMap<>();
    settings.put("service", service.get("id"));
    for (Map<String, Object> f : fields) {
      if (!Js.truthy(f.get("secret"))) {
        String field = (String) f.get("name");
        settings.put(field, Js.trim(Js.string(orEmpty(input.get(field)))));
      }
    }
    // A blank secret keeps the saved one only while the connection is the same,
    // so changing the host cannot send a saved password somewhere new.
    boolean sameConnection = before != null && service.get("id").equals(before.get("service"));
    if (sameConnection) {
      for (Map<String, Object> f : fields) {
        String field = (String) f.get("name");
        if (!Js.truthy(f.get("secret"))
            && !Js.string(orEmpty(before.get(field))).equals(settings.get(field))) {
          sameConnection = false;
          break;
        }
      }
    }
    for (Map<String, Object> f : fields) {
      if (!Js.truthy(f.get("secret"))) {
        continue;
      }
      String field = (String) f.get("name");
      String given = Js.trim(Js.string(orEmpty(input.get(field))));
      settings.put(
          field, given.isEmpty() && sameConnection ? Js.string(orEmpty(before.get(field))) : given);
    }
    String from = Js.trim(Js.string(orEmpty(input.get("from"))));
    if (!EMAIL.matcher(from).find()) {
      throw new MailError(
          "Enter the address reports come from, like reports@example.com", "mail_from", Map.of());
    }
    String fromName = Js.slice(Js.trim(Js.string(orEmpty(input.get("fromName")))), 0, 80);
    Map<String, Object> config = new LinkedHashMap<>(settings);
    config.put("from", from);
    if (!fromName.isEmpty()) {
      config.put("fromName", fromName);
    }
    Transports.checkConfig(config);
    store.setSetting("mail", Secret.seal(Json.stringify(config), secret));
  }

  private static Object orEmpty(Object value) {
    return value == null || value == Json.UNDEFINED ? "" : value;
  }

  @SuppressWarnings("unchecked")
  private static List<Map<String, Object>> maps(Object value) {
    return value instanceof List<?> l ? (List<Map<String, Object>>) l : List.of();
  }

  /**
   * Sends one email through the mail service: to, subject, html, text, and optional headers.
   *
   * @throws MailError when there is no mail service or it refused the message
   */
  @Override
  public void sendMail(Map<String, Object> message) {
    Map<String, Object> settings = mailSettings();
    if (settings == null) {
      throw new MailError("Set up a mail service first", "mail_unset", Map.of());
    }
    Map<String, Object> full = new LinkedHashMap<>(message);
    full.put("from", settings.get("from"));
    if (settings.get("fromName") != null) {
      full.put("fromName", settings.get("fromName"));
    }
    Transports.send(settings, full, fetcher, now());
  }

  /**
   * Sends every report that is due: last week's on Monday from 8am, last month's on the 1st, in
   * each site's timezone. Safe to run often; each period goes out once. Called by check().
   *
   * @return sent and failed counts
   */
  public Map<String, Object> sendReports() {
    init();
    long sent = 0;
    long failed = 0;
    List<Map<String, Object>> reports = store.reports(null);
    if (reports.isEmpty() || mailSettings() == null) {
      return Json.object("sent", sent, "failed", failed);
    }
    long now = now();
    for (Map<String, Object> r : reports) {
      Map<String, Object> site = site((String) r.get("site"));
      if (site == null) {
        continue;
      }
      Map<String, Object> period =
          Reports.lastPeriod((String) r.get("frequency"), now, timezone(site));
      if (now < Js.asLong(period.get("dueAt")) || period.get("key").equals(r.get("lastPeriod"))) {
        continue;
      }
      if (!store.claimReport((String) r.get("id"), (String) period.get("key"), now)) {
        continue;
      }
      try {
        deliverReport(r, site, period);
        sent++;
      } catch (RuntimeException error) {
        store.releaseReport(
            (String) r.get("id"), (String) period.get("key"), (String) r.get("lastPeriod"));
        log(
            "Runlight: could not send the "
                + r.get("frequency")
                + " report for "
                + name(site)
                + " to "
                + r.get("email")
                + ": "
                + error.getMessage());
        failed++;
      }
    }
    return Json.object("sent", sent, "failed", failed);
  }

  /** Builds and sends one report. Also used by "Send a sample now". */
  public void deliverReport(Map<String, Object> r, Map<String, Object> site) {
    deliverReport(r, site, null);
  }

  /** Builds and sends one report for a period, the last one when it is null. */
  public void deliverReport(
      Map<String, Object> r, Map<String, Object> site, Map<String, Object> period) {
    Map<String, Object> p =
        period != null
            ? period
            : Reports.lastPeriod((String) r.get("frequency"), now(), timezone(site));
    String unsubscribe = r.get("origin") + "/unsubscribe/" + r.get("token");
    Map<String, Object> report =
        Reports.buildReport(
            store,
            site,
            (String) r.get("frequency"),
            p,
            (String) r.get("lang"),
            Json.object(
                "dashboard",
                r.get("origin") + "/?site=" + Js.encodeURIComponent(id(site)),
                "unsubscribe",
                unsubscribe));
    sendMail(
        Json.object(
            "to",
            r.get("email"),
            "subject",
            report.get("subject"),
            "html",
            report.get("html"),
            "text",
            report.get("text"),
            "headers",
            Json.object(
                "List-Unsubscribe",
                "<" + unsubscribe + ">",
                "List-Unsubscribe-Post",
                "List-Unsubscribe=One-Click")));
  }

  /** Creates tables and records the configured sites. Runs once. */
  @Override
  public void init() {
    if (ready) {
      return;
    }
    synchronized (this) {
      if (ready) {
        return;
      }
      store.migrate();
      // A database that never had its statistics gathered gets them now, before any report is
      // read, rather than at the first scheduled check, which an app may never run.
      store.optimize(true);
      if (managedSites) {
        configured = List.copyOf(store.sites());
        loadRemotes();
      }
      for (Map<String, Object> site : configured) {
        store.upsertSite(site, now());
      }
      overrides = store.siteOverrides();
      // A process starting with a timezone set in code is the newest word on it: if the code
      // changed it, the days built in the old one are cleared here, once, and never by a process
      // still running.
      for (Map<String, Object> site : sites()) {
        if (remotes.containsKey(id(site))) {
          continue;
        }
        String stored = store.setting("rollup-zone:" + id(site));
        Object zone =
            stored != null && !stored.isEmpty() ? Js.map(Json.parse(stored)).get("zone") : null;
        if (zone == null) {
          store.setSetting(
              "rollup-zone:" + id(site),
              Json.stringify(Json.object("zone", timezone(site), "since", 0L)));
        } else if (!zone.equals(timezone(site))) {
          zoneChanged(id(site), timezone(site));
        }
      }
      ready = true;
    }
  }

  /** The dashboard and API. Routes is the port of routes.ts. */
  public Routes routes(Routes.Options options) {
    return new Routes(this, options);
  }

  /** The dashboard and API with the default options. */
  public Routes routes() {
    return routes(new Routes.Options());
  }

  /** The sites, with any settings changed in the dashboard applied. */
  @Override
  public List<Map<String, Object>> sites() {
    Map<String, Map<String, Object>> changed = overrides;
    List<Map<String, Object>> out = new ArrayList<>();
    for (Map<String, Object> site : configured) {
      Map<String, Object> merged = new LinkedHashMap<>(site);
      Map<String, Object> over = changed.get(id(site));
      if (over != null) {
        merged.putAll(over);
      }
      out.add(merged);
    }
    return out;
  }

  /** Checks a list of hostnames for a managed site: at least one, each a domain, none taken. */
  private List<String> hostnamesFor(Object input, String except) {
    List<Object> items;
    if (input instanceof List<?> list) {
      items = new ArrayList<>(list);
    } else {
      items =
          new ArrayList<>(
              List.of(
                  Js.string(input == null || input == Json.UNDEFINED ? "" : input)
                      .split("[" + Js.SPACE + ",]+", -1)));
    }
    List<String> out = new ArrayList<>();
    for (Object h : items) {
      String host = Js.trim(Js.string(h));
      host = host.replaceFirst("^https?://", "");
      host = host.replaceFirst("[/:]" + Js.DOT + "*\\z", "");
      host = Sources.stripWww(host);
      if (!host.isEmpty() && !out.contains(host)) {
        out.add(host);
      }
    }
    if (out.isEmpty()) {
      throw new SettingsError("Add the site's domain, like example.com", "site_domain_needed");
    }
    for (String host : out) {
      if (!DOMAIN.matcher(host).find() && !host.equals("localhost")) {
        throw new SettingsError(
            "\"" + host + "\" is not a domain name",
            "site_domain_invalid",
            Json.object("host", host));
      }
      for (Map<String, Object> site : configured) {
        if (!id(site).equals(except) && hostnames(site).contains(host)) {
          throw new SettingsError(
              host + " already belongs to " + name(site),
              "site_domain_taken",
              Json.object("host", host, "site", name(site)));
        }
      }
    }
    return out;
  }

  private void loadRemotes() {
    Map<String, Map<String, Object>> found = new LinkedHashMap<>();
    for (Map<String, Object> row : store.settingsStartingWith("remote:")) {
      String opened = Secret.unseal((String) row.get("value"), secret);
      if (opened != null && !opened.isEmpty()) {
        found.put(
            ((String) row.get("key")).substring("remote:".length()), Js.map(Json.parse(opened)));
      }
    }
    remotes = found;
  }

  /**
   * The install a site is read from, when it is counted elsewhere: url, token, site, hostnames, and
   * scope. Null for a site counted here.
   */
  @Override
  public Map<String, Object> remote(String id) {
    return remotes.get(id);
  }

  /** When a connected install's site last had a visit, asked at most once a minute. */
  public Object remoteLastSeen(String id) {
    Map<String, Object> info = remoteInfo(id);
    return info == null ? null : info.get("lastSeen");
  }

  /**
   * What a connected install says about its site: its last visit and how long it keeps visits,
   * asked at most once a minute. retentionMonths is {@link Json#UNDEFINED} while the install cannot
   * be reached, and connection says whether it answered ("ok"), refused this server's token
   * ("refused"), or could not be reached ("unreachable").
   */
  public Map<String, Object> remoteInfo(String id) {
    Map<String, Object> remote = remotes.get(id);
    if (remote == null) {
      return null;
    }
    Map<String, Object> cached = remoteSeen.get(id);
    if (cached != null && now() - Js.asLong(cached.get("at")) < 60_000) {
      Map<String, Object> out = new LinkedHashMap<>(cached);
      out.remove("at");
      return out;
    }
    Map<String, Object> info =
        Json.object(
            "lastSeen",
            cached != null ? cached.get("lastSeen") : null,
            "retentionMonths",
            Json.UNDEFINED,
            "connection",
            "unreachable");
    try {
      Response answer =
          Safefetch.installFetch(
              remote.get("url") + "/api/sites",
              Json.object(
                  "headers",
                  Map.of("authorization", "Bearer " + remote.get("token")),
                  "timeoutMs",
                  8000L,
                  "maxBytes",
                  REMOTE_MAX_BYTES),
              localInstalls,
              fetcher);
      if (answer.status() == 401 || answer.status() == 403) {
        info.put("connection", "refused");
      }
      Object body = jsonOrNull(answer);
      List<Object> sites = Js.list(Js.get(body, "sites"));
      if (sites != null) {
        for (Object s : sites) {
          if (!(s instanceof Map<?, ?> found)) {
            // TS reads `s.id` of each and stops at a null, as a throw would.
            if (s == null) {
              break;
            }
            continue;
          }
          if (Js.same(found.get("id"), remote.get("site")) && found.containsKey("id")) {
            info =
                Json.object(
                    "lastSeen",
                    nullish(found.get("lastSeen")),
                    "retentionMonths",
                    nullish(found.get("retentionMonths")),
                    "connection",
                    "ok");
            break;
          }
        }
      }
    } catch (RuntimeException e) {
      // Unreachable, as said.
    }
    Map<String, Object> seen = new LinkedHashMap<>();
    seen.put("at", now());
    seen.putAll(info);
    remoteSeen.put(id, seen);
    return info;
  }

  private static Object nullish(Object value) {
    return value == Json.UNDEFINED ? null : value;
  }

  /** Forgets what a connected install said, after a change made through it. */
  public void forgetRemoteInfo(String id) {
    remoteSeen.remove(id);
  }

  /** A capped JSON body, or null where TS's readJsonCapped(...).catch(() => null) gives null. */
  private static Object jsonOrNull(Response answer) {
    try {
      return Body.readJsonCapped(answer, REMOTE_MAX_BYTES);
    } catch (RuntimeException e) {
      return null;
    }
  }

  /**
   * Asks a connected install to delete the token this server holds for it. A failure leaves it
   * listed there.
   */
  private void revokeRemoteToken(Map<String, Object> remote) {
    try {
      Safefetch.installFetch(
          remote.get("url") + "/api/token",
          Json.object(
              "method",
              "DELETE",
              "headers",
              Map.of("authorization", "Bearer " + remote.get("token")),
              "timeoutMs",
              5_000L),
          localInstalls,
          fetcher);
    } catch (RuntimeException e) {
      // Left listed there.
    }
  }

  /**
   * Connects a site counted by another Runlight (an app's own install) so this server shows it too.
   * Takes the install's address, as its dashboard is (https://example.com/runlight), and an API
   * token made there.
   */
  private Map<String, Object> addRemoteSite(Map<String, Object> input) {
    String url = Js.trim(Js.string(orEmpty(input.get("url")))).replaceFirst("/+\\z", "");
    if (!Safefetch.installAddress(url, localInstalls)) {
      throw new SettingsError(
          "Enter the install's address, like https://example.com/runlight", "connect_url");
    }
    String token = Js.trim(Js.string(orEmpty(input.get("token"))));
    if (token.isEmpty()) {
      throw new SettingsError("Enter an API token from that install", "install_token");
    }
    Response answer;
    try {
      answer =
          Safefetch.installFetch(
              url + "/api/sites",
              Json.object(
                  "headers",
                  Map.of("authorization", "Bearer " + token),
                  "timeoutMs",
                  10_000L,
                  "maxBytes",
                  REMOTE_MAX_BYTES),
              localInstalls,
              fetcher);
    } catch (BodyTooLong e) {
      // An answer too long to read is no Runlight's.
      throw new SettingsError(
          url + " did not answer like a Runlight install",
          "connect_not_runlight",
          Json.object("url", url));
    } catch (RuntimeException e) {
      throw new SettingsError(
          "Could not reach " + url, "unreachable", Json.object("host", new Url(url).host()));
    }
    if (answer.status() == 401 || answer.status() == 403) {
      throw new SettingsError("That install refused the token", "install_refused");
    }
    Object body = jsonOrNull(answer);
    List<Object> listed = Js.list(Js.get(body, "sites"));
    List<Object> sites = listed != null ? listed : List.of();
    if (!answer.ok() || sites.isEmpty()) {
      throw new SettingsError(
          url + " did not answer like a Runlight install",
          "connect_not_runlight",
          Json.object("url", url));
    }
    // What the token may do there; an install from before manage tokens has no /api/token and
    // reads only.
    String scope = "read";
    String tokenSite = "";
    try {
      Response about =
          Safefetch.installFetch(
              url + "/api/token",
              Json.object(
                  "headers",
                  Map.of("authorization", "Bearer " + token),
                  "timeoutMs",
                  10_000L,
                  "maxBytes",
                  REMOTE_MAX_BYTES),
              localInstalls,
              fetcher);
      Object info = about.ok() ? jsonOrNull(about) : null;
      if (info instanceof Map<?, ?> m && "manage".equals(m.get("scope"))) {
        scope = "manage";
      }
      Object site = info instanceof Map<?, ?> m ? m.get("site") : null;
      tokenSite = Js.string(site == null || site == Json.UNDEFINED ? "" : site);
    } catch (RuntimeException e) {
      // Read only, then.
    }
    Object want =
        !tokenSite.isEmpty()
            ? tokenSite
            : input.containsKey("site") ? input.get("site") : Json.UNDEFINED;
    Map<String, Object> there = null;
    for (Object s : sites) {
      if (s instanceof Map<?, ?> m) {
        Object sid = m.containsKey("id") ? m.get("id") : Json.UNDEFINED;
        if (Js.same(sid, want)) {
          there = Js.map(s);
          break;
        }
      }
    }
    if (there == null) {
      there = Js.map(sites.get(0));
      if (there == null) {
        // TS reads the fields of whatever came first; a value that is not an object has none.
        there = Map.of();
      }
    }
    List<Object> thereHostnames = new ArrayList<>();
    List<Object> theirs = Js.list(there.get("hostnames"));
    if (theirs != null) {
      for (Object h : theirs) {
        if (h instanceof String) {
          thereHostnames.add(h);
        }
      }
    }
    Object thereId = there.get("id");
    synchronized (this) {
      // Connecting the same site again (to allow changes, or with a new token) updates it in
      // place.
      for (Map.Entry<String, Map<String, Object>> e : remotes.entrySet()) {
        Map<String, Object> known = e.getValue();
        if (url.equals(known.get("url")) && Js.same(known.get("site"), thereId)) {
          Map<String, Object> updated = new LinkedHashMap<>(known);
          updated.put("token", token);
          updated.put("scope", scope);
          updated.put("hostnames", thereHostnames);
          if (!token.equals(known.get("token"))) {
            revokeRemoteToken(known);
          }
          store.setSetting("remote:" + e.getKey(), Secret.seal(Json.stringify(updated), secret));
          Map<String, Map<String, Object>> next = new LinkedHashMap<>(remotes);
          next.put(e.getKey(), updated);
          remotes = next;
          remoteSeen.remove(e.getKey());
          return site(e.getKey());
        }
      }
      String source =
          !thereHostnames.isEmpty() ? (String) thereHostnames.get(0) : new Url(url).host();
      StringBuilder cleaned = new StringBuilder();
      for (int i = 0; i < source.length(); i++) {
        char c = source.charAt(i);
        boolean keep =
            (c >= 'a' && c <= 'z')
                || (c >= 'A' && c <= 'Z')
                || (c >= '0' && c <= '9')
                || c == '.'
                || c == '_'
                || c == '-';
        cleaned.append(keep ? c : '-');
      }
      String host = Js.lower(cleaned.toString());
      String id = Js.slice(host, 0, 56);
      for (int n = 2; hasSite(id); n++) {
        id = Js.slice(host, 0, 56) + "-" + n;
      }
      String name = Js.slice(Js.trim(Js.string(orEmpty(input.get("name")))), 0, 80);
      if (name.isEmpty()) {
        name = Js.string(there.containsKey("name") ? there.get("name") : Json.UNDEFINED);
      }
      // No hostnames: tracker hits never land on a site that is counted elsewhere.
      Object tz = there.get("timezone");
      Map<String, Object> site =
          Json.object(
              "id",
              id,
              "name",
              name,
              "hostnames",
              new ArrayList<>(),
              "timezone",
              tz instanceof String s && Time.isTimezone(s) ? s : "UTC");
      Map<String, Object> remote =
          Json.object(
              "url",
              url,
              "token",
              token,
              "site",
              thereId == Json.UNDEFINED ? null : thereId,
              "hostnames",
              thereHostnames,
              "scope",
              scope);
      store.upsertSite(site, now());
      store.setSetting("remote:" + id, Secret.seal(Json.stringify(remote), secret));
      Map<String, Map<String, Object>> next = new LinkedHashMap<>(remotes);
      next.put(id, remote);
      remotes = next;
      List<Map<String, Object>> all = new ArrayList<>(configured);
      all.add(site);
      configured = byName(all);
      return site;
    }
  }

  private boolean hasSite(String id) {
    for (Map<String, Object> site : configured) {
      if (id(site).equals(id)) {
        return true;
      }
    }
    return false;
  }

  /** Sites in name order, as TS sorts them with localeCompare. */
  private static List<Map<String, Object>> byName(List<Map<String, Object>> sites) {
    Collator collator = Collator.getInstance(Locale.ENGLISH);
    collator.setStrength(Collator.TERTIARY);
    List<Map<String, Object>> sorted = new ArrayList<>(sites);
    sorted.sort((a, b) -> collator.compare(name(a), name(b)));
    return List.copyOf(sorted);
  }

  /**
   * Adds a site, when sites are managed in the dashboard: one counted here (name, hostnames, and
   * timezone), or one connected from another install (remote: url, token, and site).
   */
  public Map<String, Object> addSite(Map<String, Object> input) {
    init();
    if (!managedSites) {
      throw new SettingsError("Sites are set in code", "sites_in_code");
    }
    if (input.get("remote") instanceof Map<?, ?> given) {
      Map<String, Object> remote = new LinkedHashMap<>(Js.map(given));
      remote.remove("name");
      if (input.containsKey("name")) {
        remote.put("name", input.get("name"));
      }
      return addRemoteSite(remote);
    }
    synchronized (this) {
      List<String> hostnames = hostnamesFor(input.get("hostnames"), null);
      String name = Js.trim(Js.string(orEmpty(input.get("name"))));
      if (name.isEmpty()) {
        name = hostnames.get(0);
      }
      if (name.length() > 80) {
        throw new SettingsError("A site name is 1 to 80 characters", "site_name");
      }
      Object tz = input.get("timezone");
      String timezone = Js.string(tz == null || tz == Json.UNDEFINED ? "UTC" : tz);
      if (!Time.isTimezone(timezone)) {
        throw new SettingsError(
            "Unknown timezone \"" + timezone + "\"",
            "unknown_timezone",
            Json.object("timezone", timezone));
      }
      String stem = Js.slice(hostnames.get(0).replaceAll("[^a-z0-9._-]", "-"), 0, 56);
      String id = stem;
      for (int n = 2; hasSite(id); n++) {
        id = stem + "-" + n;
      }
      Map<String, Object> site =
          Json.object(
              "id",
              id,
              "name",
              name,
              "hostnames",
              new ArrayList<Object>(hostnames),
              "timezone",
              timezone);
      store.upsertSite(site, now());
      List<Map<String, Object>> all = new ArrayList<>(configured);
      all.add(site);
      configured = byName(all);
      return site;
    }
  }

  /** Deletes a site and everything recorded for it, when sites are managed in the dashboard. */
  public void deleteSite(String id) {
    init();
    if (!managedSites) {
      throw new SettingsError("Sites are set in code", "sites_in_code");
    }
    if (!hasSite(id)) {
      throw new SettingsError("Unknown site", "unknown_site");
    }
    store.deleteSite(id);
    store.setSetting("retention:" + id, null);
    store.setSetting("observe-key:" + id, null);
    store.setSetting("rollup-zone:" + id, null);
    store.setSetting("orphans-swept:" + id, null);
    // A site made again with the same id starts its Umami import from the beginning.
    for (Map<String, Object> row : store.settingsStartingWith("import:umami-visits:" + id + ":")) {
      store.setSetting((String) row.get("key"), null);
    }
    synchronized (this) {
      // A connected install keeps its own data; only the connection goes, and its token there
      // with it.
      Map<String, Object> remote = remotes.get(id);
      if (remote != null) {
        revokeRemoteToken(remote);
        Map<String, Map<String, Object>> next = new LinkedHashMap<>(remotes);
        next.remove(id);
        remotes = next;
        store.setSetting("remote:" + id, null);
      }
      List<Map<String, Object>> rest = new ArrayList<>();
      for (Map<String, Object> site : configured) {
        if (!id(site).equals(id)) {
          rest.add(site);
        }
      }
      configured = List.copyOf(rest);
      Map<String, Map<String, Object>> over = new LinkedHashMap<>(overrides);
      over.remove(id);
      overrides = over;
    }
  }

  /**
   * Changes a site's name or timezone from the dashboard. Stored apart from the settings in code,
   * which keep being written on every start. A managed site has no settings in code, so its
   * changes, hostnames too, go to its row. A key left out of the patch is left alone, as TS's
   * undefined is.
   */
  public synchronized Map<String, Object> updateSite(String id, Map<String, Object> patch) {
    init();
    Map<String, Object> current = null;
    for (Map<String, Object> site : configured) {
      if (id(site).equals(id)) {
        current = site;
      }
    }
    if (current == null) {
      throw new SettingsError("Unknown site", "unknown_site");
    }
    Map<String, Object> next =
        new LinkedHashMap<>(managedSites ? current : overrides.getOrDefault(id, Map.of()));
    if (patch.containsKey("name") && patch.get("name") != Json.UNDEFINED) {
      String name = Js.trim(Js.string(patch.get("name")));
      if (name.isEmpty() || name.length() > 80) {
        throw new SettingsError("A site name is 1 to 80 characters", "site_name");
      }
      next.put("name", name);
    }
    if (patch.containsKey("timezone") && patch.get("timezone") != Json.UNDEFINED) {
      String timezone = Js.string(patch.get("timezone"));
      if (!Time.isTimezone(timezone)) {
        throw new SettingsError(
            "Unknown timezone \"" + timezone + "\"",
            "unknown_timezone",
            Json.object("timezone", timezone));
      }
      next.put("timezone", timezone);
      Map<String, Object> now = site(id);
      if (now == null || !timezone.equals(now.get("timezone"))) {
        zoneChanged(id, timezone);
      }
    }
    if (managedSites) {
      if (patch.containsKey("hostnames")
          && patch.get("hostnames") != Json.UNDEFINED
          && !remotes.containsKey(id)) {
        next.put("hostnames", new ArrayList<Object>(hostnamesFor(patch.get("hostnames"), id)));
      }
      store.upsertSite(next, now());
      List<Map<String, Object>> all = new ArrayList<>();
      for (Map<String, Object> site : configured) {
        all.add(id(site).equals(id) ? next : site);
      }
      configured = List.copyOf(all);
      return site(id);
    }
    store.setSiteOverrides(id, next);
    Map<String, Map<String, Object>> over = new LinkedHashMap<>(overrides);
    over.put(id, next);
    overrides = over;
    return site(id);
  }

  /** How many months of visits a site keeps, or null to keep everything (the default). */
  public Long retention(String site) {
    String stored = store.setting("retention:" + site);
    double value = Js.toNumber(stored);
    for (Long months : RETENTION_MONTHS) {
      if (months == value) {
        return months;
      }
    }
    return null;
  }

  /**
   * Sets how many months of visits a site keeps. Deleting a long history takes a while, so it runs
   * in pieces in idle(), after the answer, with tracking going on between them, as TS runs it after
   * answering.
   */
  public void setRetention(String site, Object months) {
    if (site(site) == null || remotes.containsKey(site)) {
      throw new SettingsError("Unknown site", "unknown_site");
    }
    boolean allowed = months == null;
    for (Long choice : RETENTION_MONTHS) {
      if (months instanceof Number n && n.doubleValue() == choice) {
        allowed = true;
      }
    }
    if (!allowed) {
      String list = String.join(", ", Js.strings(RETENTION_MONTHS));
      throw new SettingsError(
          "Keep visits for " + list + " months, or forever",
          "retention_bad",
          Json.object("months", list));
    }
    store.setSetting("retention:" + site, months == null ? null : Js.string(Js.num(months)));
    pruning.add(site);
  }

  /**
   * Queues work for idle(), so it runs after the answer is sent, as TypeScript leaves a promise
   * running. The scheduled check runs any an adapter left waiting.
   */
  @Override
  public void later(Runnable work) {
    later.add(work);
  }

  /**
   * Runs the work still waiting from earlier calls (later() work and a retention change's
   * deletions); the scheduled check and tests wait for it.
   */
  public void idle() {
    runLater();
    String only;
    while ((only = pruning.poll()) != null) {
      try {
        applyRetention(only);
      } catch (RuntimeException error) {
        log("Runlight: could not apply retention " + error.getMessage());
      }
    }
  }

  /**
   * Days are the site's local days, so a new timezone clears the built ones. Visitor ids recorded
   * before the change were made per day of the old timezone, and could count one person twice in a
   * new day, so only days that start after the change are built; earlier ones are always counted
   * visit by visit.
   */
  private long zoneChanged(String id, String timezone) {
    long since = now();
    store.clearRollups(id);
    store.setSetting(
        "rollup-zone:" + id, Json.stringify(Json.object("zone", timezone, "since", since)));
    return since;
  }

  /**
   * Since when a site's days may be built: 0 for always, or when its timezone last changed. Null
   * when this process holds a different timezone than the one on record, such as an older copy
   * still running during a deploy. It builds nothing for that site, and reports read the visits
   * themselves for any day not built, so nothing is wrong meanwhile.
   */
  private Long rollupSince(Map<String, Object> site) {
    String stored = store.setting("rollup-zone:" + id(site));
    if (stored == null || stored.isEmpty()) {
      store.setSetting(
          "rollup-zone:" + id(site),
          Json.stringify(Json.object("zone", timezone(site), "since", 0L)));
      return 0L;
    }
    Map<String, Object> zone = Js.map(Json.parse(stored));
    return timezone(site).equals(zone.get("zone")) ? Js.asLong(zone.get("since")) : null;
  }

  /**
   * Adds up each site's finished days, so long ranges read a row a day instead of every visit. A
   * day is built two hours after it ends in the site's timezone, once late engagement has landed,
   * and at most ROLLUP_BATCH days a run, so a long history fills in over a few runs. Reports read
   * the raw visits for any day not built yet, so the numbers are the same either way. Only a visit
   * still going two hours past midnight, with no 30 minute gap, could add to a day after it is
   * built.
   */
  public int buildRollups() {
    // Days rolled up by an earlier way of counting are cleared once, and built again below.
    if (!String.valueOf(ROLLUP_VERSION).equals(store.setting("rollup-version"))) {
      for (Map<String, Object> site : sites()) {
        store.clearRollups(id(site));
      }
      store.setSetting("rollup-version", String.valueOf(ROLLUP_VERSION));
    }
    int built = 0;
    long now = now();
    int batch = store.db().metered() ? METERED_ROLLUP_BATCH : ROLLUP_BATCH;
    for (Map<String, Object> site : sites()) {
      if (remotes.containsKey(id(site))) {
        continue;
      }
      Object first = store.firstSeen(id(site));
      if (first == null) {
        continue;
      }
      Long cut = retentionCutoff(id(site));
      long cutoff = cut == null ? 0 : cut;
      Long since = rollupSince(site);
      if (since == null) {
        continue;
      }
      Set<String> done = new java.util.HashSet<>(store.rollupDays(id(site)));
      String tz = timezone(site);
      String today = Time.localDate(now, tz);
      String oldest = Time.localDate(Math.max(Js.asLong(first), cutoff), tz);
      int made = 0;
      // Newest first, so recent ranges speed up before a long history is done.
      for (String day = Time.addDays(today, -1);
          day.compareTo(oldest) >= 0 && made < batch;
          day = Time.addDays(day, -1)) {
        if (done.contains(day)) {
          continue;
        }
        long start = Time.startOf(day, tz);
        long end = Time.startOf(Time.addDays(day, 1), tz);
        if (start < since) {
          break;
        }
        if (now < end + ROLLUP_DELAY_MS || start < cutoff) {
          continue;
        }
        try {
          store.buildRollupDay(id(site), day, start, end);
          made++;
        } catch (RuntimeException error) {
          // Another process building the same day at once loses nothing: the day is there either
          // way.
          if (!store.rollupDays(id(site)).contains(day)) {
            log(
                "Runlight: could not add up "
                    + day
                    + " for "
                    + id(site)
                    + " "
                    + error.getMessage());
          }
        }
      }
      built += made;
    }
    return built;
  }

  /**
   * The dashboard assistant's provider, model, and key, kept sealed like the mail keys. Null until
   * an owner sets it up.
   */
  public Map<String, Object> assistantSettings() {
    String stored = store.setting("assistant");
    String opened = stored != null && !stored.isEmpty() ? Secret.unseal(stored, secret) : null;
    return opened != null && !opened.isEmpty() ? Js.map(Json.parse(opened)) : null;
  }

  /**
   * Saves the assistant's settings; an empty key keeps the one saved for the same provider. Null
   * removes them.
   */
  public void saveAssistantSettings(Map<String, Object> input) {
    if (input == null) {
      store.setSetting("assistant", null);
      return;
    }
    Map<String, Object> provider = null;
    for (Map<String, Object> p : Assistant.PROVIDERS) {
      if (p.get("id").equals(input.get("provider"))) {
        provider = p;
        break;
      }
    }
    if (provider == null) {
      throw new SettingsError("Choose a provider", "assistant_provider");
    }
    String baseUrl = Js.trim(Js.string(orEmpty(input.get("baseUrl")))).replaceFirst("/+\\z", "");
    if (!baseUrl.isEmpty()) {
      Url parsed = Url.parse(baseUrl);
      if (parsed == null
          || (!parsed.protocol.equals("https:") && !parsed.protocol.equals("http:"))) {
        throw new SettingsError(
            "Enter the service's address, starting with https://", "assistant_address_bad");
      }
    }
    String providerBase = (String) provider.get("baseUrl");
    if (baseUrl.isEmpty() && providerBase.isEmpty()) {
      throw new SettingsError("Enter the service's address", "assistant_address");
    }
    String model = Js.slice(Js.trim(Js.string(orEmpty(input.get("model")))), 0, 200);
    if (model.isEmpty() && ((String) provider.get("model")).isEmpty()) {
      throw new SettingsError("Enter the model to use", "assistant_model");
    }
    Map<String, Object> before = assistantSettings();
    String key = Js.trim(Js.string(orEmpty(input.get("key"))));
    // A saved key is kept only for the same service at the same address, so it is never sent
    // somewhere new.
    String beforeBase =
        before != null && before.get("baseUrl") != null ? Js.string(before.get("baseUrl")) : "";
    if (key.isEmpty()
        && before != null
        && provider.get("id").equals(before.get("provider"))
        && (beforeBase.isEmpty() ? providerBase : beforeBase)
            .equals(baseUrl.isEmpty() ? providerBase : baseUrl)) {
      key = before.get("key") != null ? Js.string(before.get("key")) : "";
    }
    if (key.isEmpty() && "yes".equals(provider.get("key"))) {
      throw new SettingsError(
          "Enter your " + provider.get("name") + " key",
          "assistant_key",
          Json.object("provider", provider.get("name")));
    }
    Map<String, Object> settings =
        Json.object("provider", provider.get("id"), "model", model, "baseUrl", baseUrl, "key", key);
    store.setSetting("assistant", Secret.seal(Json.stringify(settings), secret));
  }

  /** The oldest moment a site keeps visits from, or null when it keeps everything. */
  @Override
  public Long retentionCutoff(String site) {
    Long months = retention(site);
    if (months == null) {
      return null;
    }
    // setUTCMonth: the same day and time that many months back, a day past the month's end
    // running on.
    long now = now();
    long dayMs = Math.floorMod(now, 86_400_000L);
    LocalDate date = LocalDate.ofEpochDay(Math.floorDiv(now, 86_400_000L));
    LocalDate first = date.withDayOfMonth(1).minusMonths(months);
    long day = first.toEpochDay() + date.getDayOfMonth() - 1;
    return LocalDate.ofEpochDay(day).atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()
        + dayMs;
  }

  /**
   * Deletes visits older than each site's retention allows. Cheap when there is nothing to delete.
   */
  private void applyRetention(String only) {
    for (Map<String, Object> site : sites()) {
      if ((only != null && !only.isEmpty() && !id(site).equals(only))
          || remotes.containsKey(id(site))) {
        continue;
      }
      Long cutoff = retentionCutoff(id(site));
      if (cutoff == null) {
        continue;
      }
      store.dropBefore(id(site), cutoff);
      // Earlier versions let an event join its visit days late, so retention could leave such an
      // event behind once its visit was gone. They are swept once; events can no longer join a
      // visit that late.
      if (!Js.truthy(store.setting("orphans-swept:" + id(site)))) {
        store.dropOrphans(id(site), cutoff, now());
        store.setSetting("orphans-swept:" + id(site), "1");
      }
    }
  }

  /** A site by id, the first when the id is null or empty, and null when there is no such site. */
  @Override
  public Map<String, Object> site(String id) {
    List<Map<String, Object>> sites = sites();
    if (id == null || id.isEmpty()) {
      return sites.isEmpty() ? null : sites.get(0);
    }
    for (Map<String, Object> site : sites) {
      if (id(site).equals(id)) {
        return site;
      }
    }
    return null;
  }

  /** The site a page belongs to, or null if it belongs to none. */
  public Map<String, Object> siteFor(String hostname) {
    return siteFor(hostname, null);
  }

  /** The site a page belongs to, of the one named when an id is given, or null. */
  public Map<String, Object> siteFor(String hostname, String id) {
    String host = Sources.stripWww(hostname);
    Map<String, Map<String, Object>> elsewhere = remotes;
    // A site counted by another install never takes hits here.
    if (!elsewhere.isEmpty()) {
      List<Map<String, Object>> local = new ArrayList<>();
      for (Map<String, Object> site : sites()) {
        if (!elsewhere.containsKey(id(site))) {
          local.add(site);
        }
      }
      if (id != null && !id.isEmpty()) {
        return elsewhere.containsKey(id) ? null : siteForAmong(local, host, id);
      }
      return siteForAmong(local, host, null);
    }
    return siteForAmong(sites(), host, id);
  }

  private static Map<String, Object> siteForAmong(
      List<Map<String, Object>> sites, String host, String id) {
    if (id != null && !id.isEmpty()) {
      for (Map<String, Object> site : sites) {
        if (id(site).equals(id)) {
          return hostnames(site).isEmpty() || hostnames(site).contains(host) ? site : null;
        }
      }
      return null;
    }
    if (sites.size() == 1) {
      Map<String, Object> only = sites.get(0);
      return hostnames(only).isEmpty() || hostnames(only).contains(host) ? only : null;
    }
    for (Map<String, Object> site : sites) {
      if (hostnames(site).contains(host)) {
        return site;
      }
    }
    return null;
  }

  /**
   * A test from a developer's own machine while a site is being set up. A site with no visits yet
   * accepts hits from localhost and .local or .test names, so the install screen confirms it works;
   * after its first visit they are ignored again, so local browsing never mixes with real traffic.
   */
  private Map<String, Object> setupSite(String hostname, String id) {
    String host = Js.lower(hostname).replaceAll("^\\[|\\]\\z", "");
    if (!(host.equals("localhost")
        || host.equals("127.0.0.1")
        || host.equals("::1")
        || host.matches("(?s).*\\.(localhost|local|test)\\z"))) {
      return null;
    }
    List<Map<String, Object>> sites = sites();
    Map<String, Object> site =
        id != null && !id.isEmpty() ? site(id) : sites.size() == 1 ? sites.get(0) : null;
    if (site == null || remotes.containsKey(id(site))) {
      return null;
    }
    return store.lastSeen(id(site)) == null ? site : null;
  }

  /**
   * The visitor's address, for the daily visitor hash and the rate limit. Behind a proxy it comes
   * from a header. By default that is the last X-Forwarded-For entry, which the nearest proxy wrote
   * and a client cannot choose, then X-Real-IP and CF-Connecting-IP. Naming one header reads only
   * that one. Otherwise it is the connection's address: the given ip, or else the request's own
   * remoteAddress.
   */
  @Override
  public String clientIp(Request request, Map<String, Object> context) {
    if (!Boolean.FALSE.equals(trustProxy)) {
      Headers h = request.headers();
      String forwarded;
      if (Boolean.TRUE.equals(trustProxy)) {
        forwarded = lastEntry(h.get("x-forwarded-for"));
        if (forwarded == null) {
          forwarded = h.get("x-real-ip");
        }
        if (forwarded == null) {
          forwarded = h.get("cf-connecting-ip");
        }
      } else if ("x-forwarded-for".equals(trustProxy)) {
        forwarded = lastEntry(h.get("x-forwarded-for"));
      } else {
        forwarded = h.get(Js.string(trustProxy));
      }
      if (forwarded != null && !Js.trim(forwarded).isEmpty()) {
        return Js.trim(forwarded);
      }
    }
    Object ip = context == null ? null : context.get("ip");
    return ip instanceof String given ? given : request.remoteAddress();
  }

  /** The visitor's address, read from the request alone. */
  public String clientIp(Request request) {
    return clientIp(request, Map.of());
  }

  private static String lastEntry(String value) {
    if (value == null) {
      return null;
    }
    String last = null;
    for (String part : value.split(",", -1)) {
      String trimmed = Js.trim(part);
      if (!trimmed.isEmpty()) {
        last = trimmed;
      }
    }
    return last;
  }

  /**
   * Today's salt in a site's timezone and, if it still exists, yesterday's. Salts follow the site's
   * own days, as its reports do, so a visitor is one visitor for the whole of that site's day. Old
   * salts go on the way.
   */
  private Salts currentSalts(long now, String timezone) {
    String day = Time.localDate(now, timezone);
    Salts cached = salts.get(timezone);
    if (cached != null && cached.day().equals(day)) {
      return cached;
    }
    String today = store.salt(day, Hash.randomSalt());
    String yesterday = store.saltIfExists(Time.addDays(day, -1));
    dropOldSalts(now);
    Salts fresh = new Salts(day, today, yesterday);
    salts.put(timezone, fresh);
    return fresh;
  }

  /**
   * Deletes salts whose day has ended everywhere. The earliest timezone is a day behind UTC and
   * still needs its yesterday, so a salt goes two UTC days after its date.
   */
  private void dropOldSalts(long now) {
    store.dropSaltsBefore(Time.isoString(now - 2 * 86_400_000L).substring(0, 10));
  }

  /**
   * The host a proxy says the request was for, read only when proxy headers are trusted, as the
   * client's address is.
   */
  private String forwardedHost(Request request) {
    return !Boolean.FALSE.equals(trustProxy) ? request.headers().get("x-forwarded-host") : null;
  }

  /**
   * Handles one tracker request. Bad input is dropped quietly; only a database that keeps failing
   * throws.
   */
  public void collect(Request request) {
    collect(request, Map.of());
  }

  /**
   * Handles one tracker request, with the connection's address when the request does not carry it.
   */
  public void collect(Request request, Map<String, Object> context) {
    String header = request.headers().get("content-length");
    double length = Js.toNumber(header == null ? 0L : header);
    if (length > Payload.MAX_BODY) {
      return;
    }
    // Read no more than a tracker hit can be, whatever the length header says (or when there is
    // none).
    byte[] bytes = request.bytes();
    if (bytes.length > Payload.MAX_BODY) {
      return;
    }
    Map<String, Object> payload = Payload.parsePayload(Js.decodeUtf8(bytes));
    if (payload == null) {
      return;
    }

    String ua = userAgent(request);
    if (Ua.aiAgent(ua) != null || Ua.isBot(ua)) {
      return;
    }
    if (limit != null && !limit.allow(clientIp(request, context))) {
      return;
    }

    // A database too busy to take the hit right now (every pooled connection held by long reports,
    // or another process writing the SQLite file) gets it a little later, at the time it arrived.
    long now = now();
    for (int attempt = 1; ; attempt++) {
      try {
        record(payload, request, context, now);
        return;
      } catch (RuntimeException error) {
        if (attempt >= 3 || !busy(error)) {
          throw error;
        }
        try {
          Thread.sleep(500L * attempt);
        } catch (InterruptedException e) {
          Thread.currentThread().interrupt();
          throw error;
        }
      }
    }
  }

  private static String userAgent(Request request) {
    String ua = request.headers().get("user-agent");
    return ua == null ? "" : ua;
  }

  private void record(
      Map<String, Object> payload, Request request, Map<String, Object> context, long now) {
    // Managed sites load from the database in init(), so it must come first.
    init();
    Url url = (Url) payload.get("url");
    String siteId = (String) payload.get("site");
    Map<String, Object> site = siteFor(url.hostname, siteId);
    if (site == null) {
      site = setupSite(url.hostname, siteId);
    }
    if (site == null) {
      return;
    }

    String kind = (String) payload.get("kind");
    if (kind.equals("engagement")) {
      engagement(site, payload, now);
      return;
    }

    Map<String, Object> page = Sources.parsePage(url);
    Map<String, Object> session = null;
    boolean reopen = true;
    String pageviewId = (String) payload.get("pageviewId");
    if (kind.equals("event") && !pageviewId.isEmpty()) {
      Map<String, Object> pageview = store.pageview(id(site), pageviewId);
      // An event joins its page's visit unless that visit began longer ago than reports look for
      // its rows (a tab left open for days); it then starts a visit of its own, as any later
      // activity would.
      if (pageview != null && now - Js.asLong(pageview.get("startedAt")) < SqlStore.EVENT_TAIL_MS) {
        session = Json.object("id", pageview.get("session"), "visitor", pageview.get("visitor"));
        // A visit idle past the 30 minutes stays ended: the event counts in it without reopening
        // it.
        reopen = now - Js.asLong(pageview.get("lastAt")) <= SESSION_IDLE_MS;
        if (now - Js.asLong(pageview.get("startedAt")) > 3_600_000) {
          store.touchedOldVisit(
              id(site), Js.asLong(pageview.get("startedAt")), now - ROLLUP_DELAY_MS + 3_600_000);
        }
      }
    }
    if (session == null) {
      Object width = payload.get("screenWidth");
      Object height = payload.get("screenHeight");
      session =
          sessionFor(
              site,
              request,
              context,
              page,
              (String) payload.get("referrer"),
              now,
              width,
              Js.truthy(width) && Js.truthy(height)
                  ? Js.string(width) + "x" + Js.string(height)
                  : "",
              (String) payload.get("language"));
    }

    store.touchSession((String) session.get("id"), now, kind, (String) page.get("path"), reopen);
    store.insertEvent(
        Json.object(
            "site",
            id(site),
            "ts",
            now,
            "kind",
            kind,
            "visitor",
            session.get("visitor"),
            "session",
            session.get("id"),
            "pageview",
            pageviewId,
            "path",
            page.get("path"),
            "hostname",
            page.get("hostname"),
            "title",
            kind.equals("pageview") ? payload.get("title") : "",
            "name",
            kind.equals("event") ? payload.get("name") : "",
            "props",
            payload.get("props"),
            "engagedMs",
            0L,
            "scroll",
            null,
            "link",
            ""));
  }

  /**
   * The visitor's open session on a site, or a new one attributed to this request. Shared by
   * tracker hits and short link clicks. One visitor's requests take turns here, so a pageview and
   * the event right after it find one session.
   */
  private Map<String, Object> sessionFor(
      Map<String, Object> site,
      Request request,
      Map<String, Object> context,
      Map<String, Object> page,
      String referrer,
      long now,
      Object screenWidth,
      String screen,
      String language) {
    String ua = userAgent(request);
    String address = clientIp(request, context);
    Salts current = currentSalts(now, timezone(site));
    String today = Hash.visitorHash(current.today(), id(site), address, ua);
    List<String> candidates = new ArrayList<>();
    candidates.add(today);
    if (current.yesterday() != null && !current.yesterday().isEmpty()) {
      candidates.add(Hash.visitorHash(current.yesterday(), id(site), address, ua));
    }
    String key = id(site) + ":" + today;
    synchronized (turns[Math.floorMod(key.hashCode(), turns.length)]) {
      Map<String, Object> open = store.openSession(id(site), candidates, now - SESSION_IDLE_MS);
      if (open != null) {
        return open;
      }

      Map<String, Object> session = Json.object("id", Hash.randomId(), "visitor", today);
      Map<String, Object> attribution = Sources.attribute(page, referrer, hostnames(site));
      Headers h = request.headers();
      Map<String, Object> parsed =
          Ua.parseClient(
              ua,
              Json.object(
                  "brands", h.get("sec-ch-ua"),
                  "mobile", h.get("sec-ch-ua-mobile"),
                  "platform", h.get("sec-ch-ua-platform")),
              screenWidth instanceof Number n ? n.doubleValue() : null);
      Map<String, Object> location = Geo.locate(h, address, geo);
      Map<String, Object> utm = Js.map(page.get("utm"));
      Map<String, Object> row = new LinkedHashMap<>();
      row.put("id", session.get("id"));
      row.put("site", id(site));
      row.put("visitor", session.get("visitor"));
      row.put("startedAt", now);
      row.put("hostname", page.get("hostname"));
      row.putAll(attribution);
      row.put("utmSource", utm.get("source"));
      row.put("utmMedium", utm.get("medium"));
      row.put("utmCampaign", utm.get("campaign"));
      row.put("utmTerm", utm.get("term"));
      row.put("utmContent", utm.get("content"));
      row.putAll(location);
      row.putAll(parsed);
      row.put("screen", screen);
      row.put("language", language);
      store.insertSession(row);
      return session;
    }
  }

  /**
   * The link domains, read at most every 30 seconds. Every request to a standalone server asks, so
   * this saves a query on each tracker hit; a change made here clears it at once, one made by
   * another process within half a minute.
   */
  private Set<String> linkDomainSet() {
    long now = now();
    LinkDomains cached = linkDomainCache;
    if (cached != null && now - cached.at() < 30_000) {
      return cached.domains();
    }
    init();
    Set<String> domains = new java.util.HashSet<>();
    for (Map<String, Object> d : store.linkDomains()) {
      domains.add((String) d.get("domain"));
    }
    linkDomainCache = new LinkDomains(now, domains);
    return domains;
  }

  /** Clears the cached link domains after one is added or removed. */
  @Override
  public void forgetLinkDomains() {
    linkDomainCache = null;
  }

  /**
   * Handles {linkPath}/{slug} on the app's own domain: in a front controller, answer a request
   * whose path starts with "/go/" with {@code runlight.linkHandler().apply(request)}.
   */
  public Function<Request, Response> linkHandler() {
    return request -> {
      String path = new Url(request.url()).pathname;
      String slug =
          path.startsWith(linkPath + "/") ? decode(path.substring(linkPath.length() + 1)) : "";
      Response found =
          !slug.isEmpty() && !slug.contains("/") ? redirect(request, slug, "", Map.of()) : null;
      return found != null ? found : notFound();
    };
  }

  /**
   * For middleware: when a request arrives on a link domain added in Settings (such as
   * t.example.com), answers /{slug} there with the redirect, and anything else with a 404. Null for
   * every other host, so the app carries on as normal, and for the dashboard's own paths, so its
   * owner can always reach it to remove the domain.
   */
  public Response linkDomainResponse(Request request) {
    return linkDomainResponse(request, Map.of());
  }

  /** {@link #linkDomainResponse(Request)} with the connection's address. */
  public Response linkDomainResponse(Request request, Map<String, Object> context) {
    Url url = new Url(request.url());
    // A forwarded host only counts behind a proxy that sets it; otherwise any client could pick
    // one.
    String given = forwardedHost(request);
    if (given == null) {
      given = request.headers().get("host");
    }
    if (given == null) {
      given = url.host();
    }
    String host = Sources.stripWww(Js.trim(given.split(",", -1)[0]).split(":", -1)[0]);
    if (!linkDomainSet().contains(host)) {
      return null;
    }
    // Lets the dashboard confirm that requests to this domain reach Runlight.
    if (url.pathname.equals(LINK_DOMAIN_CHECK)) {
      return new Response(
          Json.stringify(Json.object("runlight", true, "domain", host)),
          200,
          Headers.of("content-type", "application/json", "cache-control", "no-store"));
    }
    List<String> bases = routeBases.isEmpty() ? List.of("/runlight") : routeBases;
    for (String base : bases) {
      if (!base.equals("/") && (url.pathname.equals(base) || url.pathname.startsWith(base + "/"))) {
        return null;
      }
    }
    String slug = decode(url.pathname.substring(1));
    Response found =
        !slug.isEmpty() && !slug.contains("/") ? redirect(request, slug, host, context) : null;
    return found != null ? found : notFound();
  }

  private static Response notFound() {
    return new Response("Not found", 404, Headers.of("content-type", "text/plain; charset=utf-8"));
  }

  /** The error decodeURIComponent throws on a broken escape. */
  public static final class UriError extends IllegalArgumentException {
    private static final long serialVersionUID = 1L;

    public UriError() {
      super("URI malformed");
    }
  }

  /** decodeURIComponent, throwing where it throws a URIError. */
  private static String decode(String text) {
    String decoded = Js.decodeURIComponent(text);
    if (decoded == null) {
      throw new UriError();
    }
    return decoded;
  }

  /**
   * Answers a request for a short link: a redirect to its destination, with the click recorded like
   * a visit (source, place, device, and any campaign tags on the short URL) but kept out of visitor
   * and pageview counts. Bots are redirected and not counted. domain is the link domain the request
   * came in on, or "" for the app's own link path, which answers for every link. Null when no link
   * fits.
   */
  public Response redirect(
      Request request, String slug, String domain, Map<String, Object> context) {
    init();
    Url url = new Url(request.url());
    String given = forwardedHost(request);
    if (given == null) {
      given = request.headers().get("host");
    }
    if (given == null) {
      given = url.host();
    }
    String host = Sources.stripWww(given.split(":", -1)[0]);
    Map<String, Object> link = store.linkBySlug(slug);
    // The app's own link path answers for every link, so a link whose domain was removed keeps
    // working; a link domain answers only for its own links.
    if (link == null || (!domain.isEmpty() && !domain.equals(link.get("domain")))) {
      return null;
    }
    Map<String, Object> site = site((String) link.get("site"));
    if (site == null) {
      List<Map<String, Object>> all = sites();
      site = all.isEmpty() ? null : all.get(0);
    }
    String ua = userAgent(request);
    if (site != null && Ua.aiAgent(ua) == null && !Ua.isBot(ua) && request.method().equals("GET")) {
      try {
        long now = now();
        String accept = request.headers().get("accept-language");
        String first = (accept == null ? "" : accept).split(",", -1)[0].split(";", -1)[0];
        String language = Js.slice(Js.trim(first), 0, 35);
        String referer = request.headers().get("referer");
        Map<String, Object> session =
            sessionFor(
                site,
                request,
                context,
                Sources.parsePage(url),
                referer == null ? "" : referer,
                now,
                null,
                "",
                language);
        store.touchSession((String) session.get("id"), now, "click", url.pathname);
        store.insertEvent(
            Json.object(
                "site",
                id(site),
                "ts",
                now,
                "kind",
                "click",
                "visitor",
                session.get("visitor"),
                "session",
                session.get("id"),
                "pageview",
                "",
                "path",
                Js.slice(url.pathname, 0, 1000),
                "hostname",
                host,
                "title",
                "",
                "name",
                link.get("slug"),
                "props",
                null,
                "engagedMs",
                0L,
                "scroll",
                null,
                "link",
                link.get("id")));
      } catch (RuntimeException error) {
        // A failed count must never break the redirect.
        log("Runlight: could not record a link click " + error.getMessage());
      }
    }
    return new Response(
        new byte[0],
        302,
        Headers.of(
            "location",
            (String) link.get("url"),
            "cache-control",
            "no-store",
            "referrer-policy",
            "no-referrer-when-downgrade"));
  }

  private void engagement(Map<String, Object> site, Map<String, Object> payload, long now) {
    long engaged = Js.asLong(payload.get("engagedMs"));
    if (engaged <= 0) {
      return;
    }
    String pageviewId = (String) payload.get("pageviewId");
    Map<String, Object> pageview = store.pageview(id(site), pageviewId);
    // Reports look for a visit's rows only so long after it began, so later time on it is let go.
    if (pageview == null || now - Js.asLong(pageview.get("startedAt")) >= SqlStore.EVENT_TAIL_MS) {
      return;
    }
    store.addEngagement((String) pageview.get("session"), engaged);
    // Only a visit that began more than an hour ago can belong to a day that is already added up.
    if (now - Js.asLong(pageview.get("startedAt")) > 3_600_000) {
      store.touchedOldVisit(
          id(site), Js.asLong(pageview.get("startedAt")), now - ROLLUP_DELAY_MS + 3_600_000);
    }
    store.insertEvent(
        Json.object(
            "site",
            id(site),
            "ts",
            now,
            "kind",
            "engagement",
            "visitor",
            pageview.get("visitor"),
            "session",
            pageview.get("session"),
            "pageview",
            pageviewId,
            "path",
            pageview.get("path"),
            "hostname",
            pageview.get("hostname"),
            "title",
            "",
            "name",
            "",
            "props",
            null,
            "engagedMs",
            engaged,
            "scroll",
            payload.get("scroll"),
            "link",
            ""));
  }

  /**
   * Records a request from a known AI agent. Call it from middleware for every page request; it
   * ignores everything else and never throws. Agents do not run JavaScript, so the tracker cannot
   * see them.
   */
  public boolean observe(Request request) {
    return observe(request, null);
  }

  /**
   * Records a request from a known AI agent, served at a time in milliseconds a log reader gives,
   * or now when it is null.
   */
  public boolean observe(Request request, Double at) {
    try {
      if (!request.method().equals("GET")) {
        return false;
      }
      Map<String, Object> agent = Ua.aiAgent(userAgent(request));
      if (agent == null) {
        return false;
      }
      Url url = new Url(request.url());
      // Pages, not their assets.
      Matcher m = PAGE_EXTENSION.matcher(url.pathname);
      if (m.find()
          && !List.of("html", "htm", "md", "txt", "php")
              .contains(m.group(1).toLowerCase(Locale.ROOT))) {
        return false;
      }
      String host = forwardedHost(request);
      if (host == null) {
        host = request.headers().get("host");
      }
      if (host == null) {
        host = url.hostname;
      }
      init();
      Map<String, Object> site = siteFor(host.split(":", -1)[0]);
      if (site == null) {
        return false;
      }
      // A log reader sends when the page was served. Older than a week is dropped, so a first run
      // over an old log does not land as one spike on today; a time ahead of now counts as now.
      long now = now();
      boolean finite = at != null && !at.isNaN() && !at.isInfinite();
      if (finite && at < now - 7 * 86_400_000L) {
        return false;
      }
      long ts = finite && at <= now ? (long) Math.floor(at) : now;
      store.insertEvent(
          Json.object(
              "site",
              id(site),
              "ts",
              ts,
              "kind",
              "fetch",
              "visitor",
              "",
              "session",
              "",
              "pageview",
              "",
              "path",
              Js.slice(url.pathname, 0, 1000),
              "hostname",
              Sources.stripWww(url.hostname),
              "title",
              "",
              "name",
              agent.get("name"),
              "props",
              Json.object("company", agent.get("company"), "kind", agent.get("kind")),
              "engagedMs",
              0L,
              "scroll",
              null,
              "link",
              ""));
      return true;
    } catch (RuntimeException error) {
      // Analytics must never break the page it watches, but a failure should still be seen.
      log("Runlight: could not record an AI agent fetch " + error.getMessage());
      return false;
    }
  }

  /**
   * Scheduled upkeep, safe to run every minute. It rotates salts, sends the email reports that are
   * due, deletes visits past each site's retention, and builds daily rollups. It also rereads
   * sites, their dashboard settings, and connected installs, so a change made by another process
   * sharing the database shows up here too. A check called while one is running from inside it does
   * nothing more; one called from another thread waits for it.
   *
   * @return ok, and the reports sent and failed
   */
  public Map<String, Object> check() {
    if (checking.isHeldByCurrentThread()) {
      return Json.object("ok", true, "reports", Json.object("sent", 0L, "failed", 0L));
    }
    checking.lock();
    try {
      return runCheck();
    } finally {
      checking.unlock();
    }
  }

  private void runLater() {
    Runnable work;
    while ((work = later.poll()) != null) {
      try {
        work.run();
      } catch (RuntimeException error) {
        log("Runlight: " + error.getMessage());
      }
    }
  }

  private Map<String, Object> runCheck() {
    init();
    runLater();
    // Requests take a current schema version on trust; the scheduled check goes over every table
    // and index.
    store.migrate(true);
    synchronized (this) {
      if (managedSites) {
        configured = List.copyOf(store.sites());
        loadRemotes();
      }
      // A name or timezone changed in the dashboard by another process reaches this one too.
      overrides = store.siteOverrides();
    }
    salts.clear();
    Set<String> zones = new LinkedHashSet<>();
    for (Map<String, Object> site : sites()) {
      zones.add(timezone(site));
    }
    for (String zone : zones) {
      currentSalts(now(), zone);
    }
    dropOldSalts(now());
    // Every site's retention covers any one site's that is still waiting.
    pruning.clear();
    try {
      applyRetention(null);
    } catch (RuntimeException error) {
      log("Runlight: could not apply retention " + error.getMessage());
    }
    if (now() - optimizedAt >= 86_400_000L) {
      optimizedAt = now();
      store.optimize();
    }
    buildRollups();
    return Json.object("ok", true, "reports", sendReports());
  }

  /** True for a database that could not take a statement just now and may a moment later. */
  private static boolean busy(Throwable error) {
    for (Throwable e = error; e != null; e = e.getCause()) {
      if (e.getMessage() != null && BUSY.matcher(e.getMessage()).find()) {
        return true;
      }
    }
    return false;
  }

  /** console.error. */
  static void log(String message) {
    System.err.println(message);
  }
}
