package sh.runlight.server;

import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.io.PrintStream;
import java.net.InetSocketAddress;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.channels.OverlappingFileLockException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.function.LongSupplier;
import sh.runlight.Js;
import sh.runlight.Version;
import sh.runlight.accounts.Crypto;
import sh.runlight.http.Fetcher;

/**
 * Runlight as its own server, and its commands: the Java counterpart of {@code npx runlight.sh}
 * (packages/server's cli.ts) and of PHP's {@code vendor/bin/runlight}. With no command it serves
 * the dashboard, sites managed in it, accounts, and short links on the JDK's own HTTP server, and
 * runs the scheduled check every five minutes. The other commands run the check once from a
 * crontab, give someone locked out a new password, print the setup link, make the tables, and read
 * an access log for AI agents.
 *
 * <p>The core has no dependencies, so the database's JDBC driver goes on the class path beside the
 * jar: {@code java -cp runlight.jar:sqlite-jdbc.jar sh.runlight.server.Cli}.
 */
public final class Cli {
  private Cli() {}

  /** How the help names the command. */
  public static final String PROGRAM = "runlight";

  public static final String HELP =
      """
      Runlight %s, privacy friendly web analytics for any number of sites.

      Usage:
        runlight                      Start the server
        runlight cron                 Run the scheduled check once, and fetch this month's location data
        runlight password <email>     Make an account, or give one a new password
        runlight setup                Print the link that makes the first account
        runlight migrate              Create or update Runlight's tables
        runlight agents --log <file>  Count AI agents from a web server's access log
        runlight --version            Print the version

      runlight stands for the jar with your database's JDBC driver beside it on
      the class path, which the jar does not include:
        java -cp runlight.jar:sqlite-jdbc.jar sh.runlight.server.Cli
      Use sqlite-jdbc for SQLite (the default), the PostgreSQL JDBC driver for
      Postgres, and MySQL Connector/J or MariaDB Connector/J for MySQL and
      MariaDB. On Windows, separate the jars with ; instead of :. The agents
      command needs no driver, so java -jar runlight.jar agents works too.

      Settings are environment variables, or lines such as
      RUNLIGHT_URL=https://stats.example.com in runlight.properties in the working
      folder (or the file named by --config <file>, or RUNLIGHT_CONFIG); the
      environment wins. PORT (3000) and HOST (0.0.0.0) set where it listens.
      DATA_DIR (./runlight-data) holds the SQLite file, the secret, and the setup
      link, and DATABASE_URL switches to Postgres, MySQL, or MariaDB.
      RUNLIGHT_SECRET signs sessions and encrypts saved keys, RUNLIGHT_TOKEN also
      works as a bearer token on the API, and TRUST_PROXY=false ignores forwarded
      addresses when nothing sits in front.
      RUNLIGHT_URL is the dashboard's public address, such as
      https://stats.example.com, which short links can never take over.
      RUNLIGHT_GEO picks where locations come from when no platform header gives
      them. It is city by default, which downloads DB-IP's free city database into
      DATA_DIR and refreshes it each month. Set it to country for a smaller file, to
      off, or to the path of your own MMDB file. CRON_SECRET lets a scheduler run
      the check over HTTP, and RUNLIGHT_OBSERVE_KEY is one key for every site's AI
      agent reports.

      Docs: https://runlight.sh/docs/java/
      """;

  public static final String AGENTS_HELP =
      """
      Count AI agents on a site that has only the script tag, from its web server's log.

      Usage:
        runlight agents --log /var/log/nginx/access.log --to https://stats.example.com --key rlo_...

        --log <file>    The access log, in nginx or Apache's combined format, or Caddy's JSON
        --to <url>      Your Runlight, as its dashboard address (or RUNLIGHT_URL)
        --key <key>     The site's key from Settings, Install, Key for CMS plugins (or RUNLIGHT_OBSERVE_KEY)
        --site <url>    The site's address, such as https://example.com, when the log has no host in it
        --follow        Keep running and send fetches as they happen
        --state <file>  Remember where it stopped, so the next run, or a restarted --follow, starts there.
                        Only one run at a time can use it.

      Docs: https://runlight.sh/docs/java/#ai-agents-from-a-log
      """;

  /** Runs the command line, and exits with its code when that is not 0. */
  public static void main(String[] args) {
    int code =
        run(List.of(args), Path.of(""), System.out, System.err, System::currentTimeMillis, null);
    if (code != 0) {
      System.exit(code);
    }
  }

