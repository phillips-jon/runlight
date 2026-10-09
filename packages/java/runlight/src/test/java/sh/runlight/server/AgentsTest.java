package sh.runlight.server;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assumptions.assumeFalse;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.PosixFilePermissions;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.function.BiFunction;
import java.util.function.LongSupplier;
import java.util.stream.Collectors;
import java.util.stream.IntStream;
import java.util.stream.Stream;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import sh.runlight.Env;
import sh.runlight.Fixtures;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.RecordingFetcher;
import sh.runlight.Routes;
import sh.runlight.Runlight;
import sh.runlight.http.FetchError;
import sh.runlight.http.FetchInit;
import sh.runlight.http.Request;
import sh.runlight.http.Response;
import sh.runlight.store.Stores;

/** The port of the Node server's agents.test.ts: the access log reader that counts AI agents. */
class AgentsTest {
  private static final String GPTBOT =
      "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2; +https://openai.com/gptbot)";
  private static final String CLAUDE =
      "Mozilla/5.0 (compatible; ClaudeBot/1.0; +claudebot@anthropic.com)";
  private static final String CHROME =
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36";
  private static final String TIME = "07/Oct/2026:13:55:36 -0400";

  private Path dir;

  @BeforeEach
  void setUp() throws IOException {
    dir = Files.createTempDirectory("runlight-agents-");
  }

  @AfterEach
  void tearDown() throws IOException {
    Env.reset();
    Path log = dir.resolve("access.log");
    if (Files.exists(log)) {
      Files.setPosixFilePermissions(log, PosixFilePermissions.fromString("rw-r--r--"));
    }
    try (Stream<Path> files = Files.list(dir)) {
      for (Path file : files.toList()) {
        Files.delete(file);
      }
    }
    Files.delete(dir);
  }

  private static String line(String path, String ua) {
    return line(path, ua, 200, "GET", TIME, "");
  }

  private static String line(
      String path, String ua, int status, String method, String time, String vhost) {
    return (vhost.isEmpty() ? "" : vhost + " ")
        + "203.0.113.9 - - ["
        + time
        + "] \""
        + method
        + " "
        + path
        + " HTTP/1.1\" "
        + status
        + " 5120 \"-\" \""
        + ua
        + "\"";
  }

  private static long utc(int y, int m, int d, int h, int i, int s) {
    return LocalDateTime.of(y, m, d, h, i, s).toInstant(ZoneOffset.UTC).toEpochMilli();
  }

  private List<String> files() throws IOException {
    try (Stream<Path> files = Files.list(dir)) {
      return files.map(p -> p.getFileName().toString()).sorted().toList();
    }
  }

  private static void write(Path file, String text) throws IOException {
    Files.writeString(file, text, StandardCharsets.ISO_8859_1);
  }

  private static void append(Path file, String text) throws IOException {
    Files.writeString(
        file, text, StandardCharsets.UTF_8, StandardOpenOption.CREATE, StandardOpenOption.APPEND);
  }

  private static String lines(int count) {
    return IntStream.range(0, count)
        .mapToObj(i -> line("/p" + i, GPTBOT) + "\n")
        .collect(Collectors.joining());
  }

  /** A Runlight that takes reports for example.com with the key rlo_site, and its routes. */
  private record Target(Runlight rl, RecordingFetcher fetcher) {
    List<Map<String, Object>> fetches() {
      return rl.store
          .db()
          .all("SELECT path, name, ts FROM rl_events WHERE kind = 'fetch' ORDER BY ts, path");
    }

    List<String> paths() {
      List<String> out = new ArrayList<>();
      for (Map<String, Object> row : fetches()) {
        out.add((String) row.get("path"));
      }
      return out;
    }
  }

  private static Target runlight() {
    long now = utc(2026, 10, 7, 18, 0, 0);
    Runlight rl =
        new Runlight(
            new Runlight.Options()
                .store(Stores.sqlite(":memory:"))
                .site(Json.object("hostnames", Json.array("example.com")))
                .now(() -> now));
    rl.init();
    rl.store.setSetting("observe-key:default", "rlo_site");
    Routes routes = rl.routes(new Routes.Options().token("owner"));
    RecordingFetcher fetcher =
        new RecordingFetcher(
            (url, init) ->
                routes.handle(new Request(url, init.method, init.headers, init.body, "")));
    return new Target(rl, fetcher);
  }

