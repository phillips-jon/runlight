package sh.runlight.server;

import java.io.IOException;
import java.io.Reader;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.FileAlreadyExistsException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.PosixFilePermissions;
import java.util.Locale;
import java.util.Properties;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import sh.runlight.Env;
import sh.runlight.Geo;
import sh.runlight.Hash;
import sh.runlight.Js;
import sh.runlight.accounts.Web;
import sh.runlight.store.SqlStore;
import sh.runlight.store.Stores;

/**
 * The standalone server's settings, as {@code runlight serve} and the other commands read them:
 * environment variables first, then a runlight.properties in the project folder (the working
 * folder, unless the command is told another) that sets the same names, one {@code NAME=value} a
 * line.
 *
 * <pre>
 *   PORT                  where to listen (3000)
 *   HOST                  which address to listen on (0.0.0.0)
 *   DATA_DIR              the SQLite file, the secret, the setup link, and location data (./runlight-data)
 *   DATABASE_URL          a postgres://, mysql://, or mariadb:// URL, to use that database instead of SQLite
 *   RUNLIGHT_SECRET       signs sessions and encrypts saved keys (made and kept in DATA_DIR if unset)
 *   RUNLIGHT_TOKEN        also accepted as a bearer token on the API, and makes the first account
 *   RUNLIGHT_URL          the dashboard's public address, which can never become a link domain
 *   TRUST_PROXY           "false" when no proxy sits in front, so forwarded addresses are ignored
 *   RUNLIGHT_GEO          city (the default), country, off, or the path to an MMDB file
 *   CRON_SECRET           lets a scheduler run the check over HTTP, at POST /api/check
 *   RUNLIGHT_OBSERVE_KEY  one key for every site's AI agent reports
 * </pre>
 *
 * <p>Relative paths are read from the project folder. This is the port of PHP's Server/Config.php,
 * whose config.php becomes runlight.properties.
 */
public final class Config implements AutoCloseable {
  /** The settings file read from the project folder when no other is named. */
  public static final String FILE = "runlight.properties";

  private static final Pattern URL = Pattern.compile("^https?://[^/?#]+/?\\z");
  private static final Pattern SETUP_LINK = Pattern.compile("/setup\\?code=([A-Za-z0-9_-]+)");
  private static final Pattern POSTGRES =
      Pattern.compile("^postgres(ql)?://", Pattern.CASE_INSENSITIVE);
  private static final Pattern MYSQL = Pattern.compile("^mysql://", Pattern.CASE_INSENSITIVE);
  private static final Pattern MARIADB = Pattern.compile("^mariadb://", Pattern.CASE_INSENSITIVE);

  /** The project folder, which holds runlight.properties. */
  public final Path root;

  private final Properties file = new Properties();
  private String secret;
  private SqlStore store;

  /**
   * Settings from the environment and a properties file.
   *
   * @param root the project folder, which holds runlight.properties
   * @param named a properties file elsewhere, or null; RUNLIGHT_CONFIG names one too
   */
  public Config(Path root, String named) {
    this.root = root.toAbsolutePath().normalize();
    String given = named != null ? named : Env.get("RUNLIGHT_CONFIG");
    Path path = given != null ? path(given) : this.root.resolve(FILE);
    if (Files.isRegularFile(path)) {
      try (Reader reader = Files.newBufferedReader(path, StandardCharsets.UTF_8)) {
        file.load(reader);
      } catch (IOException | IllegalArgumentException e) {
        throw new IllegalStateException(
            "Runlight: could not read "
                + path
                + ". Write one setting a line, such as RUNLIGHT_URL=https://stats.example.com",
            e);
      }
    } else if (given != null) {
      throw new IllegalStateException("Runlight: there is no config file at " + path);
    }
  }

  /** Settings from the environment and the project folder's runlight.properties. */
  public Config(Path root) {
    this(root, null);
  }

  /** A setting: the environment's, else the file's, trimmed, with nothing for an empty one. */
  public String get(String name) {
    String value = Env.get(name);
    if (value != null) {
      return value;
    }
    String given = file.getProperty(name);
    if (given == null) {
      return null;
    }
    given = Js.trim(given);
    return given.isEmpty() ? null : given;
  }

  /** A path from a setting, read from the project folder when it is relative. */
  private Path path(String value) {
    return root.resolve(value).normalize();
  }