  /**
   * Runs one command and returns the exit code. The server ({@code serve}, {@code start}, or no
   * command) runs until the process is stopped.
   *
   * @param args the arguments after the program's name
   * @param root the project folder, which holds runlight.properties
   * @param now the clock, in milliseconds
   * @param fetcher reaches Runlight for the agents command, {@link sh.runlight.http.JdkFetcher}
   *     when null
   */
  public static int run(
      List<String> args,
      Path root,
      PrintStream out,
      PrintStream err,
      LongSupplier now,
      Fetcher fetcher) {
    List<String> rest = new ArrayList<>(args);
    String file = null;
    int at = rest.indexOf("--config");
    if (at >= 0) {
      if (at + 1 >= rest.size()) {
        err.print("Runlight: name the file after --config.\n");
        return 1;
      }
      file = Path.of(rest.get(at + 1)).toAbsolutePath().normalize().toString();
      rest.remove(at + 1);
      rest.remove(at);
    }
    String command = rest.isEmpty() ? "serve" : rest.get(0);
    switch (command) {
      case "help", "--help", "-h" -> {
        out.print(String.format(HELP, Version.version()));
        return 0;
      }
      case "--version", "-v" -> {
        out.print(Version.version() + "\n");
        return 0;
      }
      case "serve", "start", "cron", "check", "password", "setup", "agents", "migrate" -> {}
      default -> {
        err.print("Runlight: unknown command \"" + command + "\". Run " + PROGRAM + " --help.\n");
        return 1;
      }
    }
    if (command.equals("agents")) {
      try {
        return agents(rest.subList(1, rest.size()), root, file, out, err, now, fetcher);
      } catch (RuntimeException error) {
        err.print("Runlight: " + message(error) + "\n");
        return 1;
      }
    }
    Config config = null;
    try {
      config = new Config(root, file);
      switch (command) {
        case "serve", "start" -> {
          try (Serving serving = start(config, out, err, now)) {
            serving.await();
          }
          return 0;
        }
        case "cron", "check" -> {
          return cron(config, err, now);
        }
        case "password" -> {
          return password(config, rest.size() > 1 ? rest.get(1) : null, out, err, now);
        }
        case "setup" -> {
          return setup(config, out);
        }
        default -> {
          Standalone server = new Standalone(config.options(false).now(now));
          server.runlight.init();
          server.runlight.store.migrate(true);
          out.print("Runlight's tables are up to date in " + config.where() + ".\n");
          return 0;
        }
      }
    } catch (RuntimeException error) {
      err.print("Runlight: " + message(error) + "\n");
      return 1;
    } finally {
      if (config != null) {
        config.close();
      }
    }
  }

  /** An error's message without a "Runlight: " of its own, and how to add a missing driver. */
  private static String message(Throwable error) {
    String text = error.getMessage() != null ? error.getMessage() : error.toString();
    text = text.startsWith("Runlight: ") ? text.substring("Runlight: ".length()) : text;
    for (Throwable e = error; e != null; e = e.getCause()) {
      if (e.getMessage() != null && e.getMessage().contains("No suitable driver")) {
        return text
            + "\nPut the database's JDBC driver on the class path beside the jar, as in"
            + " java -cp runlight.jar:sqlite-jdbc.jar sh.runlight.server.Cli. "
            + PROGRAM
            + " --help says which.";
      }
    }
    return text;
  }

  /** The server running on the JDK's HTTP server, with its scheduled check. */
  public static final class Serving implements AutoCloseable {
    public final Standalone server;
    public final HttpServer http;
    private final ScheduledExecutorService timer;
    private final CountDownLatch stopped = new CountDownLatch(1);
    private final Thread hook;

    Serving(Standalone server, HttpServer http, ScheduledExecutorService timer) {
      this.server = server;
      this.http = http;
      this.timer = timer;
      this.hook = new Thread(this::stop, "runlight-stop");
    }

    /** The port it listens on. */
    public int port() {
      return http.getAddress().getPort();
    }

    /** Waits until the server is stopped, by close() or the process being told to stop. */
    public void await() {
      try {
        stopped.await();
      } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
      }
    }

    private synchronized void stop() {
      if (stopped.getCount() == 0) {
        return;
      }
      timer.shutdownNow();
      http.stop(1);
      stopped.countDown();
    }

