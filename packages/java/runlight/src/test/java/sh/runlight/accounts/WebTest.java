package sh.runlight.accounts;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.LongSupplier;
import java.util.function.Supplier;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.junit.jupiter.api.Test;
import sh.runlight.CodedError;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.http.Headers;
import sh.runlight.http.Request;
import sh.runlight.http.Response;
import sh.runlight.http.SearchParams;
import sh.runlight.http.Url;
import sh.runlight.store.SqlStore;
import sh.runlight.store.Stores;

/**
 * Accounts on the web, through Web.handle() as the routes call it, with a stand-in for the
 * Runlight. The cases follow accounts.test.ts and the accounts conformance scenario; the same flows
 * through the real routes are in RoutesAccountsTest, which runs once the core is here.
 */
class WebTest {
  private static final long NOW = 1_791_288_000_000L;
  private static final String BASE = "/runlight";
  private static final String FORGOT = "https://runlight.sh/docs/configuration/#accounts";

  private long now = NOW;
  private StandIn rl;

  private Web web() {
    return web(Json.object("token", "app-token"), null);
  }

  private Web web(Object first) {
    return web(first, null);
  }

  private Web web(Object first, String home) {
    SqlStore store = Stores.sqlite(":memory:");
    store.migrate();
    rl = new StandIn(store);
    Map<String, Object> options =
        Json.object(
            "runlight", rl,
            "secret", "k".repeat(64),
            "base", BASE,
            "now", (LongSupplier) () -> now,
            "firstAccount", first,
            "forgot", FORGOT);
    if (home != null) {
      options.put("home", (Supplier<String>) () -> home);
    }
    return new Web(options);
  }

  private static Request req(String path) {
    return req(path, "GET", Map.of(), "");
  }

  private static Request req(String path, String method, Map<String, String> headers) {
    return req(path, method, headers, "");
  }

  private static Request req(String path, String method, Map<String, String> headers, String body) {
    return new Request("https://example.com/runlight" + path, method, Headers.of(headers), body);
  }

  private static String encode(String... pairs) {
    Map<String, String> fields = new LinkedHashMap<>();
    for (int i = 0; i + 1 < pairs.length; i += 2) {
      fields.put(pairs[i], pairs[i + 1]);
    }
    return new SearchParams(fields).toString();
  }

  private static Request form(String path, String... pairs) {
    return formWith("", path, pairs);
  }

  private static Request formWith(String cookie, String path, String... pairs) {
    Map<String, String> headers = new LinkedHashMap<>();
    headers.put("content-type", "application/x-www-form-urlencoded");
    if (!cookie.isEmpty()) {
      headers.put("cookie", cookie);
    }
    return req(path, "POST", headers, encode(pairs));
  }

  private static Request json(String cookie, String method, String path, Object body) {
    return req(
        path,
        method,
        Map.of("cookie", cookie, "content-type", "application/json"),
        body == null ? "" : Json.stringify(body));
  }

  private static Request json(String cookie, String method, String path) {
    return json(cookie, method, path, null);
  }

  private static Response handle(Web web, Request request) {
    String path = new Url(request.url()).pathname.substring(BASE.length());
    return web.handle(request, path.isEmpty() ? "/" : path);
  }

  private static String cookieOf(Response response) {
    List<String> cookies = response.headers().getSetCookie();
    return cookies.isEmpty() ? "" : cookies.get(0).split(";", -1)[0];
  }

  private static Request withCookie(String cookie) {
    return req("/", "GET", Map.of("cookie", cookie));
  }

  private String owner(Web web) {
    Response made =
        handle(
            web,
            form(
                "/setup",
                "code",
                "app-token",
                "email",
                "jon@example.com",
                "password",
                "a long password",
                "again",
                "a long password"));
    return cookieOf(made);
  }

  private static Map<String, Object> parse(Response response) {
    return Js.map(Json.parse(response.text()));
  }