  /** How many fetches a small server kept and how many batches it was sent. */
  private static final class Counter {
    long stored;
    int posts;
  }

  /**
   * A Fetcher like a small server that keeps each batch, answering with how many it took, unless
   * {@code answer} gives an answer of its own for this post, given its number.
   */
  private static RecordingFetcher counter(
      Counter counter, BiFunction<Integer, Integer, Response> answer) {
    return new RecordingFetcher(
        (String url, FetchInit init) -> {
          counter.posts++;
          int n = Js.list(Js.map(Json.parse(init.bodyText())).get("fetches")).size();
          Response own = answer != null ? answer.apply(counter.posts, n) : null;
          if (own != null) {
            return own;
          }
          counter.stored += n;
          return Response.json(Json.object("recorded", (long) n));
        });
  }

  private Agents.Options options(Path log, RecordingFetcher fetcher) {
    return new Agents.Options()
        .log(log.toString())
        .to("http://127.0.0.1:9")
        .key("k")
        .site("https://example.com")
        .fetcher(fetcher)
        .out(said -> {});
  }

  @Test
  void logLinesNginxAndApacheCombinedAVhostColumnAndCaddysJson() {
    assertEquals(
        Json.stringify(
            Json.object(
                "method",
                "GET",
                "url",
                "https://example.com/blog/post?x=1",
                "status",
                200L,
                "userAgent",
                GPTBOT,
                "at",
                utc(2026, 10, 7, 17, 55, 36))),
        Json.stringify(Agents.parseLine(line("/blog/post?x=1", GPTBOT), "https://example.com")));
    assertNull(
        Agents.parseLine(line("/", GPTBOT)), "with no host anywhere there is no page to name");
    assertEquals(
        "https://blog.example.com/",
        Agents.parseLine(line("/", GPTBOT, 200, "GET", TIME, "blog.example.com:443")).get("url"));
    String caddy =
        Json.stringify(
            Json.object(
                "ts",
                1791399336.5,
                "status",
                200L,
                "request",
                Json.object(
                    "method",
                    "GET",
                    "host",
                    "example.com",
                    "uri",
                    "/docs/",
                    "tls",
                    Json.object(),
                    "headers",
                    Json.object("User-Agent", Json.array(CLAUDE)))));
    assertEquals(
        Json.stringify(
            Json.object(
                "method",
                "GET",
                "url",
                "https://example.com/docs/",
                "status",
                200L,
                "userAgent",
                CLAUDE,
                "at",
                1791399336500L)),
        Json.stringify(Agents.parseLine(caddy)));
    assertNull(Agents.parseLine("not a log line"));
    // A target is a path and query on the site, never read as an address: a backslash cannot name
    // another host.
    assertEquals(
        "https://example.com//evil.example/x?y=1",
        Agents.parseLine(line("/\\evil.example/x?y=1", GPTBOT), "https://example.com").get("url"));
    assertEquals(
        "https://example.com/evil.example/x",
        Agents.parseLine(line("//evil.example/x", GPTBOT), "https://example.com").get("url"));

    // Only successful GETs from AI agents are worth sending.
    assertNotNull(Agents.agentFetch(line("/", GPTBOT), "https://example.com"));
    assertNull(
        Agents.agentFetch(line("/", CHROME), "https://example.com"),
        "people are the tracker's job");
    assertNull(Agents.agentFetch(line("/", GPTBOT, 404, "GET", TIME, ""), "https://example.com"));
    assertNull(Agents.agentFetch(line("/", GPTBOT, 200, "POST", TIME, ""), "https://example.com"));
  }

  @Test
  void linesAreReadAsTheNodeCommandReadsThem() {
    Map<String, Object> fixture = Fixtures.load("agents");
    long now = Js.asLong(fixture.get("now"));
    for (Map<String, Object> c : Fixtures.cases(fixture, "cases")) {
      String site = c.get("site") instanceof String s ? s : null;
      Map<String, Object> parsed = Agents.parseLine((String) c.get("line"), site);
      if (parsed != null && parsed.get("at") instanceof Double at && at.isNaN()) {
        parsed.put("at", "NaN");
      }
      Fixtures.assertJson(c.get("parsed"), parsed, Fixtures.label(c));
      Fixtures.assertJson(
          c.get("fetched"),
          Agents.agentFetch((String) c.get("line"), site, () -> now),
          Fixtures.label(c));
    }
  }

