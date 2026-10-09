package sh.runlight.accounts;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import java.util.Map;
import java.util.function.Function;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import sh.runlight.Env;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.Routes;
import sh.runlight.Runlight;
import sh.runlight.http.Headers;
import sh.runlight.http.Request;
import sh.runlight.http.Response;
import sh.runlight.http.SearchParams;
import sh.runlight.http.Url;
import sh.runlight.store.Databases;

/** accounts.test.ts's route-level tests: an app with routes(accounts: true). */
class RoutesAccountsTest {
  static List<String> kinds() {
    return Databases.kinds();
  }

  @AfterEach
  void tearDown() {
    Env.reset();
    Databases.cleanup();
  }

  private static Request req(String path) {
    return req(path, "GET", Headers.of(), "");
  }

  private static Request req(String path, String method, Headers headers, String body) {
    return new Request("https://example.com" + path, method, headers, body);
  }

  private static Request form(String path, String cookie, String... fields) {
    SearchParams params = new SearchParams();
    for (int i = 0; i + 1 < fields.length; i += 2) {
      params.append(fields[i], fields[i + 1]);
    }
    Headers headers = Headers.of("content-type", "application/x-www-form-urlencoded");
    if (!cookie.isEmpty()) {
      headers.set("cookie", cookie);
    }
    return req(path, "POST", headers, params.toString());
  }

  private static String cookieOf(Response response) {
    String cookie = response.headers().get("set-cookie");
    return (cookie == null ? "" : cookie).split(";")[0];
  }

  private static Map<String, Object> body(Response response) {
    return Js.map(Json.parse(response.text()));
  }

  private interface JsonCall {
    Response call(String cookie, String method, String path, Object body);
  }

