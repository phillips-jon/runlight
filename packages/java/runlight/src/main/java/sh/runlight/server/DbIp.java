package sh.runlight.server;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.UncheckedIOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.util.List;
import java.util.Map;
import java.util.function.Consumer;
import java.util.stream.Stream;
import java.util.zip.GZIPInputStream;
import sh.runlight.Geo;
import sh.runlight.Mmdb;

/**
 * Location for servers with no platform headers (Cloudflare, Vercel, and Netlify send their own,
 * and those always win), from DB-IP's free databases (CC BY 4.0, https://db-ip.com). This is the
 * port of the Geo class in packages/server/src/geo.ts, by way of PHP's Server/DbIp.php: {@link
 * #refresh(long)} downloads each month's release (the server does it every five minutes, {@code
 * runlight cron} each time it runs), and lookups answer from the newest file on disk, opened again
 * once a newer one arrives.
 */
public final class DbIp {
  /** Writes the gzipped file at a URL to a file, and says whether it got one. */
  @FunctionalInterface
  public interface Download {
    boolean download(String url, Path file) throws Exception;
  }

  private static final DateTimeFormatter MONTH = DateTimeFormatter.ofPattern("uuuu-MM");

  private final Path dir;
  private final String mode;
  private final Download download;
  private final Consumer<String> log;
  private final Object opening = new Object();
  private volatile Path loaded;
  private volatile Path seen;
  private volatile long scanned = Long.MIN_VALUE;
  private volatile Geo.Lookup reader;

  /**
   * DB-IP's data in a folder.
   *
   * @param mode "city" or "country"
   * @param download writes the gzipped file at the URL to the file, and says whether it got one;
   *     Java's HttpClient by default
   * @param log what it has to say; standard error by default
   */
  public DbIp(Path dir, String mode, Download download, Consumer<String> log) {
    this.dir = dir;
    this.mode = mode;
    this.download = download != null ? download : DbIp::fetch;
    this.log = log != null ? log : line -> System.err.println(line);
  }

  public DbIp(Path dir, String mode) {
    this(dir, mode, null, null);
  }

  /** "2026-10", the month DB-IP names each release after. */
  public static String month(long ms) {
    return MONTH.format(Instant.ofEpochMilli(ms).atZone(ZoneOffset.UTC));
  }

  private Path file(String release) {
    return dir.resolve("dbip-" + mode + "-lite-" + release + ".mmdb");
  }

  private String prefix() {
    return "dbip-" + mode + "-lite-";
  }

  private List<Path> releases() {
    if (!Files.isDirectory(dir)) {
      return List.of();
    }
    try (Stream<Path> files = Files.list(dir)) {
      return files.filter(f -> f.getFileName().toString().startsWith(prefix())).sorted().toList();
    } catch (IOException e) {
      return List.of();
    }
  }

  /** The newest release on disk, or null before the first download. */
  public Path newest() {
    Path found = null;
    for (Path file : releases()) {
      if (file.getFileName().toString().endsWith(".mmdb")) {
        found = file;
      }
    }
    return found;
  }

  /**
   * A lookup answering from the newest release on disk, or null when there is none yet. Lookups
   * that fail answer nothing, as they do before the first download in TypeScript.
   */
  public Geo.Lookup lookup() {
    return newest() == null ? null : this::locate;
  }

  /**
   * An address's location from the newest release on disk, opened at the first lookup and again
   * when a newer release arrives; null before the first download, or when the file cannot be read.
   */
  public Map<String, Object> locate(String ip) throws Exception {
    // The folder is read again at most once a minute, or at once after a refresh here.
    long tick = System.nanoTime();
    Path newest = seen;
    if (scanned == Long.MIN_VALUE || tick - scanned > 60_000_000_000L || newest == null) {
      newest = newest();
      seen = newest;
      scanned = tick;
    }
    if (newest == null) {
      return null;
    }
    Geo.Lookup current = reader;
    if (!newest.equals(loaded) || current == null) {
      synchronized (opening) {
        if (!newest.equals(loaded) || reader == null) {
          try {
            reader = Geo.lookupFrom(Mmdb.open(newest)::get);
          } catch (RuntimeException e) {
            return null;
          }
          loaded = newest;
        }
        current = reader;
      }
    }
    return current.lookup(ip);
  }

  /**
   * Fetches this month's release when it is missing. A new month's file appears a day or so after
   * the month starts, so until then last month's is fetched when that is missing too. Older
   * releases go once a new one is ready. Safe to call often: once this month's file is there it
   * reads only the folder.
   */
  public void refresh(long now) {
    scanned = Long.MIN_VALUE;
    String current = month(now);
    if (Files.isRegularFile(file(current))) {
      return;
    }
    try {
      Files.createDirectories(dir);
    } catch (IOException e) {
      log.accept("Runlight: could not make the folder for location data, " + dir);
      return;
    }
    ZonedDateTime at = Instant.ofEpochMilli(now).atZone(ZoneOffset.UTC);
    String previous = MONTH.format(at.withDayOfMonth(15).minusMonths(1).toLocalDate());
    for (String release : List.of(current, previous)) {
      if (Files.isRegularFile(file(release))) {
        return;
      }
      String url = "https://download.db-ip.com/free/" + prefix() + release + ".mmdb.gz";
      Path gz = Path.of(file(release) + ".gz.partial");
      Path partial = Path.of(file(release) + ".partial");
      try {
        if (!download.download(url, gz)) {
          continue;
        }
        gunzip(gz, partial);
        // A file that does not open as a database is never kept.
        Mmdb.open(partial);
        Files.move(partial, file(release), StandardCopyOption.REPLACE_EXISTING);
        for (Path old : releases()) {
          if (!old.equals(file(release))) {
            Files.deleteIfExists(old);
          }
        }
        log.accept("Runlight: location data from DB-IP (" + release + ") is ready.");
        return;
      } catch (Exception error) {
        log.accept("Runlight: could not download location data from " + url + ": " + reason(error));
      } finally {
        try {
          Files.deleteIfExists(gz);
          Files.deleteIfExists(partial);
        } catch (IOException ignored) {
          // Left for the next refresh.
        }
      }
    }
  }

  private static String reason(Exception error) {
    Throwable cause =
        error instanceof UncheckedIOException && error.getCause() != null
            ? error.getCause()
            : error;
    return cause.getMessage() != null ? cause.getMessage() : cause.toString();
  }

  private static void gunzip(Path from, Path to) throws IOException {
    try (InputStream in = new GZIPInputStream(Files.newInputStream(from));
        OutputStream out = Files.newOutputStream(to)) {
      in.transferTo(out);
    }
  }

  /**
   * Downloads a file straight to disk, since a city database is too big to hold in memory. This is
   * the one download that does not go through a Fetcher, which keeps whole answers in memory.
   */
  private static boolean fetch(String url, Path file) throws IOException, InterruptedException {
    try (HttpClient client =
        HttpClient.newBuilder()
            .followRedirects(HttpClient.Redirect.NORMAL)
            .connectTimeout(Duration.ofSeconds(15))
            .build()) {
      HttpResponse<Path> answer =
          client.send(
              HttpRequest.newBuilder(URI.create(url)).timeout(Duration.ofMinutes(10)).build(),
              HttpResponse.BodyHandlers.ofFile(file));
      return answer.statusCode() == 200 && answer.uri().getScheme().equals("https");
    }
  }
}