  @Test
  void aLogIsReadOnceCarriesOnWhereItStoppedAndStartsOverAfterRotation() throws IOException {
    Target target = runlight();
    String to = "http://127.0.0.1:9/runlight";
    Path log = dir.resolve("access.log");
    Path state = dir.resolve("state.json");
    LongSupplier run =
        () ->
            Agents.run(
                options(log, target.fetcher()).to(to).key("rlo_site").state(state.toString()));

    write(
        log,
        String.join(
            "\n",
            line("/a", GPTBOT),
            line("/b", CHROME),
            line("/c", CLAUDE, 200, "GET", "07/Oct/2026:13:56:00 -0400", ""),
            line("/style.css", GPTBOT),
            ""));
    assertEquals(2, run.getAsLong(), "two pages count; the stylesheet and the person do not");
    List<Map<String, Object>> first = target.fetches();
    assertEquals(
        List.of(List.of("/a", "GPTBot"), List.of("/c", "ClaudeBot")),
        first.stream().map(f -> List.of(f.get("path"), f.get("name"))).toList(),
        "Runlight keeps pages, not their assets");
    assertEquals(
        utc(2026, 10, 7, 17, 55, 36),
        Js.asLong(first.get(0).get("ts")),
        "counted when the page was served");
    Map<String, Object> sent = target.fetcher().requests.get(0);
    assertEquals("Bearer rlo_site", Js.map(sent.get("headers")).get("authorization"));
    assertEquals("http://127.0.0.1:9/runlight/api/observe", sent.get("url"));

    assertEquals(0, run.getAsLong(), "nothing new, nothing sent");
    append(log, line("/d", GPTBOT) + "\n");
    assertEquals(1, run.getAsLong());

    Files.move(log, dir.resolve("access.log.1"));
    write(log, line("/e", CLAUDE) + "\n");
    assertEquals(1, run.getAsLong(), "a rotated log is read from the top");
    assertEquals(List.of("/a", "/c", "/d", "/e"), target.paths().stream().sorted().toList());
    Files.delete(dir.resolve("access.log.1"));

    RuntimeException refused =
        assertThrows(
            RuntimeException.class,
            () -> Agents.run(options(log, target.fetcher()).to(to).key("rlo_wrong")),
            "a wrong key is refused");
    assertTrue(refused.getMessage().contains("refused the key"), refused.getMessage());

    // Lines for another host, a // path, an absolute target, an old line, and a bad byte: none
    // stops the rest.
    int before = target.fetches().size();
    write(
        log,
        line("/f", GPTBOT, 200, "GET", "07/Oct/2026:13:57:00 -0400", "other.example:443")
            + "\n"
            + line("//g", GPTBOT)
            + "\n"
            + line("http://evil.example/h", GPTBOT)
            + "\n"
            + line("/old", GPTBOT, 200, "GET", "01/Sep/2026:10:00:00 -0400", "")
            + "\n"
            + "ÿþ\n"
            + line("/i", CLAUDE)
            + "\n");
    assertEquals(
        2,
        run.getAsLong(),
        "/g and /i count; the other host, the absolute target, and the old line do not");
    List<String> paths = target.paths();
    assertEquals(before + 2, paths.size());
    assertTrue(paths.contains("/g"));
    assertTrue(paths.contains("/i"));
    assertFalse(paths.contains("/f"));
    assertFalse(paths.contains("/h"));
    assertFalse(paths.contains("/old"));
    assertEquals(
        0,
        run.getAsLong(),
        "the offset after a bad byte lands on the next line, so nothing is sent twice");

    // Rotated by copying and truncating: the same file, a new start, already longer than the old
    // place.
    write(log, line("/one", GPTBOT) + "\n");
    assertEquals(1, run.getAsLong());
    write(log, line("/two", CLAUDE) + "\n" + line("/three", GPTBOT) + "\n");
    assertEquals(2, run.getAsLong(), "both lines of the new log, none skipped");
  }

