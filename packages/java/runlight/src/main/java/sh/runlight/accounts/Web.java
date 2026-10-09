package sh.runlight.accounts;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.LongSupplier;
import java.util.function.Supplier;
import java.util.logging.Level;
import java.util.logging.Logger;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import sh.runlight.CodedError;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.http.Headers;
import sh.runlight.http.Request;
import sh.runlight.http.Response;
import sh.runlight.http.SearchParams;
import sh.runlight.http.Url;
import sh.runlight.store.SqlStore;

/**
 * Accounts on the web: sign-in, the code step, invites, first-run setup, and the Account and People
 * APIs, under the base path the routes answer at. The standalone server and an app with
 * routes({accounts: true}) share it.
 *
 * <p>Who may create the first account ({@code firstAccount}): the server's printed one-time code
 * ({code: ...}), the app's token ({token: ...}), anyone ("open", for development), or nobody yet
 * ("locked").
 */
public final class Web {
  /** The little of a Runlight that accounts on the web reach for. */
  public interface Host {
    SqlStore store();

    /** The mail service's settings, or null when there is none. */
    Map<String, Object> mailSettings();

    /**
     * Sends a message, {to, subject, text, html}. A {@link CodedError} it throws has its code and
     * params passed on to the dashboard.
     */
    void sendMail(Map<String, Object> message);

    /** The client's address as the install reads it, or "" when unknown. */
    String clientIp(Request request, Map<String, Object> context);

    /**
     * Queues work to run once the answer is sent (an adapter calls Runlight.idle() then), as
     * TypeScript leaves a promise running.
     */
    void later(Runnable work);
  }

  private static final Logger LOG = Logger.getLogger("sh.runlight");

  private static final String CSP =
      "default-src 'none'; script-src 'self'; style-src 'self'; img-src data:; form-action 'self'; base-uri 'none'; frame-ancestors 'none'";

  private static final String DEVICE_COOKIE = "runlight_device";

  /**
   * Who made each token, kept beside it as a setting, so removing someone or making them a viewer
   * deletes them.
   */
  private static final String MADE_BY = "token-by:";

  /**
   * When each account was last sent a sign-in link, at most one a minute; a setting, as the PHP
   * port keeps it, so every process shares it.
   */
  private static final String LINK_SENT = "login-link-sent:";

  private static final Pattern UNSAFE = Pattern.compile("[\\x00-\\x1f\\x7f\\\\]");
  private static final Pattern SPACES = Pattern.compile("[" + Js.SPACE + "]");
  private static final Pattern RESET_2FA = Pattern.compile("^/api/people/([a-f0-9]{24})/2fa\\z");
  private static final Pattern HAND_OVER = Pattern.compile("^/api/people/([a-f0-9]{24})/owner\\z");
  private static final Pattern INVITE =
      Pattern.compile("^/api/invites/([a-f0-9]{24})(/resend)?\\z");
  private static final Pattern PERSON = Pattern.compile("^/api/people/([a-f0-9]{24})\\z");

  private final Accounts accounts;
  private final Host rl;
  private final SqlStore store;
  private final String base;
  private final LongSupplier now;
  private final Object first;
  private final Supplier<String> home;
  private final String forgot;
  private final String setupWhere;
  private final String cookiePath;
  private final String homePath;
  private final boolean asksForToken;
  private volatile boolean existing;

  // Wrong passwords are counted twice. Per account and address, ten tries;
  // per account from anywhere, fifty, so a caller who invents a new address
  // for every try still cannot guess on and on. Addresses come from
  // forwarding headers a client can write, so they never stand alone.
  // Each try counts before the password is checked, and a right one is taken back.
  private final Throttle perAddress;
  private final Throttle perAccount;
  // Six-digit codes: five wrong tries an account every fifteen minutes, and five to confirm the
  // first one. Password re-checks in Account: ten.
  private final Throttle codeTries;
  private final Throttle confirmTries;
  private final Throttle rechecks;

  /**
   * Accounts on the web, from options with the TypeScript's keys: runlight (a {@link Host}),
   * secret, base, now (a {@link LongSupplier} of milliseconds), firstAccount ("open", "locked", or
   * a map with code or token), home (an optional {@link Supplier} of the install's own origin),
   * forgot, and setupWhere (optional: where to find the setup link with the one-time code when it
   * is not in a log, as HTML).
   */
  public Web(Map<String, Object> options) {
    this.rl = (Host) options.get("runlight");
    this.store = rl.store();
    this.base = (String) options.get("base");
    this.now = (LongSupplier) options.get("now");
    this.first = options.get("firstAccount");
    this.home =
        options.get("home") instanceof Supplier<?> given
            ? () -> given.get() instanceof String origin ? origin : null
            : null;
    this.forgot = (String) options.get("forgot");
    this.setupWhere = Js.strOr(options.get("setupWhere"), null);
    this.accounts = new Accounts(store, (String) options.get("secret"));
    this.cookiePath = base.isEmpty() ? "/" : base;
    this.homePath = base + "/";
    this.asksForToken = first instanceof Map<?, ?> m && m.containsKey("token");
    this.perAddress = new Throttle(store, "address", 10);
    this.perAccount = new Throttle(store, "account", 50);
    this.codeTries = new Throttle(store, "code", 5);
    this.confirmTries = new Throttle(store, "confirm", 5);
    this.rechecks = new Throttle(store, "recheck", 10);
  }