  /** The data folder, made on first use and readable only by this user. */
  public Path dataDir() {
    Path dir = dataPath();
    if (!Files.isDirectory(dir)) {
      try {
        Files.createDirectories(dir);
        restrict(dir, "rwx------");
      } catch (IOException e) {
        if (!Files.isDirectory(dir)) {
          throw new IllegalStateException(
              "Runlight: could not make the data folder "
                  + dir
                  + ". Make it, writable by this user, or set DATA_DIR.",
              e);
        }
      }
    }
    return dir;
  }

  private static void restrict(Path path, String permissions) {
    try {
      Files.setPosixFilePermissions(path, PosixFilePermissions.fromString(permissions));
    } catch (IOException | UnsupportedOperationException e) {
      // A file system without POSIX permissions keeps its own.
    }
  }

  private Path dataPath() {
    String dir = get("DATA_DIR");
    return path(dir != null ? dir : "runlight-data");
  }

  /** Where the data lives, for messages. */
  public String where() {
    String url = get("DATABASE_URL");
    url = url == null ? "" : url;
    if (POSTGRES.matcher(url).find()) {
      return "Postgres";
    }
    if (MYSQL.matcher(url).find()) {
      return "MySQL";
    }
    if (MARIADB.matcher(url).find()) {
      return "MariaDB";
    }
    return !url.isEmpty() ? url : dataPath().resolve("runlight.db").toString();
  }

  /** The store DATABASE_URL names, or SQLite in the data folder. Made once. */
  public synchronized SqlStore store() {
    if (store == null) {
      String url = get("DATABASE_URL");
      store =
          url != null
              ? Stores.url(url)
              : Stores.sqlite(dataDir().resolve("runlight.db").toString());
    }
    return store;
  }

  /** Closes the store, when one was opened. */
  @Override
  public synchronized void close() {
    if (store != null) {
      store.close();
      store = null;
    }
  }

  /**
   * RUNLIGHT_SECRET, or one made on first use and kept beside the data, readable only by this user.
   */
  public synchronized String secret() {
    if (secret != null) {
      return secret;
    }
    String given = get("RUNLIGHT_SECRET");
    if (given != null) {
      return secret = given;
    }
    Path path = dataDir().resolve("secret");
    String saved = read(path);
    if (!saved.isEmpty()) {
      return secret = saved;
    }
    String made = Hash.randomId(32);
    // Made once: whoever writes the file first wins, and everyone else reads theirs.
    if (!create(path, made + "\n")) {
      pause();
      saved = read(path);
      if (saved.isEmpty()) {
        throw new IllegalStateException(
            "Runlight: could not write "
                + path
                + ". Make the data folder writable, or set RUNLIGHT_SECRET.");
      }
      return secret = saved;
    }
    return secret = made;
  }

  /** A file's text, trimmed, or "" when there is none. */
  private static String read(Path path) {
    try {
      return Files.isRegularFile(path) ? Js.trim(Files.readString(path)) : "";
    } catch (IOException e) {
      return "";
    }
  }

  /** Writes a new file readable only by this user; false when it is already there. */
  private static boolean create(Path path, String text) {
    try {
      Files.writeString(
          path,
          text,
          StandardCharsets.UTF_8,
          StandardOpenOption.CREATE_NEW,
          StandardOpenOption.WRITE);
    } catch (FileAlreadyExistsException e) {
      return false;
    } catch (IOException e) {
      throw new UncheckedIOException(e);
    }
    restrict(path, "rw-------");
    return true;
  }

  private static void pause() {
    try {
      Thread.sleep(50);
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
    }
  }

  /** The dashboard's public address, such as https://stats.example.com, or null. */
  public String url() {
    String url = get("RUNLIGHT_URL");
    if (url != null && !URL.matcher(url).find()) {
      throw new IllegalStateException(
          "Runlight: set RUNLIGHT_URL to the dashboard's address only, such as https://stats.example.com");
    }
    return url;
  }

  /**
   * False with nothing in front, the one header the proxy sets, such as cf-connecting-ip behind
   * Cloudflare, or true.
   */
  public Object trustProxy() {
    String value = get("TRUST_PROXY");
    value = value == null ? "" : value.toLowerCase(Locale.ROOT);
    if (value.equals("false")) {
      return false;
    }
    return value.equals("x-forwarded-for")
            || value.equals("x-real-ip")
            || value.equals("cf-connecting-ip")
        ? value
        : true;
  }