  @Test
  void followingALogReadsWhatWasWrittenJustBeforeARotationThenTheNewLog() throws IOException {
    Target target = runlight();
    Path log = dir.resolve("access.log");
    write(log, "");
    int[] polls = {0};
    List<String> said = new ArrayList<>();
    Agents.run(
        options(log, target.fetcher())
            .to("http://127.0.0.1:9/runlight")
            .key("rlo_site")
            .follow(true)
            // Each look at the log waits first; the steps run in that wait, as another process
            // writing the log would.
            .sleep(
                ms -> {
                  polls[0]++;
                  if (polls[0] == 2) {
                    try {
                      append(log, line("/before", GPTBOT) + "\n");
                      // Rotated before the reader looks again: the last line is in the renamed
                      // file only.
                      append(log, line("/last-old", CLAUDE) + "\n");
                      Files.move(log, dir.resolve("access.log.1"));
                      write(log, line("/new", GPTBOT) + "\n");
                    } catch (IOException e) {
                      throw new IllegalStateException(e);
                    }
                  }
                })
            .stop(() -> polls[0] >= 6)
            .out(said::add));
    assertEquals(
        List.of("/before", "/last-old", "/new"), target.paths().stream().sorted().toList());
    assertEquals(
        "Following " + log + ". AI agent fetches go to http://127.0.0.1:9/runlight as they happen.",
        said.get(0));
    assertEquals(
        List.of("Sent 2 AI agent fetches.", "Sent 1 AI agent fetches."),
        said.subList(1, said.size()));
  }

  @Test
  void aFailedBatchSendsNoneOfTheEarlierOnesAgainAndABadStateFileStartsOverWithAWord()
      throws IOException {
    Counter counter = new Counter();
    int[] failAt = {0};
    RecordingFetcher fetcher =
        counter(counter, (post, n) -> post == failAt[0] ? new Response("busy", 503) : null);
    Path log = dir.resolve("access.log");
    Path state = dir.resolve("state.json");
    write(log, lines(1200));
    failAt[0] = 2;
    RuntimeException failed =
        assertThrows(
            RuntimeException.class,
            () -> Agents.run(options(log, fetcher).state(state.toString())),
            "the second batch fails");
    assertEquals("Runlight answered 503: busy", failed.getMessage());
    assertEquals(500, counter.stored, "the first batch went");
    Agents.run(options(log, fetcher).state(state.toString()));
    assertEquals(1200, counter.stored, "each line once");

    write(state, "{ not json");
    List<String> said = new ArrayList<>();
    counter.stored = 0;
    Agents.run(options(log, fetcher).state(state.toString()).out(said::add));
    assertTrue(said.get(0).matches("^Could not read .*state\\.json.*"), said.get(0));
    assertEquals("Sent 1200 AI agent fetches from 1200 new lines.", said.get(1));
    assertEquals(1200, counter.stored, "read from the top");
    assertEquals(
        Files.size(log), Js.asLong(Js.map(Json.parse(Files.readString(state))).get("offset")));
  }

  @Test
  void linesWithNoHostAndNoSiteAreMentionedOnce() throws IOException {
    Counter counter = new Counter();
    Path log = dir.resolve("access.log");
    write(log, line("/a", GPTBOT) + "\n" + line("/b", GPTBOT) + "\n");
    List<String> said = new ArrayList<>();
    long sent = Agents.run(options(log, counter(counter, null)).site(null).out(said::add));
    assertEquals(0, sent);
    assertEquals(
        List.of(
            "Some lines have no host in them. Add --site https://your-site.example so they can be counted.",
            "Sent 0 AI agent fetches from 2 new lines."),
        said);
    assertEquals(0, counter.posts);
  }