  public Accounts accounts() {
    return accounts;
  }

  /** A random one-time code, such as the one a server prints to unlock its first account. */
  public static String setupCode() {
    return Crypto.base64url(Crypto.randomBytes(9));
  }

  private long now() {
    return now.getAsLong();
  }

  private String homeOrigin() {
    return home == null ? null : home.get();
  }

  private boolean isOpen() {
    return "open".equals(first);
  }

  private boolean isLocked() {
    return "locked".equals(first);
  }

  public boolean hasAccount() {
    existing = existing || accounts.count() > 0;
    return existing;
  }

  private static String readCookie(Request request, String name) {
    String header = request.headers().get("cookie");
    for (String part : (header == null ? "" : header).split(";", -1)) {
      String[] pieces = Js.trim(part).split("=", -1);
      if (pieces[0].equals(name)) {
        return String.join("=", java.util.Arrays.asList(pieces).subList(1, pieces.length));
      }
    }
    return "";
  }

  private static boolean isSecure(Request request) {
    return new Url(request.url()).protocol.equals("https:")
        || "https".equals(request.headers().get("x-forwarded-proto"));
  }

  /** An error the dashboard words in its own language, as the routes send them. */
  private static Response coded(String error, String code, int status, Map<String, Object> params) {
    Map<String, Object> body = Json.object("error", error, "code", code);
    if (params != null) {
      body.put("params", new LinkedHashMap<>(params));
    }
    return new Response(
        Json.stringify(body),
        status,
        Headers.of(
            "content-type",
            "application/json; charset=utf-8",
            "cache-control",
            "no-store",
            "x-content-type-options",
            "nosniff"));
  }

  private static Response coded(String error, String code, int status) {
    return coded(error, code, status, null);
  }

  private static String esc(String s) {
    return s.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("\"", "&quot;")
        .replace("'", "&#39;");
  }

  /**
   * Only a path on this install, so a sign-in can never send someone elsewhere. Browsers drop tabs
   * and newlines from a URL and read a backslash as a slash, so "/\t/evil.example" would leave;
   * anything with those is refused outright, and what is left must resolve to this origin.
   */
  public String safeNext(String value) {
    if (value == null
        || value.isEmpty()
        || !value.startsWith("/")
        || UNSAFE.matcher(value).find()) {
      return homePath;
    }
    Url url = Url.parse(value, "http://runlight.invalid");
    return url != null && url.origin().equals("http://runlight.invalid")
        ? url.pathname + url.search + url.hash
        : homePath;
  }

  /**
   * The signed-in user, or null.
   *
   * @throws IllegalArgumentException for a session cookie decodeURIComponent cannot read, as it
   *     throws a URIError in TypeScript
   */
  public Map<String, Object> signedIn(Request request) {
    String value = readCookie(request, Accounts.SESSION_COOKIE);
    if (value.isEmpty()) {
      return null;
    }
    String decoded = Js.decodeURIComponent(value);
    if (decoded == null) {
      throw new IllegalArgumentException("URI malformed");
    }
    return accounts.fromSession(decoded, now());
  }

  private void dropTokensOf(String id) {
    for (Map<String, Object> setting : store.settingsStartingWith(MADE_BY)) {
      if (!id.equals(setting.get("value"))) {
        continue;
      }
      String key = (String) setting.get("key");
      store.deleteToken(key.substring(MADE_BY.length()));
      store.setSetting(key, null);
    }
  }

  private String sessionCookie(Request request, String value, long maxAge) {
    return Accounts.SESSION_COOKIE
        + "="
        + Js.encodeURIComponent(value)
        + "; Path="
        + cookiePath
        + "; HttpOnly; SameSite=Lax; Max-Age="
        + maxAge
        + (isSecure(request) ? "; Secure" : "");
  }

  private String freshSession(Request request, Map<String, Object> user, long at) {
    return sessionCookie(request, accounts.sessionFor(user, at), Accounts.SESSION_MS / 1000);
  }

  /**
   * The redirect after signing in: a session, and the mark that this browser has signed in to the
   * account.
   */
  private Response signedInTo(Request request, Map<String, Object> user, String next) {
    Headers headers = Headers.of("location", next, "cache-control", "no-store");
    headers.append("set-cookie", freshSession(request, user, now()));
    headers.append(
        "set-cookie",
        DEVICE_COOKIE
            + "="
            + Js.encodeURIComponent(accounts.deviceFor(user))
            + "; Path="
            + cookiePath
            + "; HttpOnly; SameSite=Lax; Max-Age="
            + (365 * 86_400)
            + (isSecure(request) ? "; Secure" : ""));
    return new Response("", 303, headers);
  }