  @ParameterizedTest
  @MethodSource("kinds")
  void anAppWithAccountsOnMakesItsFirstAccountWithItsTokenThenInvitesPeopleByRole(String kind) {
    Runlight rl =
        new Runlight(new Runlight.Options().store(Databases.fresh(kind)).secret("k".repeat(64)));
    Routes routes = rl.routes(new Routes.Options().token("app-token").accounts(true));
    Function<Request, Response> handler = routes::handle;
    JsonCall json =
        (cookie, method, path, body) ->
            handler.apply(
                req(
                    "/runlight" + path,
                    method,
                    Headers.of("cookie", cookie, "content-type", "application/json"),
                    body == null ? "" : Json.stringify(body)));

    // Nobody yet: the dashboard sends you to set up, which asks for the app's token.
    Response start = handler.apply(req("/runlight/"));
    assertEquals(303, start.status());
    assertEquals("/runlight/setup", start.headers().get("location"));
    String page = handler.apply(req("/runlight/setup")).text();
    assertTrue(page.contains("RUNLIGHT_TOKEN"));
    assertTrue(page.contains("action=\"/runlight/setup\""));
    assertTrue(page.contains("href=\"/runlight/auth.css\""));
    Response wrong =
        handler.apply(
            form(
                "/runlight/setup",
                "",
                "code",
                "guess",
                "email",
                "jon@example.com",
                "password",
                "a long password",
                "again",
                "a long password"));
    assertEquals(403, wrong.status());
    Response made =
        handler.apply(
            form(
                "/runlight/setup",
                "",
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
    assertTrue(
        made.headers().get("set-cookie").contains("Path=/runlight;"),
        "the session is for Runlight's paths only");
    String owner = cookieOf(made);
    assertEquals(
        "/runlight/login",
        handler.apply(req("/runlight/setup")).headers().get("location"),
        "setup closes once there is an account");

    // Signed in, the dashboard and its API answer; signed out, they do not.
    Headers asOwner = Headers.of("cookie", owner);
    assertEquals(200, handler.apply(req("/runlight/", "GET", asOwner, "")).status());
    assertTrue(
        handler.apply(req("/runlight/", "GET", asOwner, "")).text().contains("data-accounts=\"\""));
    assertEquals(401, handler.apply(req("/runlight/api/sites")).status());
    assertEquals(200, handler.apply(req("/runlight/api/sites", "GET", asOwner, "")).status());
    assertEquals(
        200,
        handler
            .apply(
                req(
                    "/runlight/api/sites",
                    "GET",
                    Headers.of("authorization", "Bearer app-token"),
                    ""))
            .status(),
        "a script's token still works");
    assertEquals(
        "owner",
        Js.get(body(json.call(owner, "GET", "/api/account", null)).get("account"), "role"));

    // The owner invites a member, who joins with their own password.
    Map<String, Object> sent =
        body(
            json.call(
                owner,
                "POST",
                "/api/people",
                Json.object("email", "mo@example.com", "role", "member")));
    assertEquals(false, sent.get("emailed"), "no mail service here, so the link is for passing on");
    Url link = new Url((String) sent.get("link"));
    assertEquals("/runlight/invite", link.pathname);
    assertTrue(handler.apply(req(link.pathname + link.search)).text().contains("as a member"));
    Response joined =
        handler.apply(
            form(
                "/runlight/invite",
                "",
                "code",
                link.searchParams().get("code"),
                "password",
                "another long one",
                "again",
                "another long one"));
    assertEquals(303, joined.status());
    String member = cookieOf(joined);

    // A member changes a site's settings, but not people, the mail service, or the assistant's
    // settings.
    assertEquals(
        201,
        json.call(
                member,
                "POST",
                "/api/goals",
                Json.object("name", "Signup", "kind", "page", "match", "/thanks"))
            .status());
    assertEquals(403, json.call(member, "GET", "/api/people", null).status());
    assertEquals(
        "admin_only", body(json.call(member, "PUT", "/api/mail", Json.object())).get("code"));
    assertEquals(403, json.call(member, "PUT", "/api/assistant", Json.object()).status());

    // Signing out ends the session; signing in again with the password starts one.
    Response out = handler.apply(req("/runlight/logout"));
    assertEquals("/runlight/login", out.headers().get("location"));
    assertEquals("/runlight/login", handler.apply(req("/runlight/")).headers().get("location"));
    Response back =
        handler.apply(
            form(
                "/runlight/login",
                "",
                "email",
                "mo@example.com",
                "password",
                "another long one",
                "next",
                "/runlight/?period=7d"));
    assertEquals(303, back.status());
    assertEquals("/runlight/?period=7d", back.headers().get("location"));
    Response elsewhere =
        handler.apply(
            form(
                "/runlight/login",
                "",
                "email",
                "mo@example.com",
                "password",
                "another long one",
                "next",
                "//evil.example/"));
    assertEquals("/runlight/", elsewhere.headers().get("location"), "never sent off the app");
  }

  private static Request setup(String code) {
    return form(
        "/runlight/setup",
        "",
        "code",
        code,
        "email",
        "jon@example.com",
        "password",
        "a long password",
        "again",
        "a long password");
  }

  @Test
  void
      inDevelopmentOrLeftOpenOnPurposeTheFirstAccountNeedsNoProofInProductionWithoutATokenSetupStaysShut() {
    Env.override("RUNLIGHT_TOKEN", null);
    Env.override("RUNLIGHT_SECRET", null);
    Env.override("NODE_ENV", "development");
    Routes dev =
        new Runlight(new Runlight.Options().store(Databases.fresh("sqlite")))
            .routes(new Routes.Options().accounts(true));
    String page = dev.handle(req("/runlight/setup")).text();
    assertFalse(page.contains("RUNLIGHT_TOKEN"));
    assertEquals(303, dev.handle(setup("")).status());

    Env.override("NODE_ENV", "production");
    Routes open =
        new Runlight(new Runlight.Options().store(Databases.fresh("sqlite")))
            .routes(new Routes.Options().token(null).accounts(true));
    assertEquals(
        200,
        open.handle(req("/runlight/setup")).status(),
        "token: null leaves setup open, as it leaves everything");
    Routes prod =
        new Runlight(new Runlight.Options().store(Databases.fresh("sqlite")).secret("k".repeat(64)))
            .routes(new Routes.Options().accounts(true));
    Response shut = prod.handle(req("/runlight/setup"));
    assertEquals(403, shut.status());
    assertTrue(shut.text().contains("Set RUNLIGHT_TOKEN"));
    assertEquals(403, prod.handle(setup("")).status());
  }
}
