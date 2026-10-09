package sh.runlight.server;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.PrintStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.PosixFilePermissions;
import java.util.ArrayList;
import java.util.Base64;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Stream;
import java.util.zip.GZIPOutputStream;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import sh.runlight.Fixtures;
import sh.runlight.Js;
import sh.runlight.Version;
import sh.runlight.http.Request;

/**
 * The server's settings, its command line, and DB-IP's monthly download, in a folder of their own.
 */
class CliTest {
  private static final long NOW = 1_791_374_400_000L; // 2026-10-07 12:00 UTC

  private Path root;

  @BeforeEach
  void setUp() throws IOException {
    root = Files.createTempDirectory("runlight-cli-");
  }

  @AfterEach
  void tearDown() throws IOException {
    try (Stream<Path> files = Files.walk(root)) {
      for (Path file : files.sorted(Comparator.reverseOrder()).toList()) {
        Files.delete(file);
      }
    }
  }

  private void configure(String... lines) throws IOException {
    Files.writeString(root.resolve("runlight.properties"), String.join("\n", lines) + "\n");
  }

  private record Ran(int code, String out, String err) {}

  private Ran cli(String... args) {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    ByteArrayOutputStream err = new ByteArrayOutputStream();
    int code =
        Cli.run(
            List.of(args),
            root,
            new PrintStream(out, true, StandardCharsets.UTF_8),
            new PrintStream(err, true, StandardCharsets.UTF_8),
            () -> NOW,
            null);
    return new Ran(
        code, out.toString(StandardCharsets.UTF_8), err.toString(StandardCharsets.UTF_8));
  }

  private static String permissions(Path path) throws IOException {
    return PosixFilePermissions.toString(Files.getPosixFilePermissions(path));
  }

  @Test
  void settingsComeFromRunlightPropertiesWithPathsFromTheProjectFolder() throws IOException {
    configure(
        "RUNLIGHT_URL=https://stats.example.com",
        "TRUST_PROXY = cf-connecting-ip",
        "RUNLIGHT_GEO=off");
    try (Config config = new Config(root)) {
      assertEquals("https://stats.example.com", config.url());
      assertEquals("cf-connecting-ip", config.trustProxy());
      assertEquals(root.resolve("runlight-data"), config.dataDir());
      assertEquals("rwx------", permissions(config.dataDir()), "the data folder is private");
      assertNull(config.geo());
      assertNull(config.dbIp());

      String secret = config.secret();
      assertTrue(secret.matches("^[0-9a-f]{64}$"), secret);
      assertEquals(secret, new Config(root).secret(), "the secret is made once and kept");
      assertEquals("rw-------", permissions(root.resolve("runlight-data/secret")));
    }

    configure("RUNLIGHT_URL=https://stats.example.com/dashboard");
    IllegalStateException wrong =
        assertThrows(IllegalStateException.class, () -> new Config(root).url());
    assertTrue(
        wrong.getMessage().contains("set RUNLIGHT_URL to the dashboard's address only"),
        wrong.getMessage());
  }

  @Test
  void theSetupCodeIsWrittenDownOnceAndUnlocksTheFirstAccount() throws IOException {
    configure("RUNLIGHT_URL=https://stats.example.com", "RUNLIGHT_GEO=off");
    String text;
    try (Config config = new Config(root)) {
      Standalone server = config.standalone();
      text = Files.readString(config.setupFile());
      assertTrue(
          text.matches(
              "^Open this link to create the first Runlight account\\. It works only while Runlight has no account\\.\nhttps://stats\\.example\\.com/setup\\?code=[A-Za-z0-9_-]{12}\n$"),
          text);
      assertEquals(
          config.setupCode(), new Config(root).setupCode(), "every start reads the same code");
      var page = server.handle(new Request("https://stats.example.com/"));
      assertEquals(403, page.status());
      assertTrue(page.text().contains("in the file setup.txt"), page.text());
      assertEquals(
          200,
          server
              .handle(new Request("https://stats.example.com/setup?code=" + config.setupCode()))
              .status());
    }

    Ran setup = cli("setup");
    assertEquals(0, setup.code());
    assertEquals(text, setup.out());
  }