  @Test
  void anAppMakesItsFirstAccountWithItsToken() {
    Web web = web();
    Response start = handle(web, req("/"));
    assertEquals(303, start.status());
    assertEquals("/runlight/setup", start.headers().get("location"));
    assertEquals("no-store", start.headers().get("cache-control"));
    Response page = handle(web, req("/setup"));
    assertEquals(Pages.setupPage(BASE, Json.object("code", "", "askCode", true)), page.text());
    assertEquals(
        "default-src 'none'; script-src 'self'; style-src 'self'; img-src data:; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
        page.headers().get("content-security-policy"));
    assertTrue(page.text().contains("href=\"/runlight/auth.css\""));

    Response wrong =
        handle(
            web,
            form(
                "/setup",
                "code",
                "guess",
                "email",
                "jon@example.com",
                "password",
                "a long password",
                "again",
                "a long password"));
    assertEquals(403, wrong.status());
    assertEquals(
        Pages.setupPage(
            BASE,
            Json.object(
                "code",
                "",
                "askCode",
                true,
                "error",
                "That is not this app's RUNLIGHT_TOKEN.",
                "email",
                "jon@example.com")),
        wrong.text());
    Response typo =
        handle(
            web,
            form(
                "/setup",
                "code",
                "app-token",
                "email",
                "jon@example.com",
                "password",
                "a long password",
                "again",
                "a long passwore"));
    assertEquals(400, typo.status());
    assertTrue(typo.text().contains("The two passwords are not the same."));
    Response shortOne =
        handle(
            web,
            form(
                "/setup",
                "code",
                "app-token",
                "email",
                "jon@example.com",
                "password",
                "short",
                "again",
                "short"));
    assertEquals(400, shortOne.status());
    assertTrue(shortOne.text().contains("Use a password of at least 10 characters"));

    Response made =
        handle(
            web,
            form(
                "/setup",
                "code",
                "app-token",
                "email",
                "jon@example.com",
                "password",
                "a long password",
                "again",
                "a long password"));
    assertEquals(303, made.status());
    assertEquals("/runlight/", made.headers().get("location"));
    List<String> cookie = made.headers().getSetCookie();
    assertEquals(1, cookie.size());
    assertTrue(
        cookie
            .get(0)
            .matches(
                "^runlight_session=[a-f0-9]{24}\\.\\d+\\.[A-Za-z0-9_-]{43}; Path=/runlight; HttpOnly; SameSite=Lax; Max-Age=2592000; Secure\\z"),
        cookie.get(0));
    assertEquals(
        "/runlight/login",
        handle(web, req("/setup")).headers().get("location"),
        "setup closes once there is an account");

    String owner = cookieOf(made);
    assertNull(handle(web, withCookie(owner)), "signed in, the dashboard is the routes' to answer");
    assertEquals(true, web.access(withCookie(owner)));
    assertEquals(false, web.access(req("/")));
    Response answer = handle(web, json(owner, "GET", "/api/account"));
    Map<String, Object> user = web.accounts().byEmail("jon@example.com");
    assertEquals(
        Json.stringify(
            Json.object(
                "account",
                Json.object(
                    "id",
                    user.get("id"),
                    "email",
                    "jon@example.com",
                    "role",
                    "owner",
                    "createdAt",
                    NOW,
                    "twoFactor",
                    false,
                    "recoveryLeft",
                    0))),
        answer.text());
    assertEquals("application/json; charset=utf-8", answer.headers().get("content-type"));
    assertEquals(user.get("id"), web.accountOf(withCookie(owner)));

    // Signed out, the dashboard sends you to sign in, and keeps where you were going.
    assertEquals(
        "/runlight/login?next=%2Frunlight%2F%3Fperiod%3D7d",
        handle(web, req("/?period=7d")).headers().get("location"));
    assertEquals("/runlight/login", handle(web, req("/")).headers().get("location"));
  }

