package sh.runlight.spring;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.function.Consumer;
import javax.sql.DataSource;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.boot.SpringBootConfiguration;
import org.springframework.boot.autoconfigure.EnableAutoConfiguration;
import org.springframework.boot.builder.SpringApplicationBuilder;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.context.support.GenericApplicationContext;
import org.springframework.jdbc.datasource.TransactionAwareDataSourceProxy;
import org.springframework.web.servlet.function.RouterFunction;
import org.springframework.web.servlet.function.RouterFunctions;
import org.springframework.web.servlet.function.ServerResponse;
import org.sqlite.SQLiteDataSource;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.Routes;
import sh.runlight.Runlight;
import sh.runlight.store.SqlStore;

/**
 * The starter in a real Spring Boot app on Spring MVC under Tomcat, over HTTP on 127.0.0.1:
 * Runlight from {@code runlight.*}, over a database URL or the app's DataSource, the routes at the
 * base path within the context, short links and AI agent fetches through the link filter, the body
 * cap, the filters' order, the scheduled check, and each part switched off.
 */
class StarterTest {
  private static final String CHROME = "Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36";
  private static final String GPTBOT =
      "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2;"
          + " +https://openai.com/gptbot)";

  @TempDir Path dir;

  /** The app: nothing but auto-configuration. */
  @SpringBootConfiguration
  @EnableAutoConfiguration
  static class App {}

  private static ConfigurableApplicationContext start(String... more) {
    return start(c -> {}, more);
  }

  private static ConfigurableApplicationContext start(
      Consumer<GenericApplicationContext> beans, String... more) {
    List<String> properties = new ArrayList<>();
    properties.add("server.port=0");
    properties.add("server.address=127.0.0.1");
    properties.add("spring.main.web-application-type=servlet");
    properties.add("spring.main.banner-mode=off");
    properties.add("logging.level.root=warn");
    properties.addAll(List.of(more));
    return new SpringApplicationBuilder(App.class)
        .initializers(c -> beans.accept((GenericApplicationContext) c))
        .properties(properties.toArray(String[]::new))
        .run();
  }

  private static int port(ConfigurableApplicationContext context) {
    return Integer.parseInt(
        Objects.requireNonNull(context.getEnvironment().getProperty("local.server.port")));
  }

  private String database() {
    return "runlight.database-url=sqlite:" + dir.resolve("runlight.db");
  }

  private static byte[] utf8(String text) {
    return text.getBytes(StandardCharsets.UTF_8);
  }

  @Test
  void runlightComesFromThePropertiesAndServesTheRoutes() throws Exception {
    try (ConfigurableApplicationContext context =
        start(
            database(),
            "runlight.site.name=example.com",
            "runlight.site.hostnames=example.com",
            "runlight.site.timezone=Europe/London",
            "runlight.token=app-token",
            "runlight.check.enabled=false")) {
      int port = port(context);
      Runlight rl = context.getBean(Runlight.class);
      assertEquals("Europe/London", rl.site(null).get("timezone"));
      assertEquals(List.of("/runlight"), rl.routeBases);

      RawHttp.Answer hit =
          RawHttp.send(
              port,
              "POST",
              "/runlight/e",
              utf8("{\"k\":\"pageview\",\"u\":\"https://example.com/post\"}"),
              "User-Agent",
              CHROME);
      assertEquals(202, hit.status(), hit.text());
      assertEquals(401, RawHttp.get(port, "/runlight/api/stats?period=today").status());
      RawHttp.Answer stats =
          RawHttp.get(
              port, "/runlight/api/stats?period=today", "Authorization", "Bearer app-token");
      assertEquals(200, stats.status(), stats.text());
      assertEquals(1L, Js.map(Js.map(Json.parse(stats.text())).get("stats")).get("pageviews"));

      RawHttp.Answer made =
          RawHttp.send(
              port,
              "POST",
              "/runlight/api/links",
              utf8("{\"url\":\"https://example.org/sale\",\"slug\":\"sale\"}"),
              "Authorization",
              "Bearer app-token",
              "Content-Type",
              "application/json");
      assertEquals(201, made.status(), made.text());
      RawHttp.Answer go = RawHttp.get(port, "/go/sale", "User-Agent", CHROME);
      assertEquals(302, go.status());
      assertEquals("https://example.org/sale", go.header("location"));

      RawHttp.get(port, "/about", "User-Agent", GPTBOT);
      RawHttp.get(port, "/contact", "User-Agent", CHROME);
      List<Map<String, Object>> fetches =
          rl.store.db().all("SELECT path FROM rl_events WHERE kind = 'fetch'");
      assertEquals(List.of(Map.of("path", "/about")), fetches);

      RawHttp.Answer big =
          RawHttp.send(port, "POST", "/runlight/e", new byte[16 * 1024 + 1], "User-Agent", CHROME);
      assertEquals(413, big.status());
      assertEquals("{\"error\":\"That request is too large\"}", big.text());
    }
  }

