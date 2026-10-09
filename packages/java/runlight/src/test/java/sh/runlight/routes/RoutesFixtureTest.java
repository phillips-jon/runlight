package sh.runlight.routes;

import static org.junit.jupiter.api.Assertions.assertEquals;

import java.util.ArrayList;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.TreeMap;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import sh.runlight.Env;
import sh.runlight.Fixtures;
import sh.runlight.Hash;
import sh.runlight.Js;
import sh.runlight.OAuth;
import sh.runlight.Routes;
import sh.runlight.Runlight;
import sh.runlight.conformance.Player;
import sh.runlight.http.Headers;
import sh.runlight.http.Request;
import sh.runlight.http.Response;

/**
 * Replays tests/fixtures/routes.json, which scripts/php-fixtures-routes.mts writes from the
 * TypeScript SDK: the dashboard's page, the tracker, refusals with their codes, and OAuth's
 * documents, each answer byte for byte with every header, and the helpers routes.ts and oauth.ts
 * export.
 */
class RoutesFixtureTest {
  @BeforeEach
  void setUp() {
    Make.clearEnv();
  }

  @AfterEach
  void tearDown() {
    Env.reset();
  }

  private static Map<String, Object> fixture() {
    return Fixtures.load("routes");
  }

  static List<Integer> exchanges() {
    List<Integer> out = new ArrayList<>();
    for (int i = 0; i < Js.list(fixture().get("exchanges")).size(); i++) {
      out.add(i);
    }
    return out;
  }

  @SuppressWarnings("unchecked")
  private static Runlight.Options runlightOptions(Map<String, Object> given, long now) {
    Runlight.Options out = new Runlight.Options().now(() -> now);
    if (given.get("sites") != null) {
      out.sites((List<Map<String, Object>>) given.get("sites"));
    }
    if (given.get("site") != null) {
      out.site(Js.map(given.get("site")));
    }
    return out;
  }

  private static Routes.Options routesOptions(Map<String, Object> given) {
    Routes.Options out = new Routes.Options();
    if (given.containsKey("token")) {
      out.token((String) given.get("token"));
    }
    if (given.get("basePath") instanceof String s) {
      out.basePath(s);
    }
    if (given.get("signOut") instanceof String s) {
      out.signOut(s);
    }
    if (given.get("signIn") instanceof String s) {
      out.signIn(s);
    }
    if (Boolean.TRUE.equals(given.get("geoCredit"))) {
      out.geoCredit(true);
    }
    return out;
  }

  /** A response's headers as the fixture holds them: set-cookie a list, the rest joined. */
  private static Map<String, Object> headers(Response response, boolean cookieList) {
    Map<String, Object> got = new TreeMap<>();
    for (Map.Entry<String, List<String>> e : response.headers().all().entrySet()) {
      got.put(
          e.getKey(),
          cookieList && e.getKey().equals("set-cookie")
              ? new ArrayList<Object>(e.getValue())
              : String.join(", ", e.getValue()));
    }
    return got;
  }

  @ParameterizedTest
  @MethodSource("exchanges")
  void answersAsTheTypeScriptDoes(int index) {
    Map<String, Object> fixture = fixture();
    Map<String, Object> exchange = Js.map(Js.list(fixture.get("exchanges")).get(index));
    long now = Js.asLong(fixture.get("now"));
    Runlight rl = Make.runlight(runlightOptions(Js.map(exchange.get("runlight")), now));
    Routes routes = rl.routes(routesOptions(Js.map(exchange.get("routes"))));
    for (Object item : Js.list(exchange.get("answers"))) {
      Map<String, Object> answer = Js.map(item);
      Map<String, Object> ask = Js.map(answer.get("ask"));
      String method = ask.get("method") instanceof String m ? m : "GET";
      String label = exchange.get("name") + ": " + method + " " + ask.get("path");
      Map<String, String> given = new LinkedHashMap<>();
      Map<String, Object> askHeaders = Js.map(ask.get("headers"));
      if (askHeaders != null) {
        for (Map.Entry<String, Object> e : askHeaders.entrySet()) {
          given.put(e.getKey().toLowerCase(Locale.ROOT), (String) e.getValue());
        }
      }
      String body = ask.get("body") instanceof String b ? b : null;
      if (body != null && !given.containsKey("content-type")) {
        given.put("content-type", Player.TEXT_BODY_TYPE);
      }
      Response response =
          routes.handle(
              new Request(
                  "https://example.com" + ask.get("path"),
                  method,
                  Headers.of(given),
                  body == null ? "" : body));
      assertEquals(Js.asLong(answer.get("status")), response.status(), label + ": status");
      Fixtures.assertJson(
          new TreeMap<>(Js.map(answer.get("headers"))),
          headers(response, true),
          label + ": headers");
      if (answer.get("sha256") != null) {
        assertEquals(
            answer.get("sha256"),
            HexFormat.of().formatHex(Hash.sha256Bytes(response.bytes())),
            label + ": body");
      } else {
        assertEquals(answer.get("text"), response.text(), label + ": body");
      }
    }
  }

  @Test
  @SuppressWarnings("unchecked")
  void codedErrorsAreTheSameBytes() {
    for (Object item : Js.list(fixture().get("coded"))) {
      Map<String, Object> c = Js.map(item);
      List<Object> args = Js.list(c.get("args"));
      String code = (String) args.get(1);
      Map<String, String> extra = new LinkedHashMap<>();
      for (Map.Entry<String, Object> e : Js.map(args.get(4)).entrySet()) {
        extra.put(e.getKey(), (String) e.getValue());
      }
      Response response =
          Routes.coded(
              (String) args.get(0),
              code,
              (int) Js.asLong(args.get(2)),
              (Map<String, ?>) args.get(3),
              extra);
      assertEquals(Js.asLong(c.get("status")), response.status());
      assertEquals(c.get("text"), response.text(), code);
      Fixtures.assertJson(new TreeMap<>(Js.map(c.get("headers"))), headers(response, false), code);
    }
  }

  @Test
  void hostNamesAreBareAsTheTypeScriptMakesThem() {
    for (Object item : Js.list(fixture().get("hostName"))) {
      List<Object> c = Js.list(item);
      assertEquals(c.get(1), Routes.hostName((String) c.get(0)), (String) c.get(0));
    }
  }

  @Test
  void managePathsAreTheSame() {
    for (Object item : Js.list(fixture().get("managePath"))) {
      List<Object> c = Js.list(item);
      assertEquals(
          c.get(2),
          Routes.managePath((String) c.get(0), (String) c.get(1)),
          c.get(0) + " " + c.get(1));
    }
  }

  @Test
  void pkceS256MatchesTheTypeScript() {
    for (Object item : Js.list(fixture().get("s256"))) {
      List<Object> c = Js.list(item);
      assertEquals(c.get(1), OAuth.s256((String) c.get(0)), (String) c.get(0));
    }
    // RFC 7636's own example.
    assertEquals(
        "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
        OAuth.s256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"));
  }

  @Test
  void resourceMetadataUrl() {
    for (Object item : Js.list(fixture().get("resourceMetadataUrl"))) {
      List<Object> c = Js.list(item);
      assertEquals(c.get(2), OAuth.resourceMetadataUrl((String) c.get(0), (String) c.get(1)));
    }
  }
}