  @Test
  void aServerCodeOpenAndLockedSetups() {
    String code = Web.setupCode();
    assertTrue(code.matches("[A-Za-z0-9_-]{12}"), code);
    Web web = web(Json.object("code", code));
    assertEquals(
        403,
        handle(web, req("/")).status(),
        "a server with no account and no code in the link stays shut");
    assertEquals(Pages.setupLockedPage(BASE), handle(web, req("/setup?code=nope")).text());
    assertEquals(
        Pages.setupPage(BASE, Json.object("code", code)),
        handle(web, req("/setup?code=" + code)).text());
    assertEquals(403, handle(web, req("/login")).status());
    assertEquals(
        403,
        handle(
                web,
                form(
                    "/setup",
                    "code",
                    "nope",
                    "email",
                    "jon@example.com",
                    "password",
                    "a long password",
                    "again",
                    "a long password"))
            .status());

    Web open = web("open");
    assertEquals("/runlight/setup", handle(open, req("/")).headers().get("location"));
    assertEquals("/runlight/setup", handle(open, req("/login")).headers().get("location"));
    assertFalse(handle(open, req("/setup")).text().contains("RUNLIGHT_TOKEN"));
    assertEquals(
        303,
        handle(
                open,
                form(
                    "/setup",
                    "code",
                    "",
                    "email",
                    "jon@example.com",
                    "password",
                    "a long password",
                    "again",
                    "a long password"))
            .status());

    Web locked = web("locked");
    Response shut = handle(locked, req("/setup"));
    assertEquals(403, shut.status());
    assertTrue(shut.text().contains("Set RUNLIGHT_TOKEN"));
    assertEquals(
        403,
        handle(
                locked,
                form(
                    "/setup",
                    "code",
                    "",
                    "email",
                    "jon@example.com",
                    "password",
                    "a long password",
                    "again",
                    "a long password"))
            .status());

    Response css = handle(locked, req("/auth.css"));
    assertEquals(Pages.AUTH_CSS, css.text());
    assertEquals("text/css; charset=utf-8", css.headers().get("content-type"));
    assertEquals("public, max-age=3600", css.headers().get("cache-control"));
    assertEquals(
        "application/javascript; charset=utf-8",
        handle(locked, req("/auth.js")).headers().get("content-type"));
    assertNull(handle(locked, req("/somewhere")));
  }

  @Test
  void signingInAndOutNeverLeavesTheApp() {
    Web web = web();
    owner(web);
    Response login = handle(web, req("/login?next=%2Frunlight%2F%3Fsite%3Dx"));
    assertEquals(
        Pages.loginPage(BASE, Json.object("next", "/runlight/?site=x", "forgot", FORGOT)),
        login.text());

    Response wrong =
        handle(web, form("/login", "email", "jon@example.com", "password", "a wrong password"));
    assertEquals(401, wrong.status());
    assertEquals(
        Pages.loginPage(
            BASE,
            Json.object(
                "error",
                "That email and password do not match an account.",
                "email",
                "jon@example.com",
                "next",
                "/runlight/",
                "forgot",
                FORGOT)),
        wrong.text());

    Response back =
        handle(
            web,
            form(
                "/login",
                "email",
                "JON@example.com",
                "password",
                "a long password",
                "next",
                "/runlight/?period=7d"));
    assertEquals(303, back.status());
    assertEquals("/runlight/?period=7d", back.headers().get("location"));
    List<String> cookies = back.headers().getSetCookie();
    assertEquals(
        2, cookies.size(), "a session, and the mark that this browser signed in to the account");
    assertTrue(
        cookies
            .get(1)
            .matches(
                "^runlight_device=[a-f0-9]{24}\\.[A-Za-z0-9_-]{43}; Path=/runlight; HttpOnly; SameSite=Lax; Max-Age=31536000; Secure\\z"),
        cookies.get(1));

    Response out = handle(web, req("/logout"));
    assertEquals("/runlight/login", out.headers().get("location"));
    assertEquals(
        List.of("runlight_session=; Path=/runlight; HttpOnly; SameSite=Lax; Max-Age=0; Secure"),
        out.headers().getSetCookie());

    for (String next :
        List.of(
            "//evil.example/",
            "/\\evil.example",
            "/\t/evil.example",
            "https://evil.example/",
            "",
            "runlight")) {
      assertEquals("/runlight/", web.safeNext(next), "never sent off the app: " + next);
    }
    assertEquals("/runlight/", web.safeNext(null));
    assertEquals("/runlight/x?y=1#z", web.safeNext("/runlight/a/../x?y=1#z"));
    assertEquals("/%20a", web.safeNext("/ a"));
  }