  @Test
  void passwordMakesTheOwnerThenGivesANewPasswordAndTurnsOffTwoFactor() throws IOException {
    configure("RUNLIGHT_GEO=off");
    Ran made = cli("password", "Jon@Example.com");
    assertEquals(0, made.code(), made.err());
    assertTrue(
        made.out()
            .matches(
                "^Account made, as the owner, for jon@example\\.com: \\S{16}\nSign in, and change it by running this again whenever you like\\.\n$"),
        made.out());
    assertFalse(
        Files.exists(root.resolve("runlight-data/setup.txt")),
        "no setup link is made for a server that has an account");

    try (Config config = new Config(root)) {
      Standalone server = config.standalone(false);
      Map<String, Object> user = server.accounts.byEmail("jon@example.com");
      server
          .runlight
          .store
          .db()
          .run(
              "UPDATE rl_users SET totp_secret = ? WHERE id = ?",
              List.of("sealed", user.get("id")));
      assertEquals(true, server.accounts.byEmail("jon@example.com").get("twoFactor"));

      Ran again = cli("password", "jon@example.com");
      assertEquals(0, again.code());
      Matcher found = Pattern.compile(": (\\S+)\n").matcher(again.out());
      assertTrue(found.find());
      assertTrue(again.out().startsWith("New password for jon@example.com: "), again.out());
      assertTrue(
          again
              .out()
              .contains(
                  "Two-factor sign-in is now off for this account; turn it on again under Account.\n"));
      assertEquals(false, server.accounts.byEmail("jon@example.com").get("twoFactor"));
      assertNotNull(
          server.accounts.signIn("jon@example.com", found.group(1)),
          "the printed password signs in");
    }

    assertEquals(
        "Runlight already has an account. To get into one, run runlight password <email>.\n",
        cli("setup").out());

    Ran nobody = cli("password");
    assertEquals(1, nobody.code());
    assertTrue(nobody.err().contains("name the account"), nobody.err());
  }

  @Test
  void migrateCronAndUnknownCommands() throws IOException {
    configure("RUNLIGHT_GEO=off");
    Ran migrate = cli("migrate");
    assertEquals(0, migrate.code(), migrate.err());
    assertEquals(
        "Runlight's tables are up to date in " + root + "/runlight-data/runlight.db.\n",
        migrate.out());
    assertTrue(Files.exists(root.resolve("runlight-data/runlight.db")));

    // A setup link written before the first account goes at the next check.
    new Config(root).setupCode();
    cli("password", "jon@example.com");
    Ran cron = cli("cron");
    assertEquals(new Ran(0, "", ""), cron, "cron is quiet when all is well");
    assertFalse(Files.exists(root.resolve("runlight-data/setup.txt")));

    Ran unknown = cli("nonsense");
    assertEquals(1, unknown.code());
    assertTrue(unknown.err().contains("unknown command \"nonsense\""), unknown.err());

    Ran missing = cli("cron", "--config", root + "/missing.properties");
    assertEquals(1, missing.code());
    assertTrue(missing.err().contains("there is no config file at"), missing.err());

    assertEquals(new Ran(0, Version.version() + "\n", ""), cli("--version"));
    assertTrue(cli("--help").out().startsWith("Runlight " + Version.version() + ", privacy"));
  }

  @Test
  void theServerServesTheDashboardSetupAndHealthOverHttp() throws Exception {
    configure("PORT=0", "HOST=127.0.0.1", "RUNLIGHT_GEO=off");
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    ByteArrayOutputStream err = new ByteArrayOutputStream();
    try (Config config = new Config(root);
        Cli.Serving serving =
            Cli.start(
                config,
                new PrintStream(out, true, StandardCharsets.UTF_8),
                new PrintStream(err, true, StandardCharsets.UTF_8),
                () -> NOW)) {
      String base = "http://127.0.0.1:" + serving.port();
      String said = out.toString(StandardCharsets.UTF_8);
      assertTrue(
          said.startsWith("Runlight " + Version.version() + " is listening on " + base + "\n"),
          said);
      assertTrue(said.contains("Data: " + root + "/runlight-data/runlight.db\n"), said);
      Matcher link =
          Pattern.compile("  (" + Pattern.quote(base) + "/setup\\?code=(\\S+))\n").matcher(said);
      assertTrue(link.find(), said);
      assertEquals(link.group(2), config.setupCode(), "the code setup.txt holds");

      HttpClient client = HttpClient.newHttpClient();
      HttpResponse<String> health =
          client.send(
              HttpRequest.newBuilder(URI.create(base + "/healthz")).build(),
              HttpResponse.BodyHandlers.ofString());
      assertEquals(List.of(200, "ok"), List.of(health.statusCode(), health.body()));
      assertEquals(
          200,
          client
              .send(
                  HttpRequest.newBuilder(URI.create(link.group(1))).build(),
                  HttpResponse.BodyHandlers.ofString())
              .statusCode());
      HttpResponse<String> made =
          client.send(
              HttpRequest.newBuilder(URI.create(base + "/setup"))
                  .header("content-type", "application/x-www-form-urlencoded")
                  .POST(
                      HttpRequest.BodyPublishers.ofString(
                          "code="
                              + link.group(2)
                              + "&email=a%40b.co&password=a+long+password&again=a+long+password"))
                  .build(),
              HttpResponse.BodyHandlers.ofString());
      assertEquals(303, made.statusCode(), made.body());
      List<String> cookies = made.headers().allValues("set-cookie");
      assertFalse(cookies.isEmpty());
      HttpResponse<String> dashboard =
          client.send(
              HttpRequest.newBuilder(URI.create(base + "/"))
                  .header("cookie", cookies.get(0).split(";", -1)[0])
                  .build(),
              HttpResponse.BodyHandlers.ofString());
      assertEquals(200, dashboard.statusCode());
      assertTrue(dashboard.body().contains("data-sign-out=\"/logout\""));
    }
  }