  private static Response html(String body, int status) {
    return new Response(
        body,
        status,
        Headers.of(
            "content-type",
            "text/html; charset=utf-8",
            "cache-control",
            "no-store",
            "content-security-policy",
            CSP,
            "x-frame-options",
            "DENY",
            "referrer-policy",
            "same-origin"));
  }

  private static Response html(String body) {
    return html(body, 200);
  }

  /** A 303 to a location, with extra header pairs. */
  private static Response redirect(String location, String... extra) {
    Headers headers = Headers.of("location", location, "cache-control", "no-store");
    for (int i = 0; i + 1 < extra.length; i += 2) {
      headers.set(extra[i], extra[i + 1]);
    }
    return new Response("", 303, headers);
  }

  /** JSON with extra header pairs. */
  private static Response reply(Object body, int status, String... extra) {
    Headers headers =
        Headers.of("content-type", "application/json; charset=utf-8", "cache-control", "no-store");
    for (int i = 0; i + 1 < extra.length; i += 2) {
      headers.set(extra[i], extra[i + 1]);
    }
    return new Response(Json.stringify(body), status, headers);
  }

  private static Response reply(Object body) {
    return reply(body, 200);
  }

  private static Map<String, Object> person(Map<String, Object> u) {
    return Json.object(
        "id", u.get("id"),
        "email", u.get("email"),
        "role", u.get("role"),
        "createdAt", u.get("createdAt"),
        "twoFactor", u.get("twoFactor"),
        "recoveryLeft", u.get("recoveryLeft"));
  }

  private static List<Object> people(List<Map<String, Object>> users) {
    List<Object> out = new ArrayList<>();
    for (Map<String, Object> u : users) {
      out.add(person(u));
    }
    return out;
  }

  private static Map<String, Object> inviteView(Map<String, Object> i) {
    return Json.object(
        "id", i.get("id"),
        "email", i.get("email"),
        "role", i.get("role"),
        "invitedBy", i.get("invitedBy"),
        "createdAt", i.get("createdAt"),
        "expiresAt", i.get("expiresAt"));
  }

  /** The media type of a request's body, as a cross-site form cannot send application/json. */
  private static String mediaType(Request request) {
    String header = request.headers().get("content-type");
    return Js.lower(Js.trim((header == null ? "" : header).split(";", -1)[0]));
  }

  /** A JSON body by its media type, which a cross-site form cannot send. */
  private static Map<String, Object> body(Request request) {
    if (!mediaType(request).equals("application/json")) {
      return null;
    }
    Json.Parsed parsed = Json.tryParse(request.text());
    return parsed.ok() ? Js.map(parsed.value()) : null;
  }

  /** {@code String(input[field] ?? "")}. */
  private static String field(Map<String, Object> input, String field) {
    Object value = Js.get(input, field);
    return value == null || value == Json.UNDEFINED ? "" : Js.string(value);
  }

  private static String formValue(SearchParams form, String name) {
    String value = form.get(name);
    return value == null ? "" : value;
  }

  /** The first account's gate: what the setup form must carry. */
  private boolean setupOk(String given) {
    if (isOpen()) {
      return true;
    }
    if (!(first instanceof Map<?, ?> gate)) {
      return false;
    }
    Object expected = gate.get("code") != null ? gate.get("code") : gate.get("token");
    return Crypto.sameText(given, expected == null ? "" : Js.string(expected));
  }

  /** Why there is no setup form. */
  private Response setupLocked() {
    return html(
        isLocked() ? Pages.setupNeedsTokenPage(base) : Pages.setupLockedPage(base, setupWhere),
        403);
  }

  /**
   * Emails an invite through the mail service when there is one. The link always comes back too,
   * for the inviter to pass on another way.
   */
  private Map<String, Object> sendInvite(Request request, Map<String, Object> invite, String code) {
    String given = homeOrigin();
    String origin = given != null ? given : new Url(request.url()).origin();
    String link = origin + base + "/invite?code=" + code;
    String host = new Url(origin).host();
    String what = Pages.roleText((String) invite.get("role"));
    String invitedBy = (String) invite.get("invitedBy");
    if (rl.mailSettings() == null) {
      return Json.object("link", link, "emailed", false);
    }
    try {
      rl.sendMail(
          Json.object(
              "to",
              invite.get("email"),
              "subject",
              invitedBy + " invited you to Runlight",
              "text",
              invitedBy
                  + " invited you to the Runlight at "
                  + host
                  + " as "
                  + what
                  + ".\n\nChoose a password to join:\n"
                  + link
                  + "\n\nThe link works for seven days.\n",
              "html",
              "<div style=\"font:15px/1.6 -apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;color:#111827;max-width:480px\"><p>"
                  + esc(invitedBy)
                  + " invited you to the Runlight at "
                  + esc(host)
                  + " as "
                  + what
                  + ".</p><p><a href=\""
                  + esc(link)
                  + "\" style=\"display:inline-block;padding:10px 18px;border-radius:8px;background:#111827;color:#ffffff;text-decoration:none;font-weight:600\">Choose a password and join</a></p><p style=\"color:#6b7280;font-size:13px\">The link works for seven days. If you were not expecting this, you can ignore it.</p></div>"));
      return Json.object("link", link, "emailed", true);
    } catch (RuntimeException error) {
      // The mail service's code and its details too, so the dashboard can say what went wrong in
      // its own language. Only an error with a code of its own has one, as TypeScript reads
      // `typeof failed.code === "string"`.
      String message = error.getMessage();
      Map<String, Object> out =
          Json.object("link", link, "emailed", false, "mailError", message == null ? "" : message);
      if (error instanceof CodedError failed && failed.code() != null) {
        out.put("mailCode", failed.code());
        out.put(
            "mailParams",
            failed.params() == null ? new LinkedHashMap<>() : new LinkedHashMap<>(failed.params()));
      }
      return out;
    }
  }