  @Test
  void invitesPeopleAndRoles() {
    Web web = web();
    String owner = owner(web);
    Response sent =
        handle(
            web,
            json(
                owner,
                "POST",
                "/api/people",
                Json.object("email", "Mo@Example.com", "role", "member")));
    assertEquals(201, sent.status());
    Map<String, Object> body = parse(sent);
    assertEquals(List.of("invite", "link", "emailed"), new ArrayList<>(body.keySet()));
    assertEquals(false, body.get("emailed"), "no mail service here, so the link is for passing on");
    Url link = new Url((String) body.get("link"));
    assertEquals("https://example.com", link.origin());
    assertEquals("/runlight/invite", link.pathname);
    String code = link.searchParams().get("code");
    assertTrue(handle(web, req("/invite?code=" + code)).text().contains("as a member"));
    assertEquals(410, handle(web, req("/invite?code=nope")).status());

    assertEquals(
        409,
        handle(
                web,
                json(
                    owner,
                    "POST",
                    "/api/people",
                    Json.object("email", "jon@example.com", "role", "admin")))
            .status());
    Response noRole =
        handle(
            web,
            json(
                owner,
                "POST",
                "/api/people",
                Json.object("email", "x@example.com", "role", "owner")));
    assertEquals(
        "{\"error\":\"Pick admin, member, or viewer\",\"code\":\"role_needed\"}", noRole.text());
    assertEquals("nosniff", noRole.headers().get("x-content-type-options"));
    Response badEmail =
        handle(
            web,
            json(owner, "POST", "/api/people", Json.object("email", "nobody", "role", "admin")));
    assertEquals(
        "{\"error\":\"Enter an email address\",\"code\":\"email_invalid\",\"params\":{}}",
        badEmail.text());
    Response plain =
        handle(
            web,
            req(
                "/api/people",
                "POST",
                Map.of("cookie", owner, "content-type", "text/plain"),
                "{}"));
    assertEquals(415, plain.status(), "a write must be JSON");
    assertEquals(
        "{\"error\":\"Sign in first\",\"code\":\"sign_in\"}",
        handle(web, req("/api/people")).text());

    Response typo =
        handle(
            web,
            form(
                "/invite",
                "code",
                code,
                "password",
                "another long one",
                "again",
                "another long two"));
    assertEquals(400, typo.status());
    Response joined =
        handle(
            web,
            form(
                "/invite",
                "code",
                code,
                "password",
                "another long one",
                "again",
                "another long one"));
    assertEquals(303, joined.status());
    assertEquals("/runlight/", joined.headers().get("location"));
    String member = cookieOf(joined);
    assertEquals("member", web.access(withCookie(member)));
    assertEquals(403, handle(web, json(member, "GET", "/api/people")).status());
    assertEquals(
        410,
        handle(
                web,
                form(
                    "/invite",
                    "code",
                    code,
                    "password",
                    "another long one",
                    "again",
                    "another long one"))
            .status(),
        "an invite works once");

    // A member's tokens go when they become a viewer.
    Map<String, Object> mo = web.accounts().byEmail("mo@example.com");
    String moId = (String) mo.get("id");
    Map<String, Object> token =
        Json.object(
            "id",
            "b".repeat(24),
            "name",
            "Script",
            "site",
            "",
            "scope",
            "read",
            "hash",
            "c".repeat(64),
            "hint",
            "abcd",
            "createdAt",
            NOW,
            "lastUsedAt",
            null);
    rl.store().insertToken(token);
    assertTrue(web.tokenMade(token, moId));
    assertFalse(web.tokenMade(token, "d".repeat(24)), "nobody by that id makes tokens");
    Response changed =
        handle(web, json(owner, "PATCH", "/api/people/" + moId, Json.object("role", "viewer")));
    assertEquals(
        Json.stringify(
            Json.object(
                "person",
                Json.object(
                    "id",
                    moId,
                    "email",
                    "mo@example.com",
                    "role",
                    "viewer",
                    "createdAt",
                    NOW,
                    "twoFactor",
                    false,
                    "recoveryLeft",
                    0))),
        changed.text());
    assertEquals(List.of(), rl.store().tokens());
    assertEquals("read", web.access(withCookie(member)));
    assertFalse(web.tokenMade(token, moId), "a viewer makes no tokens");

    String jon = (String) web.accounts().byEmail("jon@example.com").get("id");
    assertEquals(
        "{\"error\":\"Only the owner can change their own role, by handing ownership to an admin\",\"code\":\"owner_protected\",\"params\":{}}",
        handle(web, json(owner, "PATCH", "/api/people/" + jon, Json.object("role", "admin")))
            .text());
    assertEquals(
        403,
        handle(web, json(owner, "PATCH", "/api/people/" + jon, Json.object("role", "admin")))
            .status());
    assertEquals(
        404,
        handle(
                web,
                json(owner, "PATCH", "/api/people/" + "a".repeat(24), Json.object("role", "admin")))
            .status());
    assertEquals(
        "remove_self", parse(handle(web, json(owner, "DELETE", "/api/people/" + jon))).get("code"));

    // Invites listed, resent, and cancelled.
    handle(
        web,
        json(
            owner,
            "POST",
            "/api/people",
            Json.object("email", "zed@example.com", "role", "viewer")));
    Map<String, Object> listed = parse(handle(web, json(owner, "GET", "/api/people")));
    List<Object> emails = new ArrayList<>();
    for (Object p : Js.list(listed.get("people"))) {
      emails.add(Js.map(p).get("email"));
    }
    emails.sort(null);
    assertEquals(List.of("jon@example.com", "mo@example.com"), emails);
    List<Object> invites = Js.list(listed.get("invites"));
    assertEquals(1, invites.size());
    assertEquals("zed@example.com", Js.map(invites.get(0)).get("email"));
    String id = (String) Js.map(invites.get(0)).get("id");
    Response resent = handle(web, json(owner, "POST", "/api/invites/" + id + "/resend"));
    assertEquals(200, resent.status());
    String newId = (String) Js.map(parse(resent).get("invite")).get("id");
    assertNotEquals(id, newId);
    assertEquals(404, handle(web, json(owner, "DELETE", "/api/invites/" + id)).status());
    assertEquals(
        "{\"ok\":true}", handle(web, json(owner, "DELETE", "/api/invites/" + newId)).text());

    assertEquals("{\"ok\":true}", handle(web, json(owner, "DELETE", "/api/people/" + moId)).text());
    assertNull(web.signedIn(withCookie(member)), "someone removed is signed out");
  }