  /** DB-IP's monthly download, for RUNLIGHT_GEO city (the default) or country, or null. */
  public DbIp dbIp() {
    String mode = get("RUNLIGHT_GEO");
    mode = mode == null ? "city" : mode.toLowerCase(Locale.ROOT);
    return mode.equals("city") || mode.equals("country")
        ? new DbIp(dataPath().resolve("geo"), mode)
        : null;
  }

  /**
   * Where locations come from: DB-IP's newest download (nothing until the first one is there), an
   * MMDB file of the owner's, opened at the first lookup, or null when RUNLIGHT_GEO is off.
   */
  public Geo.Lookup geo() {
    return geo(dbIp());
  }

  private Geo.Lookup geo(DbIp dbIp) {
    if (dbIp != null) {
      return dbIp::locate;
    }
    String setting = get("RUNLIGHT_GEO");
    if (setting != null && setting.toLowerCase(Locale.ROOT).equals("off")) {
      return null;
    }
    Path path = path(setting);
    Geo.Lookup[] lookup = {null};
    return ip -> {
      synchronized (lookup) {
        if (lookup[0] == null) {
          lookup[0] = Geo.fileLookup(path);
        }
      }
      return lookup[0].lookup(ip);
    };
  }

  /** The file that holds the setup link while there is no account. */
  public Path setupFile() {
    return dataDir().resolve("setup.txt");
  }

  /**
   * The one-time code that unlocks /setup, made the first time it is asked for and written to
   * setup.txt in the data folder with the link that carries it. With RUNLIGHT_TOKEN set there is
   * none: setup asks for the token.
   */
  public String setupCode() {
    if (get("RUNLIGHT_TOKEN") != null) {
      return null;
    }
    Path path = setupFile();
    String found = codeIn(path);
    if (found != null) {
      return found;
    }
    String code = Web.setupCode();
    String url = url();
    String link =
        (url != null ? url.replaceAll("/+\\z", "") : "https://your-runlight-address")
            + "/setup?code="
            + code;
    if (!create(
        path,
        "Open this link to create the first Runlight account. It works only while Runlight has no account.\n"
            + link
            + "\n")) {
      // Someone else wrote it first.
      pause();
      found = codeIn(path);
      if (found != null) {
        return found;
      }
      throw new IllegalStateException(
          "Runlight: could not write "
              + path
              + ". Make the data folder writable, or set RUNLIGHT_TOKEN.");
    }
    return code;
  }

  private static String codeIn(Path path) {
    try {
      if (!Files.isRegularFile(path)) {
        return null;
      }
      Matcher m = SETUP_LINK.matcher(Files.readString(path));
      return m.find() ? m.group(1) : null;
    } catch (IOException e) {
      return null;
    }
  }

  /**
   * The standalone server's options these settings describe, for a caller to change (such as now or
   * fetcher, for tests) before making one.
   *
   * @param setup whether to make the setup code when there is none, as the web pages need
   */
  public Standalone.Options options(boolean setup) {
    DbIp dbIp = dbIp();
    Geo.Lookup geo = geo(dbIp);
    String code = setup ? setupCode() : null;
    Standalone.Options options =
        new Standalone.Options()
            .store(store())
            .secret(secret())
            .token(get("RUNLIGHT_TOKEN"))
            .url(url())
            .trustProxy(trustProxy())
            .geoCredit(dbIp != null)
            .cronSecret(get("CRON_SECRET"))
            .observeKey(get("RUNLIGHT_OBSERVE_KEY"))
            .geo(geo);
    if (code != null) {
      options.setupCode(code);
      options.setupWhere(
          "in the file setup.txt in Runlight's data folder (<code>runlight setup</code> prints it too)");
    }
    return options;
  }

  /**
   * The standalone server these settings describe.
   *
   * @param setup whether to make the setup code when there is none, as the web pages need
   */
  public Standalone standalone(boolean setup) {
    return new Standalone(options(setup));
  }

  /** The standalone server, its setup code made when there is none. */
  public Standalone standalone() {
    return standalone(true);
  }
}