  /**
   * Emails a sign-in link to an account held up by others' failed tries, at most once a minute.
   * Only to the install's own address, never the Host of the request, so without one known there is
   * no link.
   */
  private boolean sendLink(Map<String, Object> user, String next) {
    String origin = homeOrigin();
    if (origin == null || origin.isEmpty()) {
      return false;
    }
    String key = LINK_SENT + user.get("id");
    String sent = store.setting(key);
    if (now() - Js.toNumber(sent == null ? 0L : sent) < 60_000) {
      return true;
    }
    store.setSetting(key, Long.toString(now()));
    Map<String, String> query = new LinkedHashMap<>();
    query.put("ticket", accounts.linkFor(user, now()));
    query.put("next", next);
    String link = origin + base + "/login/link?" + new SearchParams(query);
    String host = new Url(origin).host();
    rl.sendMail(
        Json.object(
            "to",
            user.get("email"),
            "subject",
            "Sign in to Runlight",
            "text",
            "Someone, most likely you, signed in to Runlight at "
                + host
                + " with your password while your account was held up by too many failed tries.\n\nSign in with this link within fifteen minutes:\n"
                + link
                + "\n\nIf this was not you, change your password, since someone knows it.\n",
            "html",
            "<div style=\"font:15px/1.6 -apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;color:#111827;max-width:480px\"><p>Someone, most likely you, signed in to Runlight at "
                + esc(host)
                + " with your password while your account was held up by too many failed tries.</p><p><a href=\""
                + esc(link)
                + "\" style=\"display:inline-block;padding:10px 18px;border-radius:8px;background:#111827;color:#ffffff;text-decoration:none;font-weight:600\">Sign in</a></p><p style=\"color:#6b7280;font-size:13px\">The link works for fifteen minutes. If this was not you, change your password, since someone knows it.</p></div>"));
    return true;
  }

  private Map<String, Object> setupOpts(String code, String error, String email) {
    return Json.object(
        "code", asksForToken ? "" : code, "askCode", asksForToken, "error", error, "email", email);
  }