  @Test
  void invitesAreEmailedWhenThereIsAMailService() {
    Web web = web(Json.object("token", "app-token"), "https://stats.example.com");
    String owner = owner(web);
    rl.mail = Json.object("service", "smtp", "from", "runlight@example.com");
    Map<String, Object> body =
        parse(
            handle(
                web,
                json(
                    owner,
                    "POST",
                    "/api/people",
                    Json.object("email", "mo@example.com", "role", "viewer"))));
    assertEquals(true, body.get("emailed"));
    String link = (String) body.get("link");
    assertTrue(
        link.startsWith("https://stats.example.com/runlight/invite?code="),
        "the install's own address, never the request's Host");
    assertEquals("jon@example.com invited you to Runlight", rl.sent.get(0).get("subject"));
    assertEquals(
        "jon@example.com invited you to the Runlight at stats.example.com as a viewer, who can read every site's stats.\n\nChoose a password to join:\n"
            + link
            + "\n\nThe link works for seven days.\n",
        rl.sent.get(0).get("text"));

    rl.mailFails =
        new CodedError(
            "The server refused the password",
            "mail_auth",
            Json.object("host", "smtp.example.com"));
    Map<String, Object> failed =
        parse(
            handle(
                web,
                json(
                    owner,
                    "POST",
                    "/api/people",
                    Json.object("email", "ada@example.com", "role", "admin"))));
    assertEquals(
        List.of("invite", "link", "emailed", "mailError", "mailCode", "mailParams"),
        new ArrayList<>(failed.keySet()));
    assertEquals("mail_auth", failed.get("mailCode"));
    assertEquals(Map.of("host", "smtp.example.com"), failed.get("mailParams"));
    rl.mailFails = new IllegalStateException("Something else");
    Map<String, Object> other =
        parse(
            handle(
                web,
                json(
                    owner,
                    "POST",
                    "/api/people",
                    Json.object("email", "zed@example.com", "role", "admin"))));
    assertEquals(
        List.of("invite", "link", "emailed", "mailError"),
        new ArrayList<>(other.keySet()),
        "an error without a code of its own has none here");
  }