    /**
     * Stops the server: the timer, the HTTP server (in-flight answers get a second), and the store.
     */
    @Override
    public synchronized void close() {
      stop();
      try {
        Runtime.getRuntime().removeShutdownHook(hook);
      } catch (IllegalStateException exiting) {
        // The process is already on its way out.
      }
    }
  }

  /**
   * Starts the server on PORT (3000) and HOST (0.0.0.0) as the settings say, prints where it
   * listens and, while there is no account, the link that makes the first one, and runs the
   * scheduled check (salts, email reports, retention, and rollups) and this month's location data
   * now, then every five minutes. The process being told to stop closes it.
   */
  public static Serving start(Config config, PrintStream out, PrintStream err, LongSupplier now) {
    Standalone.Options options = config.options(true).now(now);
    Standalone server = new Standalone(options);
    server.runlight.init();
    String portSetting = config.get("PORT");
    int port = (int) Js.toNumber(portSetting == null ? "3000" : portSetting);
    String host = config.get("HOST");
    host = host == null ? "0.0.0.0" : host;
    HttpServer http;
    try {
      http = HttpServer.create(new InetSocketAddress(host, port), 0);
    } catch (IOException e) {
      throw new IllegalStateException(
          "could not listen on " + host + ":" + port + ": " + e.getMessage(), e);
    }
    http.setExecutor(Executors.newVirtualThreadPerTaskExecutor());
    http.createContext("/", server.handler());
    http.start();
    int bound = http.getAddress().getPort();
    String shown = host.equals("0.0.0.0") || host.equals("::") ? "localhost" : host;
    out.print(
        "Runlight " + Version.version() + " is listening on http://" + shown + ":" + bound + "\n");
    out.print("Data: " + config.where() + "\n");
    if (server.accounts.count() == 0) {
      String url = config.url();
      String base = url != null ? url.replaceAll("/+\\z", "") : "http://" + shown + ":" + bound;
      out.print(
          options.setupCode != null
              ? "\nNo account yet. Open this link to create the first one:\n  "
                  + base
                  + "/setup?code="
                  + options.setupCode
                  + "\n\n"
              : "\nNo account yet. Open "
                  + base
                  + "/setup and enter RUNLIGHT_TOKEN to create the first one.\n\n");
    }
    out.flush();

    ScheduledExecutorService timer =
        Executors.newSingleThreadScheduledExecutor(
            work -> {
              Thread thread = new Thread(work, "runlight-check");
              thread.setDaemon(true);
              return thread;
            });
    DbIp dbIp = config.dbIp();
    Path setupFile = config.setupFile();
    var unused =
        timer.scheduleWithFixedDelay(
            () -> {
              try {
                server.check();
                // The setup link is no use once someone has an account.
                if (server.accounts.count() > 0) {
                  Files.deleteIfExists(setupFile);
                }
              } catch (IOException | RuntimeException error) {
                err.println("Runlight: the scheduled check failed " + error);
              }
              if (dbIp != null) {
                try {
                  dbIp.refresh(now.getAsLong());
                } catch (RuntimeException error) {
                  err.println("Runlight: could not refresh location data " + error);
                }
              }
            },
            0,
            5,
            TimeUnit.MINUTES);
    Serving serving = new Serving(server, http, timer);
    Runtime.getRuntime().addShutdownHook(serving.hook);
    return serving;
  }

  /**
   * The scheduled check (salts, email reports, retention, and rollups), then this month's location
   * data. Quiet when all is well, as cron likes. A run that starts while another is still going
   * leaves it to that one.
   */
  private static int cron(Config config, PrintStream err, LongSupplier now) {
    Path lockFile = config.dataDir().resolve("cron.lock");
    try (FileChannel channel =
        FileChannel.open(lockFile, StandardOpenOption.CREATE, StandardOpenOption.WRITE)) {
      FileLock lock;
      try {
        lock = channel.tryLock();
      } catch (OverlappingFileLockException held) {
        return 0;
      }
      if (lock == null) {
        return 0;
      }
      try (lock) {
        Standalone server = new Standalone(config.options(false).now(now));
        Map<String, Object> result = server.check();
        // The setup link is no use once someone has an account.
        if (Files.isRegularFile(config.setupFile()) && server.accounts.count() > 0) {
          Files.deleteIfExists(config.setupFile());
        }
        long failed = Js.asLong(Js.map(result.get("reports")).get("failed"));
        if (failed > 0) {
          err.print(
              "Runlight: "
                  + failed
                  + " email "
                  + (failed == 1 ? "report" : "reports")
                  + " could not be sent. The dashboard's Settings, Email reports, says why.\n");
        }
        DbIp dbIp = config.dbIp();
        if (dbIp != null) {
          dbIp.refresh(now.getAsLong());
        }
        return failed > 0 ? 1 : 0;
      }
    } catch (IOException e) {
      throw new IllegalStateException("could not run the check: " + e.getMessage(), e);
    }
  }

  /**
   * A new password for someone locked out, which also turns off their two-factor sign-in, since
   * someone at the server is who they say. It makes the account when there is none: the owner on a
   * server with nobody yet, and an admin otherwise.
   */
  private static int password(
      Config config, String email, PrintStream out, PrintStream err, LongSupplier now) {
    if (email == null || Js.trim(email).isEmpty()) {
      err.print("Runlight: name the account, as in " + PROGRAM + " password you@example.com\n");
      return 1;
    }
    Standalone server = new Standalone(config.options(false).now(now));
    server.runlight.init();
    String password = Crypto.base64url(Crypto.randomBytes(12));
    boolean existed = server.accounts.byEmail(email) != null;
    Map<String, Object> user = server.accounts.setPassword(email, password, now.getAsLong());
    boolean reset = Boolean.TRUE.equals(user.get("twoFactor"));
    if (reset) {
      server.accounts.disableTwoFactor((String) user.get("id"));
    }
    String who = Js.lower(Js.trim(email));
    out.print(
        (existed
                ? "New password"
                : "Account made, as "
                    + ("owner".equals(user.get("role")) ? "the owner" : "an admin")
                    + ",")
            + " for "
            + who
            + ": "
            + password
            + "\n"
            + (reset
                ? "Two-factor sign-in is now off for this account; turn it on again under Account.\n"
                : "")
            + "Sign in, and change it by running this again whenever you like.\n");
    return 0;
  }

  /**
   * Reads a web server's access log and sends the AI agent fetches in it to a Runlight, as {@code
   * npx runlight.sh agents} does. --to and --key default to RUNLIGHT_URL and RUNLIGHT_OBSERVE_KEY,
   * from the environment or runlight.properties. With --follow it runs until it is stopped, and a
   * stop releases the state file's lock on the way out.
   */
  private static int agents(
      List<String> args,
      Path root,
      String file,
      PrintStream out,
      PrintStream err,
      LongSupplier now,
      Fetcher fetcher) {
    if (args.contains("--help") || args.contains("-h")) {
      out.print(AGENTS_HELP);
      return 0;
    }
    String log = flag(args, "log");
    String to = flag(args, "to");
    String key = flag(args, "key");
    if (to == null || key == null) {
      Config config = new Config(root, file);
      to = to != null ? to : config.get("RUNLIGHT_URL");
      key = key != null ? key : config.get("RUNLIGHT_OBSERVE_KEY");
    }
    if (log == null
        || log.isEmpty()
        || to == null
        || to.isEmpty()
        || key == null
        || key.isEmpty()) {
      err.print(AGENTS_HELP);
      return 1;
    }
    String site = flag(args, "site");
    String state = flag(args, "state");
    Agents.Options options =
        new Agents.Options()
            .log(absolute(log))
            .to(to)
            .key(key)
            .follow(args.contains("--follow"))
            .out(line -> out.print(line + "\n"))
            .now(now)
            .fetcher(fetcher);
    if (site != null && !site.isEmpty()) {
      options.site(site);
    }
    if (state != null && !state.isEmpty()) {
      options.state(absolute(state));
    }
    Agents.run(options);
    return 0;
  }

  private static String flag(List<String> args, String name) {
    int at = args.indexOf("--" + name);
    return at >= 0 && at + 1 < args.size() ? args.get(at + 1) : null;
  }

  /** A path made absolute from the working folder, with . and .. resolved, as path.resolve does. */
  private static String absolute(String path) {
    return Path.of(path).toAbsolutePath().normalize().toString();
  }

  private static int setup(Config config, PrintStream out) {
    Standalone server = new Standalone(config.options(false));
    server.runlight.init();
    if (server.accounts.count() > 0) {
      out.print(
          "Runlight already has an account. To get into one, run "
              + PROGRAM
              + " password <email>.\n");
      return 0;
    }
    if (config.get("RUNLIGHT_TOKEN") != null) {
      out.print(
          "Open /setup at your Runlight's address and enter RUNLIGHT_TOKEN to create the first account.\n");
      return 0;
    }
    config.setupCode();
    try {
      out.print(Files.readString(config.setupFile()));
    } catch (IOException e) {
      throw new IllegalStateException("could not read " + config.setupFile(), e);
    }
    if (config.url() == null) {
      out.print(
          "Put your Runlight's own address in place of https://your-runlight-address, or set RUNLIGHT_URL.\n");
    }
    return 0;
  }
}