  private Response pages(Request request, String path, Map<String, Object> context) {
    Url url = new Url(request.url());
    SearchParams query = url.searchParams();
    String method = request.method();
    if (path.equals("/auth.css")) {
      return new Response(
          Pages.AUTH_CSS,
          200,
          Headers.of(
              "content-type", "text/css; charset=utf-8", "cache-control", "public, max-age=3600"));
    }
    if (path.equals("/auth.js")) {
      return new Response(
          Pages.AUTH_JS,
          200,
          Headers.of(
              "content-type",
              "application/javascript; charset=utf-8",
              "cache-control",
              "public, max-age=3600"));
    }

    if (path.equals("/setup")) {
      if (hasAccount()) {
        return redirect(base + "/login");
      }
      if (method.equals("GET")) {
        String code = query.get("code") == null ? "" : query.get("code");
        if (isLocked()) {
          return setupLocked();
        }
        // The app's token is typed in; the server's code comes in the link it printed.
        if (asksForToken || isOpen()) {
          return html(Pages.setupPage(base, Json.object("code", "", "askCode", asksForToken)));
        }
        return setupOk(code)
            ? html(Pages.setupPage(base, Json.object("code", code)))
            : setupLocked();
      }
      if (method.equals("POST")) {
        SearchParams form = new SearchParams(request.text());
        String code = formValue(form, "code");
        if (!setupOk(code)) {
          if (asksForToken) {
            return html(
                Pages.setupPage(
                    base,
                    Json.object(
                        "code",
                        "",
                        "askCode",
                        true,
                        "error",
                        "That is not this app's RUNLIGHT_TOKEN.",
                        "email",
                        formValue(form, "email"))),
                403);
          }
          return setupLocked();
        }
        // Asked twice, since a typo here would lock the first owner out.
        if (!formValue(form, "password").equals(formValue(form, "again"))) {
          return html(
              Pages.setupPage(
                  base,
                  setupOpts(code, "The two passwords are not the same.", formValue(form, "email"))),
              400);
        }
        try {
          Map<String, Object> user =
              accounts.setPassword(formValue(form, "email"), formValue(form, "password"), now());
          existing = true;
          return redirect(homePath, "set-cookie", freshSession(request, user, now()));
        } catch (AccountError error) {
          return html(
              Pages.setupPage(base, setupOpts(code, error.getMessage(), formValue(form, "email"))),
              400);
        }
      }
    }

    if (path.equals("/login")) {
      if (!hasAccount()) {
        if (isLocked()) {
          return setupLocked();
        }
        return isOpen() || asksForToken ? redirect(base + "/setup") : setupLocked();
      }
      if (method.equals("GET")) {
        return html(
            Pages.loginPage(
                base, Json.object("next", safeNext(query.get("next")), "forgot", forgot)));
      }
      if (method.equals("POST")) {
        return login(request, context);
      }
    }

    // The link a locked account's owner is emailed: the code step with two-factor on, else
    // straight in.
    if (path.equals("/login/link") && method.equals("GET")) {
      String next = safeNext(query.get("next"));
      Map<String, Object> user =
          accounts.fromLink(query.get("ticket") == null ? "" : query.get("ticket"), now());
      if (user == null) {
        return html(
            Pages.loginPage(
                base,
                Json.object(
                    "error",
                    "That sign-in link has run out. Sign in again.",
                    "next",
                    next,
                    "forgot",
                    forgot)),
            410);
      }
      if (Boolean.TRUE.equals(user.get("twoFactor"))) {
        return html(
            Pages.codePage(
                base, Json.object("pending", accounts.pendingFor(user, now()), "next", next)));
      }
      return signedInTo(request, user, next);
    }

    if (path.equals("/login/code") && method.equals("POST")) {
      SearchParams form = new SearchParams(request.text());
      String next = safeNext(form.get("next"));
      Map<String, Object> pending = accounts.fromPending(formValue(form, "pending"), now());
      if (pending == null) {
        return redirect(base + "/login?next=" + Js.encodeURIComponent(next));
      }
      Map<String, Object> user = Js.map(pending.get("user"));
      String id = (String) user.get("id");
      // Counted before the check, so a burst cannot get past five.
      if (!codeTries.take(id, now())) {
        return html(
            Pages.codePage(
                base,
                Json.object(
                    "pending",
                    formValue(form, "pending"),
                    "next",
                    next,
                    "error",
                    "Too many tries. Wait fifteen minutes and try again.")),
            429);
      }
      if (!Boolean.TRUE.equals(pending.get("real"))
          || !accounts.checkSecondFactor(id, formValue(form, "code"), now())) {
        return html(
            Pages.codePage(
                base,
                Json.object(
                    "pending",
                    formValue(form, "pending"),
                    "next",
                    next,
                    "error",
                    "That code is not right. Check the time on your phone, or use a recovery code.")),
            401);
      }
      codeTries.clear(id);
      return signedInTo(request, user, next);
    }

    if (path.equals("/logout")) {
      return redirect(base + "/login", "set-cookie", sessionCookie(request, "", 0));
    }

    if (path.equals("/invite")) {
      if (method.equals("GET")) {
        String code = query.get("code") == null ? "" : query.get("code");
        Map<String, Object> invite = accounts.inviteByCode(code, now());
        return invite != null
            ? html(
                Pages.invitePage(
                    base,
                    Json.object(
                        "code",
                        code,
                        "email",
                        invite.get("email"),
                        "role",
                        invite.get("role"),
                        "host",
                        url.host())))
            : html(Pages.inviteGonePage(base), 410);
      }
      if (method.equals("POST")) {
        SearchParams form = new SearchParams(request.text());
        String code = formValue(form, "code");
        Map<String, Object> invite = accounts.inviteByCode(code, now());
        if (invite == null) {
          return html(Pages.inviteGonePage(base), 410);
        }
        if (!formValue(form, "password").equals(formValue(form, "again"))) {
          return inviteAgain(invite, code, url, "The two passwords are not the same.");
        }
        try {
          Map<String, Object> user =
              accounts.acceptInvite(code, formValue(form, "password"), now());
          existing = true;
          return redirect(homePath, "set-cookie", freshSession(request, user, now()));
        } catch (AccountError error) {
          return inviteAgain(invite, code, url, error.getMessage());
        }
      }
    }
    return null;
  }

  private Response inviteAgain(Map<String, Object> invite, String code, Url url, String error) {
    return html(
        Pages.invitePage(
            base,
            Json.object(
                "code",
                code,
                "email",
                invite.get("email"),
                "role",
                invite.get("role"),
                "host",
                url.host(),
                "error",
                error)),
        400);
  }