  @Test
  void twoFactorThroughTheAccountApiAndTheCodeStep() {
    Web web = web();
    String owner = owner(web);
    Response wrong =
        handle(
            web,
            json(
                owner,
                "POST",
                "/api/account/2fa/start",
                Json.object("password", "a wrong password")));
    assertEquals(
        "{\"error\":\"Your password is not right\",\"code\":\"password_wrong\"}", wrong.text());
    Map<String, Object> start =
        parse(
            handle(
                web,
                json(
                    owner,
                    "POST",
                    "/api/account/2fa/start",
                    Json.object("password", "a long password"))));
    String secret = (String) start.get("secret");
    assertEquals(Crypto.otpauthUri(secret, "jon@example.com", "example.com"), start.get("uri"));
    assertEquals(
        "{\"error\":\"Turn on two-factor sign-in first\",\"code\":\"twofactor_off\"}",
        handle(
                web,
                json(
                    owner,
                    "POST",
                    "/api/account/2fa/recovery",
                    Json.object("password", "a long password")))
            .text());

    String code = Crypto.totp(secret, now / 30_000);
    Response confirmed =
        handle(
            web,
            json(
                owner,
                "POST",
                "/api/account/2fa/confirm",
                Json.object("code", code.substring(0, 3) + " " + code.substring(3))));
    assertEquals(200, confirmed.status());
    assertEquals(10, Js.list(parse(confirmed).get("recovery")).size());
    assertNull(web.signedIn(withCookie(owner)), "turning it on signs out every other browser");
    owner = cookieOf(confirmed);
    assertEquals(true, web.signedIn(withCookie(owner)).get("twoFactor"));

    // Signing in now earns only the code step.
    now += 60_000;
    Response step =
        handle(
            web,
            form(
                "/login",
                "email",
                "jon@example.com",
                "password",
                "a long password",
                "next",
                "/runlight/?x=1"));
    assertEquals(200, step.status());
    assertEquals(List.of(), step.headers().getSetCookie());
    Matcher m = Pattern.compile("name=\"pending\" value=\"([^\"]+)\"").matcher(step.text());
    assertTrue(m.find());
    String pending = m.group(1);
    Response bad =
        handle(
            web,
            form("/login/code", "pending", pending, "code", "12345x", "next", "/runlight/?x=1"));
    assertEquals(401, bad.status());
    assertEquals(
        Pages.codePage(
            BASE,
            Json.object(
                "pending",
                pending,
                "next",
                "/runlight/?x=1",
                "error",
                "That code is not right. Check the time on your phone, or use a recovery code.")),
        bad.text());
    Response in =
        handle(
            web,
            form(
                "/login/code",
                "pending",
                pending,
                "code",
                Crypto.totp(secret, now / 30_000),
                "next",
                "/runlight/?x=1"));
    assertEquals(303, in.status());
    assertEquals("/runlight/?x=1", in.headers().get("location"));
    assertEquals(
        "/runlight/login?next=%2Frunlight%2F",
        handle(web, form("/login/code", "pending", "made.up.ticket", "code", "123456"))
            .headers()
            .get("location"));

    // Turning it off keeps this browser signed in.
    Response off =
        handle(
            web,
            json(
                cookieOf(in),
                "POST",
                "/api/account/2fa/disable",
                Json.object("password", "a long password")));
    assertEquals("{\"ok\":true}", off.text());
    assertEquals(false, web.signedIn(withCookie(cookieOf(off))).get("twoFactor"));
    assertEquals(
        404,
        handle(
                web,
                json(
                    cookieOf(off),
                    "POST",
                    "/api/account/2fa/other",
                    Json.object("password", "a long password")))
            .status());
  }