  @Test
  void theRoutesAndLinksAreWithinTheContextPath() throws Exception {
    try (ConfigurableApplicationContext context =
        start(
            database(),
            "server.servlet.context-path=/app",
            "runlight.base-path=/stats",
            "runlight.link-path=/l",
            "runlight.open=true",
            "runlight.check.enabled=false")) {
      int port = port(context);
      Runlight rl = context.getBean(Runlight.class);
      assertEquals(List.of("/app/stats"), rl.routeBases);
      RawHttp.Answer page = RawHttp.get(port, "/app/stats/");
      assertEquals(200, page.status(), page.text());
      assertTrue(page.text().contains("/app/stats/"), "the dashboard's links carry its base");
      assertEquals(200, RawHttp.get(port, "/app/stats/api/sites").status(), "open");
      assertEquals(404, RawHttp.get(port, "/app/runlight/api/sites").status());

      rl.links.create("default", Json.object("url", "https://example.org/a", "slug", "a"));
      RawHttp.Answer go = RawHttp.get(port, "/app/l/a", "User-Agent", CHROME);
      assertEquals(302, go.status(), go.text());
      assertEquals("https://example.org/a", go.header("location"));
    }
  }

  @Test
  void theStoreIsTheAppsDataSourceOutsideItsTransactions() throws Exception {
    SQLiteDataSource sqlite = new SQLiteDataSource();
    sqlite.setUrl("jdbc:sqlite:" + dir.resolve("app.db"));
    DataSource proxied = new TransactionAwareDataSourceProxy(sqlite);
    assertSame(sqlite, RunlightAutoConfiguration.plain(proxied));
    try (ConfigurableApplicationContext context =
        start(
            c -> c.registerBean(DataSource.class, () -> proxied),
            "runlight.site.name=from-the-app",
            "runlight.check.enabled=false",
            "runlight.web.enabled=false")) {
      Runlight rl = context.getBean(Runlight.class);
      rl.init();
      try (var connection = sqlite.getConnection();
          var statement = connection.createStatement();
          var rows = statement.executeQuery("SELECT name FROM rl_sites")) {
        assertTrue(rows.next());
        assertEquals("from-the-app", rows.getString(1));
      }
    }
  }

  @Test
  void withNoDatabaseTheAppSaysWhatToSet() {
    RuntimeException failed = assertThrows(RuntimeException.class, () -> start().close());
    Throwable cause = failed;
    while (cause.getCause() != null) {
      cause = cause.getCause();
    }
    assertTrue(
        cause.getMessage().contains("runlight.database-url"), String.valueOf(cause.getMessage()));
  }

  @Test
  void theAppsOwnStoreAndRoutesWin() throws Exception {
    SqlStore store = sh.runlight.store.Stores.sqlite(dir.resolve("own.db").toString());
    try (ConfigurableApplicationContext context =
        start(
            c -> {
              c.registerBean("ownStore", SqlStore.class, () -> store);
              c.registerBean(
                  "ownRoutes",
                  Routes.class,
                  () ->
                      c.getBean(Runlight.class)
                          .routes(new Routes.Options().basePath("/runlight").token(null)));
            },
            "runlight.check.enabled=false")) {
      Runlight rl = context.getBean(Runlight.class);
      assertSame(store, rl.store);
      assertSame(context.getBean("ownRoutes"), context.getBean(Routes.class));
      assertEquals(200, RawHttp.get(port(context), "/runlight/api/sites").status());
    }
  }