  @Test
  void oneRunAtATimeUsesAStateFileACrashedRunsLockIsTakenOverAndTheStateIsWrittenWhole()
      throws Exception {
    Counter counter = new Counter();
    Path log = dir.resolve("access.log");
    Path state = dir.resolve("state.json");
    String[] second = {null};
    Runnable[] run = {null};
    // While the first run sends its first batch, a second one starts on the same state file.
    RecordingFetcher fetcher =
        counter(
            counter,
            (post, n) -> {
              if (post == 1) {
                try {
                  run[0].run();
                  second[0] = "ran";
                } catch (RuntimeException error) {
                  second[0] = error.getMessage();
                }
              }
              return null;
            });
    long[] last = {0};
    run[0] = () -> last[0] = Agents.run(options(log, fetcher).state(state.toString()));
    write(log, lines(1500));
    run[0].run();
    assertEquals(1500, last[0]);
    String pid = Long.toString(ProcessHandle.current().pid());
    assertTrue(
        second[0].matches(
            "^Another run is using .*state\\.json \\(process \\d+\\)\\. Wait for it to finish, or delete .*state\\.json\\.lock if none is running\\.$"),
        second[0]);
    assertEquals(1500, counter.stored, "each line once");
    assertEquals(
        List.of("access.log", "state.json"),
        files(),
        "the lock is released and no temporary file is left");

    // A lock from a process that has ended is stale.
    Process child = new ProcessBuilder("true").start();
    child.waitFor();
    long ended = child.pid();
    write(dir.resolve("state.json.lock"), Long.toString(ended));
    append(log, line("/late", GPTBOT) + "\n");
    run[0].run();
    assertEquals(1, last[0]);
    assertEquals(1501, counter.stored);
    assertEquals(List.of("access.log", "state.json"), files());

    // A lock held by a running process is left alone.
    write(dir.resolve("state.json.lock"), pid);
    RuntimeException held = assertThrows(RuntimeException.class, run[0]::run, "the lock is held");
    assertTrue(held.getMessage().contains("(process " + pid + ")"), held.getMessage());
    assertEquals(pid, Files.readString(dir.resolve("state.json.lock")));
    Files.delete(dir.resolve("state.json.lock"));
  }

  @Test
  void followingALogThatCannotBeReadWaitsAndSaysSoAndARestartReadsALogRotatedMeanwhileFromItsStart()
      throws IOException {
    assumeFalse("root".equals(System.getProperty("user.name")), "root reads every file");
    Counter counter = new Counter();
    RecordingFetcher fetcher = counter(counter, null);
    Path log = dir.resolve("access.log");
    Path state = dir.resolve("state.json");
    write(log, "");
    int[] polls = {0};
    List<String> said = new ArrayList<>();
    Agents.run(
        options(log, fetcher)
            .state(state.toString())
            .follow(true)
            .sleep(
                ms -> {
                  polls[0]++;
                  try {
                    switch (polls[0]) {
                      case 2 -> append(log, line("/a", GPTBOT) + "\n");
                      case 4 ->
                          Files.setPosixFilePermissions(
                              log, PosixFilePermissions.fromString("---------"));
                      case 8 -> {
                        Files.setPosixFilePermissions(
                            log, PosixFilePermissions.fromString("rw-r--r--"));
                        append(log, line("/b", GPTBOT) + "\n");
                      }
                      default -> {}
                    }
                  } catch (IOException e) {
                    throw new IllegalStateException(e);
                  }
                })
            .stop(() -> polls[0] >= 10)
            .out(said::add));
    assertEquals(2, counter.stored, "it carried on once the log could be read again");
    assertEquals(
        1,
        said.stream().filter(l -> l.startsWith("Could not read")).count(),
        "said once, not every poll");
    assertEquals(0, said.stream().filter(l -> l.startsWith("Could not send")).count());

    // Stopped, then the log was rotated: everything in the new log is unread.
    Files.move(log, dir.resolve("access.log.1"));
    write(log, line("/c", GPTBOT) + "\n" + line("/d", GPTBOT) + "\n");
    polls[0] = 0;
    Agents.run(
        options(log, fetcher)
            .state(state.toString())
            .follow(true)
            .sleep(ms -> polls[0]++)
            .stop(() -> polls[0] >= 3));
    assertEquals(4, counter.stored);
    assertEquals(List.of("access.log", "access.log.1", "state.json"), files());
  }