  @Test
  void confirmingHasFiveTriesAndThenStartsAgain() {
    Web web = web();
    String owner = owner(web);
    Map<String, Object> start =
        parse(
            handle(
                web,
                json(
                    owner,
                    "POST",
                    "/api/account/2fa/start",
                    Json.object("password", "a long password"))));
    String right = Crypto.totp((String) start.get("secret"), now / 30_000);
    String wrong = right.equals("000000") ? "111111" : "000000";
    for (int i = 0; i < 5; i++) {
      assertEquals(
          "code_wrong",
          parse(
                  handle(
                      web,
                      json(owner, "POST", "/api/account/2fa/confirm", Json.object("code", wrong))))
              .get("code"));
    }
    Response restart =
        handle(web, json(owner, "POST", "/api/account/2fa/confirm", Json.object("code", right)));
    assertEquals(429, restart.status());
    assertEquals("twofactor_restart", parse(restart).get("code"));
    assertNull(
        web.accounts()
            .confirmTwoFactor(
                (String) web.accounts().byEmail("jon@example.com").get("id"), right, now),
        "the set-up was dropped");
    // Starting again with the password opens five more tries.
    Map<String, Object> again =
        parse(
            handle(
                web,
                json(
                    owner,
                    "POST",
                    "/api/account/2fa/start",
                    Json.object("password", "a long password"))));
    String code = Crypto.totp((String) again.get("secret"), now / 30_000);
    assertEquals(
        200,
        handle(web, json(owner, "POST", "/api/account/2fa/confirm", Json.object("code", code)))
            .status());
  }

  @Test
  void passwordChangesEndOtherSessions() {
    Web web = web();
    String owner = owner(web);
    assertEquals(
        "{\"error\":\"Your current password is not right\",\"code\":\"password_current_wrong\"}",
        handle(
                web,
                json(
                    owner,
                    "POST",
                    "/api/account/password",
                    Json.object("current", "nope", "next", "a newer long one")))
            .text());
    Response shortOne =
        handle(
            web,
            json(
                owner,
                "POST",
                "/api/account/password",
                Json.object("current", "a long password", "next", "short")));
    assertEquals(
        "{\"error\":\"Use a password of at least 10 characters\",\"code\":\"password_short\",\"params\":{\"min\":\"10\"}}",
        shortOne.text());
    Response changed =
        handle(
            web,
            json(
                owner,
                "POST",
                "/api/account/password",
                Json.object("current", "a long password", "next", "a newer long one")));
    assertEquals("{\"ok\":true}", changed.text());
    assertNull(web.signedIn(withCookie(owner)));
    assertNotNull(web.signedIn(withCookie(cookieOf(changed))));
  }