  private Response login(Request request, Map<String, Object> context) {
    SearchParams form = new SearchParams(request.text());
    String email = formValue(form, "email");
    String password = formValue(form, "password");
    String next = safeNext(form.get("next"));
    String account = Js.lower(Js.trim(email));
    String ip = rl.clientIp(request, context);
    String pair = account + "\n" + (ip != null && !ip.isEmpty() ? ip : "unknown");
    if (!perAddress.take(pair, now())) {
      return loginAgain("Too many tries. Wait fifteen minutes and try again.", email, next, 429);
    }
    // A browser that signed in to the account before is never held up by others' failures.
    Map<String, Object> known = accounts.byEmail(account);
    boolean trusted =
        known != null && accounts.trustsDevice(readCookie(request, DEVICE_COOKIE), known);
    boolean over = !trusted && !perAccount.take(account, now());
    // Past the account's limit, a right password and a wrong one get the same answer, so guessing
    // from many addresses learns nothing, and the owner still gets in. With two-factor on, both
    // reach the code step, where a wrong password's ticket never passes. Without it, a right
    // password emails a sign-in link.
    if (over && !(known != null && Boolean.TRUE.equals(known.get("twoFactor")))) {
      String origin = homeOrigin();
      if (rl.mailSettings() == null || origin == null || origin.isEmpty()) {
        return loginAgain("Too many tries. Wait fifteen minutes and try again.", email, next, 429);
      }
      Map<String, Object> user = accounts.signIn(email, password);
      if (user != null) {
        // Sent once the answer is out, as TypeScript does, so a right password takes no longer to
        // answer than a wrong one.
        rl.later(
            () -> {
              try {
                sendLink(user, next);
              } catch (RuntimeException error) {
                LOG.log(
                    Level.SEVERE, "Runlight: could not send a sign-in link " + error.getMessage());
              }
            });
      }
      return loginAgain(
          "Too many tries for this account. If the password was right, a link to sign in is on its way to its email address.",
          email,
          next,
          429);
    }
    Map<String, Object> user = accounts.signIn(email, password);
    if (user == null) {
      if (over && known != null) {
        return html(
            Pages.codePage(
                base, Json.object("pending", accounts.decoyFor(known, now()), "next", next)));
      }
      return loginAgain("That email and password do not match an account.", email, next, 401);
    }
    perAddress.clear(pair);
    if (!over && !trusted) {
      perAccount.forgive(account);
    }
    // With two-factor on, the password only earns the second step.
    if (Boolean.TRUE.equals(user.get("twoFactor"))) {
      return html(
          Pages.codePage(
              base, Json.object("pending", accounts.pendingFor(user, now()), "next", next)));
    }
    return signedInTo(request, user, next);
  }

  private Response loginAgain(String error, String email, String next, int status) {
    return html(
        Pages.loginPage(
            base, Json.object("error", error, "email", email, "next", next, "forgot", forgot)),
        status);
  }

  /**
   * The password asked again before a change, with its own few tries; null when it checks out, else
   * the answer to send.
   */
  private Response recheck(
      Map<String, Object> user,
      long at,
      Map<String, Object> input,
      String fieldName,
      String wrong,
      String wrongCode) {
    String id = (String) user.get("id");
    if (!rechecks.take(id, at)) {
      return coded("Too many tries. Wait fifteen minutes and try again.", "too_many_tries", 429);
    }
    if (accounts.signIn((String) user.get("email"), field(input, fieldName)) == null) {
      return coded(wrong, wrongCode, 400);
    }
    rechecks.forgive(id);
    return null;
  }

  private static String roleOf(Object value) {
    return value instanceof String s
            && (s.equals("admin") || s.equals("member") || s.equals("viewer"))
        ? s
        : null;
  }