  @Test
  void aSendThatCannotReachRunlightIsTriedAgainOnTheNextLook() throws IOException {
    Counter counter = new Counter();
    RecordingFetcher fetcher =
        counter(
            counter,
            (post, n) -> {
              if (post <= 2) {
                throw new FetchError("Could not connect");
              }
              return null;
            });
    Path log = dir.resolve("access.log");
    write(log, "");
    int[] polls = {0};
    List<String> said = new ArrayList<>();
    Agents.run(
        options(log, fetcher)
            .follow(true)
            .sleep(
                ms -> {
                  if (++polls[0] == 1) {
                    try {
                      write(log, line("/a", GPTBOT) + "\n");
                    } catch (IOException e) {
                      throw new IllegalStateException(e);
                    }
                  }
                })
            .stop(() -> polls[0] >= 4)
            .out(said::add));
    assertEquals(1, counter.stored);
    assertEquals(
        List.of(
            "Could not send, trying again shortly: Could not connect", "Sent 1 AI agent fetches."),
        said.subList(1, said.size()));
  }

  @Test
  void theCommandLine() throws IOException {
    record Ran(int code, String out, String err, RecordingFetcher fetcher) {}
    BiFunction<Path, String[], Ran> cli =
        (root, args) -> {
          ByteArrayOutputStream out = new ByteArrayOutputStream();
          ByteArrayOutputStream err = new ByteArrayOutputStream();
          RecordingFetcher fetcher = counter(new Counter(), null);
          int code =
              Cli.run(
                  List.of(args),
                  root,
                  new PrintStream(out, true, StandardCharsets.UTF_8),
                  new PrintStream(err, true, StandardCharsets.UTF_8),
                  () -> 1_791_374_400_000L,
                  fetcher);
          return new Ran(
              code,
              out.toString(StandardCharsets.UTF_8),
              err.toString(StandardCharsets.UTF_8),
              fetcher);
        };
    Ran help = cli.apply(dir, new String[] {"agents", "--help"});
    assertEquals(0, help.code());
    assertEquals(Cli.AGENTS_HELP, help.out());
    Ran missing = cli.apply(dir, new String[] {"agents", "--log", "access.log"});
    assertEquals(1, missing.code(), "no address and no key");
    assertEquals(Cli.AGENTS_HELP, missing.err());
    assertTrue(
        cli.apply(dir, new String[] {"--help"})
            .out()
            .contains("agents --log <file>  Count AI agents from a web server's access log"));

    Path log = dir.resolve("access.log");
    write(log, line("/a", GPTBOT) + "\n");
    Ran noLog =
        cli.apply(
            dir,
            new String[] {
              "agents",
              "--log",
              dir + "/missing.log",
              "--to",
              "https://stats.example.com",
              "--key",
              "k"
            });
    assertEquals(1, noLog.code());
    assertEquals("Runlight: No log at " + dir + "/missing.log\n", noLog.err());

    // --to and --key come from runlight.properties when they are not given.
    write(
        dir.resolve("runlight.properties"),
        "RUNLIGHT_URL = https://stats.example.com/\nRUNLIGHT_OBSERVE_KEY=rlo_all\n");
    Ran ran =
        cli.apply(
            dir,
            new String[] {
              "agents",
              "--log",
              dir + "/./access.log",
              "--site",
              "https://example.com",
              "--state",
              dir + "/state.json"
            });
    assertEquals(
        List.of(0, "Sent 1 AI agent fetches from 1 new lines.\n", ""),
        List.of(ran.code(), ran.out(), ran.err()));
    Map<String, Object> sent = ran.fetcher().requests.get(0);
    assertEquals("https://stats.example.com/api/observe", sent.get("url"));
    assertEquals("Bearer rlo_all", Js.map(sent.get("headers")).get("authorization"));
    assertEquals(
        Json.stringify(
            Json.object(
                "fetches",
                Json.array(
                    Json.object(
                        "url",
                        "https://example.com/a",
                        "userAgent",
                        GPTBOT,
                        "at",
                        utc(2026, 10, 7, 17, 55, 36))))),
        sent.get("body"));
    Map<String, Object> saved = Js.map(Json.parse(Files.readString(dir.resolve("state.json"))));
    assertEquals(List.of("ino", "offset", "head", "length"), List.copyOf(saved.keySet()));
    assertEquals(Files.size(log), Js.asLong(saved.get("offset")));
    Files.delete(dir.resolve("runlight.properties"));
  }
}