  @Test
  void tenWrongPasswordsFromOneAddressWait() {
    Web web = web();
    owner(web);
    Map<String, String> headers =
        Map.of(
            "content-type", "application/x-www-form-urlencoded", "x-forwarded-for", "203.0.113.9");
    String body = encode("email", "jon@example.com", "password", "a wrong password");
    for (int i = 0; i < 10; i++) {
      assertEquals(401, handle(web, req("/login", "POST", headers, body)).status());
    }
    Response held = handle(web, req("/login", "POST", headers, body));
    assertEquals(429, held.status());
    assertTrue(held.text().contains("Too many tries. Wait fifteen minutes and try again."));
    String right = encode("email", "jon@example.com", "password", "a long password");
    assertEquals(
        429,
        handle(web, req("/login", "POST", headers, right)).status(),
        "even the right password waits");
    Map<String, String> elsewhere = new LinkedHashMap<>(headers);
    elsewhere.put("x-forwarded-for", "203.0.113.10");
    assertEquals(
        303,
        handle(web, req("/login", "POST", elsewhere, right)).status(),
        "another address is not held up");
    now += 15 * 60_000;
    assertEquals(
        303, handle(web, req("/login", "POST", headers, right)).status(), "fifteen minutes later");
  }

  @Test
  void anAccountHeldUpByOthersGetsASignInLink() {
    Web web = web(Json.object("token", "app-token"), "https://stats.example.com");
    owner(web);
    rl.mail = Json.object("service", "smtp", "from", "runlight@example.com");
    Accounts accounts = web.accounts();
    // Fifty failures against the account from fifty addresses, counted as the throttle counts
    // them.
    Throttle throttle = new Throttle(rl.store(), "account", 50);
    for (int i = 0; i < 50; i++) {
      throttle.fail("jon@example.com", now);
    }
    Response held =
        handle(
            web,
            form(
                "/login",
                "email",
                "jon@example.com",
                "password",
                "a long password",
                "next",
                "/runlight/?a=1"));
    assertEquals(429, held.status());
    assertTrue(held.text().contains("a link to sign in is on its way"));
    assertEquals(1, rl.sent.size());
    assertEquals("Sign in to Runlight", rl.sent.get(0).get("subject"));
    Matcher m =
        Pattern.compile("(https://stats\\.example\\.com/runlight/login/link\\?\\S+)")
            .matcher((String) rl.sent.get(0).get("text"));
    assertTrue(m.find());
    Url link = new Url(m.group(1));
    assertEquals("/runlight/?a=1", link.searchParams().get("next"));
    handle(web, form("/login", "email", "jon@example.com", "password", "a long password"));
    assertEquals(1, rl.sent.size(), "at most one link a minute");
    Response wrongToo =
        handle(web, form("/login", "email", "jon@example.com", "password", "a wrong password"));
    assertEquals(429, wrongToo.status(), "a wrong password gets the same answer");

    Response in = handle(web, req("/login/link" + link.search));
    assertEquals(303, in.status());
    assertEquals("/runlight/?a=1", in.headers().get("location"));
    assertEquals(410, handle(web, req("/login/link" + link.search)).status(), "a link works once");
    assertNotNull(accounts.byEmail("jon@example.com"));
  }

  @Test
  void aBrokenSessionCookieThrowsAsDecodeUriComponentDoes() {
    Web web = web();
    assertThrows(
        IllegalArgumentException.class,
        () -> web.signedIn(withCookie("runlight_session=%E0%A4%A")));
  }

  @Test
  void theSessionCookieIsReadAmongOthers() {
    Web web = web();
    String owner = owner(web);
    assertNotNull(web.signedIn(withCookie("a=b; " + owner + " ; c=d=e")));
    assertEquals(Accounts.SESSION_COOKIE, owner.split("=", -1)[0]);
    Request plain =
        new Request(
            "http://example.com/runlight/login",
            "POST",
            Headers.of("content-type", "application/x-www-form-urlencoded"),
            encode("email", "jon@example.com", "password", "a long password"));
    assertFalse(
        handle(web, plain).headers().getSetCookie().get(0).contains("Secure"),
        "Secure only over https");
    Request proxied =
        new Request(
            "http://example.com/runlight/logout",
            "GET",
            Headers.of("x-forwarded-proto", "https"),
            "");
    assertTrue(handle(web, proxied).headers().getSetCookie().get(0).endsWith("; Secure"));
  }
}