  @Test
  void aLinkDomainIsAnsweredBeforeTheAppWhichKeepsItsOwnHost() throws Exception {
    try (ConfigurableApplicationContext context =
        start(
            c ->
                c.registerBean(
                    "appRoutes",
                    RouterFunction.class,
                    () ->
                        RouterFunctions.route()
                            .GET("/launch", r -> ServerResponse.ok().body("the app"))
                            .build()),
            database(),
            "runlight.site.hostnames=example.com",
            "runlight.token=app-token",
            "runlight.check.enabled=false")) {
      int port = port(context);
      String[] auth = {"Authorization", "Bearer app-token", "Content-Type", "application/json"};
      RawHttp.Answer domain =
          RawHttp.send(
              port,
              "POST",
              "/runlight/api/link-domains",
              utf8("{\"domain\":\"go.example.com\"}"),
              auth);
      assertEquals(201, domain.status(), domain.text());
      RawHttp.Answer made =
          RawHttp.send(
              port,
              "POST",
              "/runlight/api/links",
              utf8(
                  "{\"url\":\"https://example.com/launch\",\"slug\":\"launch\",\"domain\":\"go.example.com\"}"),
              auth);
      assertEquals(201, made.status(), made.text());

      RawHttp.Answer linked =
          RawHttp.get(port, "/launch", "Host", "go.example.com", "User-Agent", CHROME);
      assertEquals(302, linked.status());
      assertEquals("https://example.com/launch", linked.header("location"));
      RawHttp.Answer app = RawHttp.get(port, "/launch", "User-Agent", CHROME);
      assertEquals(200, app.status());
      assertEquals("the app", app.text(), "the app's own host reaches the app");
    }
  }

  @Test
  void theFiltersAreAheadOfSpringSecurityUnlessOpen() {
    try (ConfigurableApplicationContext context =
        start(database(), "runlight.token=t", "runlight.check.enabled=false")) {
      assertEquals(-110, context.getBean(RunlightRoutesFilter.class).getOrder());
      assertEquals(-110, context.getBean(RunlightLinksFilter.class).getOrder());
    }
    try (ConfigurableApplicationContext context =
        start(database(), "runlight.open=true", "runlight.check.enabled=false")) {
      assertEquals(-90, context.getBean(RunlightRoutesFilter.class).getOrder(), "behind it");
      assertEquals(-110, context.getBean(RunlightLinksFilter.class).getOrder());
    }
    try (ConfigurableApplicationContext context =
        start(
            database(),
            "runlight.open=true",
            "runlight.web.order=5",
            "runlight.check.enabled=false")) {
      assertEquals(5, context.getBean(RunlightRoutesFilter.class).getOrder());
      assertEquals(5, context.getBean(RunlightLinksFilter.class).getOrder());
    }
  }

  @Test
  void theCheckRunsOnItsOwn() throws Exception {
    try (ConfigurableApplicationContext context = start(database(), "runlight.check.every=1s")) {
      Runlight rl = context.getBean(Runlight.class);
      assertTrue(context.getBean(RunlightChecker.class).isRunning());
      long until = System.nanoTime() + 10_000_000_000L;
      while (salts(rl) == 0 && System.nanoTime() < until) {
        Thread.sleep(50);
      }
      assertTrue(salts(rl) > 0, "the check made today's salt");
      RunlightChecker checker = context.getBean(RunlightChecker.class);
      context.close();
      assertTrue(!checker.isRunning(), "stopped with the context");
    }
  }

  private static long salts(Runlight rl) {
    try {
      return ((Number) rl.store.db().all("SELECT count(*) AS n FROM rl_salts").get(0).get("n"))
          .longValue();
    } catch (RuntimeException e) {
      return 0; // the tables are not made yet
    }
  }

  @Test
  void eachPartTurnsOff() {
    try (ConfigurableApplicationContext context = start(database(), "runlight.enabled=false")) {
      assertTrue(context.getBeansOfType(Runlight.class).isEmpty());
    }
    try (ConfigurableApplicationContext context =
        start(database(), "runlight.web.enabled=false", "runlight.check.enabled=false")) {
      assertEquals(1, context.getBeansOfType(Runlight.class).size());
      assertTrue(context.getBeansOfType(RunlightRoutesFilter.class).isEmpty());
      assertTrue(context.getBeansOfType(RunlightLinksFilter.class).isEmpty());
      assertTrue(context.getBeansOfType(RunlightChecker.class).isEmpty());
    }
  }

  @Test
  void theTrustProxySettingReadsAsRunlightTakesIt() {
    assertEquals(true, RunlightAutoConfiguration.trustProxy(null));
    assertEquals(true, RunlightAutoConfiguration.trustProxy(" TRUE "));
    assertEquals(false, RunlightAutoConfiguration.trustProxy("false"));
    assertEquals("cf-connecting-ip", RunlightAutoConfiguration.trustProxy("CF-Connecting-IP"));
  }
}