  /** Your own account, and for the owner and admins, everyone else's. */
  private Response api(Request request, String path) {
    Map<String, Object> user = signedIn(request);
    if (user == null) {
      return coded("Sign in first", "sign_in", 401);
    }
    long at = now();
    String method = request.method();
    String userId = (String) user.get("id");
    String role = (String) user.get("role");
    // Writes must be JSON, which a form on another page cannot send, even those with no body.
    if (method.equals("POST") && !mediaType(request).equals("application/json")) {
      return coded("Send JSON", "send_json", 415);
    }
    if (path.equals("/api/account") && method.equals("GET")) {
      return reply(Json.object("account", person(user)));
    }
    if (path.equals("/api/account/password") && method.equals("POST")) {
      Map<String, Object> input = body(request);
      if (input == null) {
        return coded("Send JSON", "send_json", 415);
      }
      Response refused =
          recheck(
              user,
              at,
              input,
              "current",
              "Your current password is not right",
              "password_current_wrong");
      if (refused != null) {
        return refused;
      }
      try {
        Map<String, Object> updated =
            accounts.setPassword((String) user.get("email"), field(input, "next"), at);
        // The new password ends every other sign-in; this browser gets a fresh one.
        return reply(
            Json.object("ok", true), 200, "set-cookie", freshSession(request, updated, at));
      } catch (AccountError error) {
        return coded(error.getMessage(), error.code(), 400, error.params());
      }
    }
    // Two-factor: turning it on, confirming the first code, new recovery codes, and turning it
    // off. Each change asks for the password again, so a browser left signed in cannot quietly
    // change it.
    if (path.startsWith("/api/account/2fa") && method.equals("POST")) {
      Map<String, Object> input = body(request);
      if (input == null) {
        return coded("Send JSON", "send_json", 415);
      }
      String action = path.substring("/api/account/2fa".length());
      // Confirming asks for no password, so it has its own few tries, after which the set-up
      // starts again.
      if (action.equals("/confirm")) {
        if (!confirmTries.take(userId, at)) {
          accounts.cancelTwoFactorSetup(userId);
          return coded(
              "Too many wrong codes. Start turning on two-factor sign-in again.",
              "twofactor_restart",
              429);
        }
        List<String> codes =
            accounts.confirmTwoFactor(
                userId, SPACES.matcher(field(input, "code")).replaceAll(""), at);
        if (codes == null) {
          return coded(
              "That code is not right. Check the time on your phone and try the next one.",
              "code_wrong",
              400);
        }
        confirmTries.clear(userId);
        // Turning it on signs out every other browser; this one gets a new session.
        Map<String, Object> updated = accounts.byId(userId);
        return reply(
            Json.object("recovery", new ArrayList<Object>(codes)),
            200,
            "set-cookie",
            freshSession(request, updated, at));
      }
      Response refused =
          recheck(user, at, input, "password", "Your password is not right", "password_wrong");
      if (refused != null) {
        return refused;
      }
      if (action.equals("/start")) {
        confirmTries.clear(userId);
        String secret = accounts.startTwoFactor(userId);
        return reply(
            Json.object(
                "secret",
                secret,
                "uri",
                Crypto.otpauthUri(
                    secret, (String) user.get("email"), new Url(request.url()).host())));
      }
      if (action.equals("/recovery")) {
        if (!Boolean.TRUE.equals(user.get("twoFactor"))) {
          return coded("Turn on two-factor sign-in first", "twofactor_off", 400);
        }
        return reply(
            Json.object("recovery", new ArrayList<Object>(accounts.newRecoveryCodes(userId))));
      }
      if (action.equals("/disable")) {
        accounts.disableTwoFactor(userId);
        // Sessions follow two-factor's state, so this browser gets a new one and stays signed in.
        Map<String, Object> updated = accounts.byId(userId);
        return reply(
            Json.object("ok", true), 200, "set-cookie", freshSession(request, updated, at));
      }
      return coded("Not found", "not_found", 404);
    }
    if (!role.equals("owner") && !role.equals("admin")) {
      return coded("Only the owner or an admin can manage people", "people_owner", 403);
    }
    // The owner or an admin can turn off someone else's two-factor, for a coworker who lost both
    // phone and recovery codes, though never the owner's. It asks for their password like every
    // other two-factor change, and their own goes through Account.
    Matcher reset = RESET_2FA.matcher(path);
    if (reset.matches() && method.equals("DELETE")) {
      String target = reset.group(1);
      if (target.equals(userId)) {
        return coded("Turn off your own two-factor sign-in under Account", "twofactor_self", 400);
      }
      Map<String, Object> input = body(request);
      if (input == null) {
        return coded("Send JSON", "send_json", 415);
      }
      Response refused =
          recheck(user, at, input, "password", "Your password is not right", "password_wrong");
      if (refused != null) {
        return refused;
      }
      Map<String, Object> them = accounts.byId(target);
      if (them == null) {
        return coded("Unknown account", "unknown_account", 404);
      }
      if (them.get("role").equals("owner")) {
        return coded("Only the owner can change the owner's account", "owner_protected", 403);
      }
      accounts.disableTwoFactor(target);
      return reply(Json.object("ok", true));
    }
    // The owner hands ownership to an admin and becomes an admin, after typing their password
    // again.
    Matcher handOver = HAND_OVER.matcher(path);
    if (handOver.matches() && method.equals("POST")) {
      if (!role.equals("owner")) {
        return coded("Only the owner can hand over ownership", "owner_hand_over", 403);
      }
      Map<String, Object> input = body(request);
      if (input == null) {
        return coded("Send JSON", "send_json", 415);
      }
      Response refused =
          recheck(user, at, input, "password", "Your password is not right", "password_wrong");
      if (refused != null) {
        return refused;
      }
      try {
        accounts.handOver(userId, handOver.group(1));
        return reply(Json.object("people", people(accounts.list())));
      } catch (AccountError error) {
        return coded(
            error.getMessage(),
            error.code(),
            error.code().equals("unknown_account") ? 404 : 400,
            error.params());
      }
    }
    // Nobody is invited as, or made, the owner: there is one, and they hand it over themselves.
    if (path.equals("/api/people") && method.equals("GET")) {
      List<Object> invites = new ArrayList<>();
      for (Map<String, Object> invite : accounts.invites(at)) {
        invites.add(inviteView(invite));
      }
      return reply(Json.object("people", people(accounts.list()), "invites", invites));
    }
    if (path.equals("/api/people") && method.equals("POST")) {
      Map<String, Object> input = body(request);
      if (input == null) {
        return coded("Send JSON", "send_json", 415);
      }
      String given = roleOf(Js.get(input, "role"));
      if (given == null) {
        return coded("Pick admin, member, or viewer", "role_needed", 400);
      }
      String email = Js.lower(Js.trim(field(input, "email")));
      if (accounts.byEmail(email) != null) {
        return coded(
            email + " already has an account", "account_exists", 409, Json.object("email", email));
      }
      try {
        Map<String, Object> made = accounts.invite(email, given, (String) user.get("email"), at);
        Map<String, Object> invite = Js.map(made.get("invite"));
        Map<String, Object> out = Json.object("invite", inviteView(invite));
        out.putAll(sendInvite(request, invite, (String) made.get("code")));
        return reply(out, 201);
      } catch (AccountError error) {
        return coded(error.getMessage(), error.code(), 400, error.params());
      }
    }
    Matcher inviteMatch = INVITE.matcher(path);
    if (inviteMatch.matches()) {
      String inviteId = inviteMatch.group(1);
      boolean resend = inviteMatch.group(2) != null && !inviteMatch.group(2).isEmpty();
      if (method.equals("DELETE") && !resend) {
        return accounts.cancelInvite(inviteId)
            ? reply(Json.object("ok", true))
            : coded("Unknown invite", "unknown_invite", 404);
      }
      if (method.equals("POST") && resend) {
        Map<String, Object> old = null;
        for (Map<String, Object> one : accounts.invites(at)) {
          if (one.get("id").equals(inviteId)) {
            old = one;
            break;
          }
        }
        if (old == null) {
          return coded("Unknown invite", "unknown_invite", 404);
        }
        // A new link replaces the old one, which stops working.
        Map<String, Object> made =
            accounts.invite(
                (String) old.get("email"),
                (String) old.get("role"),
                (String) user.get("email"),
                at);
        Map<String, Object> invite = Js.map(made.get("invite"));
        Map<String, Object> out = Json.object("invite", inviteView(invite));
        out.putAll(sendInvite(request, invite, (String) made.get("code")));
        return reply(out);
      }
    }
    Matcher match = PERSON.matcher(path);
    if (match.matches() && (method.equals("PATCH") || method.equals("DELETE"))) {
      String target = match.group(1);
      try {
        if (method.equals("DELETE")) {
          if (target.equals(userId)) {
            return coded("You cannot remove yourself", "remove_self", 400);
          }
          accounts.remove(target);
          // The tokens they made, and the apps they connected, stop working with them.
          dropTokensOf(target);
          return reply(Json.object("ok", true));
        }
        Map<String, Object> input = body(request);
        if (input == null) {
          return coded("Send JSON", "send_json", 415);
        }
        String given = roleOf(Js.get(input, "role"));
        if (given == null) {
          return coded("Pick admin, member, or viewer", "role_needed", 400);
        }
        Map<String, Object> changed = accounts.setRole(target, given);
        // A viewer changes nothing, so the tokens they made before go too.
        if (given.equals("viewer")) {
          dropTokensOf(target);
        }
        return reply(Json.object("person", person(changed)));
      } catch (AccountError error) {
        int status =
            error.code().equals("unknown_account")
                ? 404
                : error.code().equals("owner_protected") ? 403 : 400;
        return coded(error.getMessage(), error.code(), status, error.params());
      }
    }
    return coded("Not found", "not_found", 404);
  }