  @Test
  void aSqliteFileGetsItsFolder() {
    sh.runlight.store.Stores.sqlite(root.resolve("data/deeper/runlight.db").toString()).migrate();
    assertTrue(Files.exists(root.resolve("data/deeper/runlight.db")));
  }

  private static byte[] gzip(byte[] bytes) {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    try (GZIPOutputStream zip = new GZIPOutputStream(out)) {
      zip.write(bytes);
    } catch (IOException e) {
      throw new IllegalStateException(e);
    }
    return out.toByteArray();
  }

  @Test
  void dbIpDownloadsThisMonthOrLastAndKeepsOnlyTheNewest() throws Exception {
    byte[] db =
        Base64.getDecoder()
            .decode(
                (String)
                    Js.map(Js.list(Fixtures.load("geo").get("databases")).get(0)).get("base64"));
    Path dir = root.resolve("geo");
    List<String> asked = new ArrayList<>();
    List<String> logged = new ArrayList<>();
    List<String> published = new ArrayList<>(List.of("2026-09"));
    Pattern release = Pattern.compile("lite-(\\d{4}-\\d{2})\\.mmdb\\.gz$");
    DbIp geo =
        new DbIp(
            dir,
            "city",
            (url, file) -> {
              asked.add(url);
              Matcher m = release.matcher(url);
              assertTrue(m.find());
              if (!published.contains(m.group(1))) {
                return false;
              }
              Files.write(file, gzip(db));
              return true;
            },
            logged::add);
    assertNull(geo.lookup(), "nothing to look up before the first download");

    long october = NOW;
    geo.refresh(october);
    assertEquals(
        List.of(
            "https://download.db-ip.com/free/dbip-city-lite-2026-10.mmdb.gz",
            "https://download.db-ip.com/free/dbip-city-lite-2026-09.mmdb.gz"),
        asked,
        "a month's file appears a day or so in, so last month's stands in");
    assertEquals(List.of("Runlight: location data from DB-IP (2026-09) is ready."), logged);
    assertEquals(dir.resolve("dbip-city-lite-2026-09.mmdb"), geo.newest());
    assertNotNull(geo.lookup());

    published.add("2026-10");
    asked.clear();
    geo.refresh(october);
    assertEquals(List.of("https://download.db-ip.com/free/dbip-city-lite-2026-10.mmdb.gz"), asked);
    try (Stream<Path> files = Files.list(dir)) {
      assertEquals(
          Set.of(dir.resolve("dbip-city-lite-2026-10.mmdb")),
          Set.copyOf(files.toList()),
          "older releases go");
    }
    asked.clear();
    geo.refresh(october);
    assertEquals(List.of(), asked, "once this month is there, nothing is fetched");

    // January's fallback is December of the year before, and a broken file is never kept.
    DbIp broken =
        new DbIp(
            dir,
            "country",
            (url, file) -> {
              Files.write(file, gzip("not a database".getBytes(StandardCharsets.UTF_8)));
              return true;
            },
            logged::add);
    broken.refresh(1_798_761_600_000L + 86_400_000L); // 2027-01-02
    assertTrue(
        logged.get(logged.size() - 1).contains("dbip-country-lite-2026-12.mmdb.gz"),
        logged.toString());
    assertNull(broken.newest());
  }
}