  /**
   * What a signed-in person may do: everything (owner and admin, {@link Boolean#TRUE}), "member",
   * "read" (viewer), or nothing ({@link Boolean#FALSE}).
   */
  public Object access(Request request) {
    Map<String, Object> user = signedIn(request);
    if (user == null) {
      return false;
    }
    // A member changes everything but the install-wide controls; a viewer reads every site and
    // changes nothing.
    Object role = user.get("role");
    if (role.equals("owner") || role.equals("admin")) {
      return true;
    }
    return role.equals("member") ? "member" : "read";
  }

  /** The signed-in account's id, or null. */
  public String accountOf(Request request) {
    Map<String, Object> user = signedIn(request);
    return user == null ? null : (String) user.get("id");
  }

  /**
   * Notes who made a token. A viewer makes no tokens; someone removed or made a viewer since
   * allowing an app gets none for it, and false takes the token back.
   */
  public boolean tokenMade(Map<String, Object> token, String by) {
    Map<String, Object> maker = accounts.byId(by);
    Object role = maker == null ? null : maker.get("role");
    if (role == null || role.equals("viewer")) {
      return false;
    }
    store.setSetting(MADE_BY + token.get("id"), by);
    return true;
  }

  /** As {@link #handle(Request, String, Map)} with no context. */
  public Response handle(Request request, String path) {
    return handle(request, path, Map.of());
  }

  /**
   * Answers an account page or API request at a path under the base, or null for anything else.
   *
   * @param context what the server knows of the request, such as {ip}
   */
  public Response handle(Request request, String path, Map<String, Object> context) {
    if (path.equals("/api/account")
        || path.startsWith("/api/account/")
        || path.equals("/api/people")
        || path.startsWith("/api/people/")
        || path.startsWith("/api/invites/")) {
      return api(request, path);
    }
    Response page = pages(request, path, context);
    if (page != null) {
      return page;
    }
    // The dashboard itself: straight to sign-in, or to setting up the first account.
    if ((path.equals("/") || path.isEmpty())
        && request.method().equals("GET")
        && signedIn(request) == null) {
      if (!hasAccount()) {
        return isOpen() || asksForToken ? redirect(base + "/setup") : setupLocked();
      }
      String search = new Url(request.url()).search;
      return redirect(
          base
              + "/login"
              + (search.isEmpty() ? "" : "?next=" + Js.encodeURIComponent(homePath + search)));
    }
    return null;
  }
}
