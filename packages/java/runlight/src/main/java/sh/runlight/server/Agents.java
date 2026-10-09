package sh.runlight.server;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.FileAlreadyExistsException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.function.BooleanSupplier;
import java.util.function.Consumer;
import java.util.function.LongConsumer;
import java.util.function.LongSupplier;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.Ua;
import sh.runlight.accounts.Crypto;
import sh.runlight.http.FetchInit;
import sh.runlight.http.Fetcher;
import sh.runlight.http.JdkFetcher;
import sh.runlight.http.Response;
import sh.runlight.http.Url;
import sh.runlight.importers.Http;

/**
 * {@code runlight agents}: counts AI agents on a site that has only the script tag, by reading its
 * web server's access log. Agents do not run JavaScript, so the tracker never sees them; the server
 * that answered them did.
 *
 * <p>It reads nginx and Apache's combined format and Caddy's JSON lines, keeps successful GETs from
 * known AI agents, and sends them in batches to a Runlight's /api/observe with the site's observe
 * key. Nothing else in the log leaves the machine. With follow it keeps reading as the log grows
 * and carries on after the log is rotated. Without it, it reads what is new and stops, for cron. In
 * both modes the state file remembers how far it read, so the next run, or a restarted follow,
 * carries on from there.
 *
 * <p>The port of the Node server's agents.ts, by way of PHP's Server/Agents.php. A fetch is a map
 * of url, userAgent, and at (epoch milliseconds).
 */
public final class Agents {
  private static final Map<String, Integer> MONTHS =
      Map.ofEntries(
          Map.entry("Jan", 0),
          Map.entry("Feb", 1),
          Map.entry("Mar", 2),
          Map.entry("Apr", 3),
          Map.entry("May", 4),
          Map.entry("Jun", 5),
          Map.entry("Jul", 6),
          Map.entry("Aug", 7),
          Map.entry("Sep", 8),
          Map.entry("Oct", 9),
          Map.entry("Nov", 10),
          Map.entry("Dec", 11));

  /** JavaScript's \S, which also leaves out Unicode spaces. */
  private static final String S = "[^" + Js.SPACE + "]";

  /** A quoted field's inside, escapes included; possessive, as its two choices never overlap. */
  private static final String QUOTED = "(?:[^\"\\\\]|\\\\" + Js.DOT + ")*+";

  // host? ip - user [time] "METHOD /path HTTP/x" status bytes "referrer" "user agent"
  private static final Pattern COMBINED =
      Pattern.compile(
          "^(?:("
              + S
              + "+) )?"
              + S
              + "+ "
              + S
              + "+ "
              + S
              + "+ \\[([^\\]]+)\\] \"("
              + S
              + "+) ("
              + S
              + "+)[^\"]*\" ([0-9]{3}) "
              + S
              + "+ \""
              + QUOTED
              + "\" \"("
              + QUOTED
              + ")\"");

  /** A request line and status, in a line that might be a combined log line without its host. */
  private static final Pattern REQUEST =
      Pattern.compile("\"" + S + "+ /" + S + "* [^\"]*\" [0-9]{3}");

  private static final Pattern LOG_TIME =
      Pattern.compile(
          "^(\\d{2})/(\\w{3})/(\\d{4}):(\\d{2}):(\\d{2}):(\\d{2}) ([+-])(\\d{2})(\\d{2})\\z");
  private static final Pattern LETTER = Pattern.compile("[a-z]", Pattern.CASE_INSENSITIVE);
  private static final Pattern ADDRESS = Pattern.compile("^[0-9.:]+\\z");
  private static final Pattern PORT = Pattern.compile(":[0-9]+\\z");

  /** The most fetches /api/observe takes at once. */
  public static final int BATCH = 500;

  /** The most of a log read at once, so a log of any size fits in memory a piece at a time. */
  private static final int CHUNK = 32 * 1024 * 1024;

  /** How many bytes at the start of a log identify it. */
  private static final int HEAD = 256;

  private Agents() {}

  /**
   * What run() takes, as the Node command's options.
   *
   * <ul>
   *   <li>log: the access log's path
   *   <li>to: the Runlight to report to, as its dashboard address
   *   <li>key: the site's observe key
   *   <li>site: the site's address, for logs with no host in them
   *   <li>follow: keep reading as the log grows
   *   <li>state: where runs remember how far they read, so the next one (or a restarted follow)
   *       carries on
   *   <li>out: what it has to say, a line at a time; printed by default
   *   <li>stop: ends follow, which otherwise runs until the process stops
   *   <li>pollMs: how often follow looks at the log, 2 seconds by default
   *   <li>sleep: waits between looks, Thread.sleep by default
   *   <li>fetcher: the Fetcher that reaches Runlight, {@link JdkFetcher} by default
   *   <li>now: epoch milliseconds, for lines whose time cannot be read
   * </ul>
   */
  public static final class Options {
    public String log;
    public String to;
    public String key;
    public String site;
    public boolean follow;
    public String state;
    public Consumer<String> out;
    public BooleanSupplier stop;
    public long pollMs = 2000;
    public LongConsumer sleep;
    public Fetcher fetcher;
    public LongSupplier now;

    public Options log(String value) {
      log = value;
      return this;
    }

    public Options to(String value) {
      to = value;
      return this;
    }

    public Options key(String value) {
      key = value;
      return this;
    }

    public Options site(String value) {
      site = value;
      return this;
    }

    public Options follow(boolean value) {
      follow = value;
      return this;
    }

    public Options state(String value) {
      state = value;
      return this;
    }

    public Options out(Consumer<String> value) {
      out = value;
      return this;
    }

    public Options stop(BooleanSupplier value) {
      stop = value;
      return this;
    }

    public Options pollMs(long value) {
      pollMs = value;
      return this;
    }

    public Options sleep(LongConsumer value) {
      sleep = value;
      return this;
    }

    public Options fetcher(Fetcher value) {
      fetcher = value;
      return this;
    }

    public Options now(LongSupplier value) {
      now = value;
      return this;
    }
  }

  /**
   * A request target as a page on the site. Absolute targets ("GET http://other/x", a proxy
   * request) name somewhere else and are skipped. The target is set as the path and query of the
   * site's own address, never parsed as a URL, so "//x" and "/\x" stay paths on the site.
   */
  private static String pageUrl(String target, String base) {
    if (!target.startsWith("/")) {
      return null;
    }
    Url url = Url.parse(base);
    if (url == null) {
      return null;
    }
    int query = target.indexOf('?');
    String path = query < 0 ? target : target.substring(0, query);
    int start = 0;
    while (start < path.length() && path.charAt(start) == '/') {
      start++;
    }
    url.setPathname("/" + path.substring(start));
    url.setSearch(query < 0 ? "" : target.substring(query));
    url.hash = "";
    return url.href();
  }

  /** "07/Oct/2026:13:55:36 -0400" as epoch milliseconds, or NaN. */
  private static Object logTime(String value) {
    Matcher m = LOG_TIME.matcher(value);
    if (!m.matches() || !MONTHS.containsKey(m.group(2))) {
      return Double.NaN;
    }
    // Date.UTC reads years 0 to 99 as 1900 to 1999, and lets days and hours run on past their end.
    long year = Long.parseLong(m.group(3));
    year += year <= 99 ? 1900 : 0;
    long days = daysFromCivil(year, MONTHS.get(m.group(2)) + 1) + Long.parseLong(m.group(1)) - 1;
    long local =
        (((days * 24 + Long.parseLong(m.group(4))) * 60 + Long.parseLong(m.group(5))) * 60
                + Long.parseLong(m.group(6)))
            * 1000;
    long offset =
        (Long.parseLong(m.group(8)) * 60 + Long.parseLong(m.group(9)))
            * 60_000
            * (m.group(7).equals("-") ? -1 : 1);
    return local - offset;
  }

  /** Days from 1970-01-01 to the first of this month. */
  private static long daysFromCivil(long year, long month) {
    long y = month <= 2 ? year - 1 : year;
    long era = Math.floorDiv(y, 400);
    long yoe = y - era * 400;
    long doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5;
    long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
  }

  /** value?.[key], for a value that may be null or undefined. */
  private static Object at(Object value, String key) {
    return value == null || value == Json.UNDEFINED ? Json.UNDEFINED : Js.get(value, key);
  }

  /** a ?? b */
  private static Object either(Object value, Object otherwise) {
    return value == null || value == Json.UNDEFINED ? otherwise : value;
  }

  /**
   * One log line as a page fetch, or null: method, url, status, userAgent, and at. {@code site} is
   * the address pages live at (https://example.com), for formats that do not record the host.
   */
  public static Map<String, Object> parseLine(String line, String site) {
    String text = Js.trim(line);
    if (text.isEmpty()) {
      return null;
    }
    if (text.startsWith("{")) {
      // Caddy: {"ts": 1696..., "request": {"method", "host", "uri", "headers": {"User-Agent":
      // [...]}}, "status": 200}
      Json.Parsed parsed = Json.tryParse(text);
      if (!parsed.ok()) {
        return null;
      }
      Object entry = parsed.value();
      Object request = at(entry, "request");
      Object uri = at(request, "uri");
      Object method = at(request, "method");
      if (!Js.truthy(uri) || !Js.truthy(method)) {
        return null;
      }
      Object given = at(request, "host");
      String host =
          Js.truthy(given)
              ? (Js.truthy(at(request, "tls"))
                      ? "https"
                      : site != null && site.startsWith("http://") ? "http" : "https")
                  + "://"
                  + Js.string(given)
              : site;
      if (host == null || host.isEmpty()) {
        return null;
      }
      Object headers = at(request, "headers");
      Object ua =
          either(
              at(at(headers, "User-Agent"), "0"), either(at(at(headers, "user-agent"), "0"), ""));
      Object ts = at(entry, "ts");
      Object when =
          ts instanceof Number n
              ? Js.num(n.doubleValue() * 1000)
              : Js.num(Http.parseDate(Js.string(either(ts, ""))));
      // A target that is not text cannot be a page, as startsWith throws on it in TypeScript.
      String url = uri instanceof String target ? pageUrl(target, host) : null;
      if (url == null) {
        return null;
      }
      return Json.object(
          "method",
          method,
          "url",
          url,
          "status",
          Js.num(Js.toNumber(either(at(entry, "status"), 0L))),
          "userAgent",
          Js.string(ua),
          "at",
          when);
    }
    Matcher m = COMBINED.matcher(text);
    if (!m.find()) {
      return null;
    }
    // A vhost column first ("example.com:443 1.2.3.4 - - [...]") names the host; otherwise site
    // does.
    String column = m.group(1);
    String vhost =
        column != null
                && !column.isEmpty()
                && LETTER.matcher(column).find()
                && !ADDRESS.matcher(column).find()
            ? PORT.matcher(column).replaceFirst("")
            : null;
    String base = vhost != null ? "https://" + vhost : site;
    if (base == null || base.isEmpty()) {
      return null;
    }
    String url = pageUrl(m.group(4), base);
    return url == null
        ? null
        : Json.object(
            "method",
            m.group(3),
            "url",
            url,
            "status",
            Long.parseLong(m.group(5)),
            "userAgent",
            m.group(6).replace("\\\"", "\""),
            "at",
            logTime(m.group(2)));
  }

  /** {@link #parseLine(String, String)} for a line that must name its own host. */
  public static Map<String, Object> parseLine(String line) {
    return parseLine(line, null);
  }

  /**
   * The lines worth sending: GETs that succeeded, from known AI agents, as url, userAgent, and at.
   *
   * @param now epoch milliseconds, for a line whose time cannot be read; the clock when null
   */
  public static Map<String, Object> agentFetch(String line, String site, LongSupplier now) {
    Map<String, Object> hit = parseLine(line, site);
    if (hit == null) {
      return null;
    }
    double status = Js.toNumber(hit.get("status"));
    if (!"GET".equals(hit.get("method"))
        || status < 200
        || status >= 400
        || Ua.aiAgent((String) hit.get("userAgent")) == null) {
      return null;
    }
    Object when = hit.get("at");
    return Json.object(
        "url",
        hit.get("url"),
        "userAgent",
        hit.get("userAgent"),
        "at",
        Js.isFinite(when) ? when : (Object) (now != null ? now.getAsLong() : clock()));
  }

  /** {@link #agentFetch(String, String, LongSupplier)} on the clock. */
  public static Map<String, Object> agentFetch(String line, String site) {
    return agentFetch(line, site, null);
  }

  private static long clock() {
    return System.currentTimeMillis();
  }

  /**
   * Reads the log and sends what AI agents fetched, returning how many fetches Runlight kept.
   *
   * @throws SendError when Runlight cannot be reached or does not take a batch
   */
  public static long run(Options options) {
    Runnable release = options.state != null ? lock(options.state) : () -> {};
    try {
      return new Reader(options).read();
    } finally {
      release.run();
    }
  }

  /** What one read of a log found. */
  private record Read(List<String> lines, List<Long> ends, long next, boolean more) {}

  /** A fingerprint of the first bytes of a log. */
  private record Head(String head, long length) {}

  /** A log's inode and size. */
  private record Stat(long ino, long size) {}

  /** Where the last run stopped: ino and offset as numbers, head and length when saved. */
  private record Saved(Object ino, double offset, Object head, Object length) {}

  /** The reason an operation on a file failed, after what was being done. */
  private static RuntimeException failed(String what, IOException error) {
    String reason = error.getMessage();
    return new UncheckedIOException(
        what + (reason == null ? "" : ": " + error.getClass().getSimpleName() + " " + reason),
        error);
  }

  /** Opens a file for reading, or throws with the reason, as Node's openSync does. */
  private static FileChannel open(String file) {
    try {
      return FileChannel.open(Path.of(file), StandardOpenOption.READ);
    } catch (IOException error) {
      throw failed("Could not open " + file, error);
    }
  }

  private static Stat stat(String file) {
    try {
      Map<String, Object> read = Files.readAttributes(Path.of(file), "unix:ino,size");
      return new Stat(
          ((Number) read.get("ino")).longValue(), ((Number) read.get("size")).longValue());
    } catch (IOException error) {
      throw failed("Could not read " + file, error);
    } catch (UnsupportedOperationException | IllegalArgumentException error) {
      try {
        // Without inodes, the size alone tells rotations apart.
        return new Stat(0, Files.size(Path.of(file)));
      } catch (IOException again) {
        throw failed("Could not read " + file, again);
      }
    }
  }

  private static long size(FileChannel fd) {
    try {
      return fd.size();
    } catch (IOException error) {
      throw failed("Could not read the log", error);
    }
  }

  /** Up to {@code length} bytes from {@code offset}. */
  private static byte[] readAt(FileChannel fd, long offset, int length) {
    if (length <= 0) {
      return new byte[0];
    }
    ByteBuffer buffer = ByteBuffer.allocate(length);
    try {
      while (buffer.hasRemaining()) {
        int n = fd.read(buffer, offset + buffer.position());
        if (n < 0) {
          break;
        }
      }
    } catch (IOException error) {
      throw failed("Could not read the log", error);
    }
    byte[] out = new byte[buffer.position()];
    buffer.flip();
    buffer.get(out);
    return out;
  }

  private static void close(FileChannel fd) {
    try {
      fd.close();
    } catch (IOException ignored) {
      // Nothing was written through it.
    }
  }

  /**
   * A fingerprint of the log's first bytes. A log rotated by copying and truncating keeps its
   * inode, so a different start is how a new log shows itself. An open file (in follow mode) is
   * read as it is, even once it is renamed.
   */
  private static Head headOf(FileChannel fd, long length) {
    byte[] buffer = readAt(fd, 0, (int) Math.min(length, size(fd)));
    return new Head(Crypto.hex(Crypto.sha256(buffer)), buffer.length);
  }

  private static Head headOf(String file, long length) {
    FileChannel fd = open(file);
    try {
      return headOf(fd, length);
    } finally {
      close(fd);
    }
  }

  private static Head headOf(String file) {
    return headOf(file, HEAD);
  }

  /** Whether the log at this inode still starts the way it did, so a saved place still holds. */
  private static boolean sameLog(String file, Object ino, Object head, Object length, Stat stat) {
    if (!(ino instanceof Long saved && saved == stat.ino())) {
      return false;
    }
    if (!Js.truthy(head) || length == null || length == Json.UNDEFINED) {
      return true;
    }
    double toNumber = Js.toNumber(length);
    long bytes = Double.isNaN(toNumber) ? 0 : (long) toNumber;
    return stat.size() >= bytes && headOf(file, bytes).head().equals(head);
  }

  /**
   * Reads whole lines from a byte offset, at most a chunk, and returns where the next read starts.
   * Offsets count bytes up to each newline byte, so a malformed character cannot shift them. {@code
   * ends} holds where the line after each one starts, so a place can be saved part way through a
   * chunk. A path is opened for this read; an open file (in follow mode) stays open, even once it
   * is renamed.
   */
  private static Read readFrom(String file, long offset) {
    long size = stat(file).size();
    if (size <= offset) {
      return new Read(List.of(), List.of(), offset, false);
    }
    FileChannel fd = open(file);
    try {
      return readFrom(fd, offset, size);
    } finally {
      close(fd);
    }
  }

  private static Read readFrom(FileChannel fd, long offset) {
    long size = size(fd);
    if (size <= offset) {
      return new Read(List.of(), List.of(), offset, false);
    }
    return readFrom(fd, offset, size);
  }

  private static Read readFrom(FileChannel fd, long offset, long size) {
    byte[] buffer = readAt(fd, offset, (int) Math.min(size - offset, CHUNK));
    int end = buffer.length - 1;
    while (end >= 0 && buffer[end] != '\n') {
      end--;
    }
    // A half-written last line waits for the next read (or, in a chunk with no newline at all, is
    // skipped).
    if (end < 0) {
      return buffer.length == CHUNK
          ? new Read(List.of(), List.of(), offset + buffer.length, true)
          : new Read(List.of(), List.of(), offset, false);
    }
    List<String> lines = new ArrayList<>();
    List<Long> ends = new ArrayList<>();
    for (int start = 0; start <= end; ) {
      int newline = start;
      while (buffer[newline] != '\n') {
        newline++;
      }
      // Read as UTF-8 the way Node does, each malformed sequence becoming U+FFFD.
      lines.add(new String(buffer, start, newline - start, StandardCharsets.UTF_8));
      ends.add(offset + newline + 1);
      start = newline + 1;
    }
    return new Read(lines, ends, offset + end + 1, offset + buffer.length < size);
  }

  /** Whether a process with this id is running on this machine. */
  private static boolean running(long pid) {
    return ProcessHandle.of(pid).map(ProcessHandle::isAlive).orElse(false);
  }

  /** The text of a file, or null when it cannot be read. */
  private static String contents(Path file) {
    try {
      return Files.readString(file, StandardCharsets.UTF_8);
    } catch (IOException | UncheckedIOException error) {
      return null;
    }
  }

  /**
   * Takes the lock beside a state file, so two runs never read from the same place and send the
   * same lines twice. The lock holds the run's process id; a lock left by a process that is no
   * longer running is taken over. Returns the release.
   */
  private static Runnable lock(String state) {
    Path path = Path.of(state + ".lock");
    String mine = Long.toString(ProcessHandle.current().pid());
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        Files.writeString(path, mine, StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE);
        return release(path, mine);
      } catch (FileAlreadyExistsException taken) {
        // Held, or left behind; read below.
      } catch (IOException error) {
        throw failed("Could not create " + path, error);
      }
      if (!Files.exists(path)) {
        continue;
      }
      String held = contents(path);
      if (held == null) {
        continue;
      }
      held = Js.trim(held);
      double pid = Js.toNumber(held);
      // A lock being written has no id in it yet, so it counts as held.
      if (held.isEmpty() || (pid == Math.floor(pid) && pid > 0 && running((long) pid))) {
        break;
      }
      // Stale. Moving it aside is atomic, so of two runs taking it over only one moves this lock;
      // one that finds a newer lock moved aside puts it back.
      Path aside = Path.of(path + "." + mine);
      try {
        Files.move(path, aside, StandardCopyOption.ATOMIC_MOVE);
      } catch (IOException error) {
        continue;
      }
      String moved = contents(aside);
      try {
        if (!Js.trim(moved == null ? "" : moved).equals(held)) {
          try {
            Files.createLink(path, aside);
          } catch (IOException | UnsupportedOperationException ignored) {
            // Someone else has made a lock since; theirs stands.
          }
          Files.deleteIfExists(aside);
          break;
        }
        Files.deleteIfExists(aside);
      } catch (IOException error) {
        throw failed("Could not take over " + path, error);
      }
    }
    String holder = contents(path);
    holder = holder == null ? "" : Js.trim(holder);
    throw new IllegalStateException(
        "Another run is using "
            + state
            + (holder.isEmpty() ? "" : " (process " + holder + ")")
            + ". Wait for it to finish, or delete "
            + path
            + " if none is running.");
  }

  /** Deletes the lock if it is still this run's, once, at the end of the run or of the process. */
  private static Runnable release(Path path, String mine) {
    boolean[] released = {false};
    Thread[] hook = new Thread[1];
    Runnable release =
        () -> {
          synchronized (released) {
            if (released[0]) {
              return;
            }
            released[0] = true;
          }
          if (mine.equals(contents(path))) {
            try {
              Files.deleteIfExists(path);
            } catch (IOException ignored) {
              // Left for the next run to find stale.
            }
          }
        };
    // Released on exit too, as a run that stops part way would otherwise leave its lock behind.
    hook[0] = new Thread(release, "runlight-agents-lock");
    Runtime.getRuntime().addShutdownHook(hook[0]);
    return () -> {
      release.run();
      try {
        Runtime.getRuntime().removeShutdownHook(hook[0]);
      } catch (IllegalStateException exiting) {
        // The process is already on its way out.
      }
    };
  }

  /** Writes the state whole or not at all, so a crash part way never leaves it empty. */
  private static void writeState(String state, long ino, long offset, Head head) {
    Path temp = Path.of(state + "." + ProcessHandle.current().pid() + ".tmp");
    try {
      Files.writeString(
          temp,
          Json.stringify(
              Json.object(
                  "ino", ino, "offset", offset, "head", head.head(), "length", head.length())),
          StandardCharsets.UTF_8);
      Files.move(
          temp,
          Path.of(state),
          StandardCopyOption.REPLACE_EXISTING,
          StandardCopyOption.ATOMIC_MOVE);
    } catch (IOException error) {
      throw failed("Could not write " + state, error);
    }
  }

  /** One run over a log. */
  private static final class Reader {
    private final Options options;
    private final Consumer<String> out;
    private final Fetcher fetcher;
    private final LongSupplier now;
    private final String site;
    private final String state;
    private final String log;
    private long total;
    private boolean warned;

    // Follow mode's place: the open file's inode, how far into it, and its start.
    private long ino;
    private long offset;
    private Head known;

    Reader(Options options) {
      this.options = options;
      this.out = options.out != null ? options.out : line -> System.out.println(line);
      this.fetcher = options.fetcher != null ? options.fetcher : new JdkFetcher();
      this.now = options.now != null ? options.now : Agents::clock;
      this.site = options.site != null && !options.site.isEmpty() ? options.site : null;
      this.state = options.state != null && !options.state.isEmpty() ? options.state : null;
      this.log = options.log;
    }

    /** Sends one batch of fetches to /api/observe and returns how many Runlight kept. */
    private long send(List<Object> fetches) {
      Response answer;
      try {
        String to = options.to;
        int end = to.length();
        while (end > 0 && to.charAt(end - 1) == '/') {
          end--;
        }
        answer =
            fetcher.fetch(
                to.substring(0, end) + "/api/observe",
                new FetchInit()
                    .method("POST")
                    .header("authorization", "Bearer " + options.key)
                    .header("content-type", "application/json")
                    .body(Json.stringify(Json.object("fetches", fetches)))
                    .timeoutMs(30_000));
      } catch (RuntimeException error) {
        throw new SendError(error.getMessage(), error);
      }
      if (answer.status() == 401) {
        throw new SendError(
            "Runlight refused the key. Use the site's key from Settings, Install, Key for CMS plugins.");
      }
      if (!answer.ok()) {
        throw new SendError(
            "Runlight answered " + answer.status() + ": " + Js.slice(answer.text(), 0, 200));
      }
      Json.Parsed body = Json.tryParse(answer.text());
      Object recorded =
          body.ok() && body.value() instanceof Map<?, ?> ? Js.get(body.value(), "recorded") : null;
      return recorded instanceof Number n ? n.longValue() : 0;
    }

    /**
     * Sends the agent fetches among lines read, a batch at a time, calling {@code done} with where
     * the next unsent line starts after each batch, so a failure part way sends none of the earlier
     * batches again.
     */
    private long handle(Read read, LongConsumer done) {
      List<String> lines = read.lines();
      // Lines with no host and no site cannot be placed on a site; say so once rather than skip
      // them silently.
      if (site == null && !warned) {
        for (String line : lines) {
          if (!Js.trim(line).startsWith("{")
              && REQUEST.matcher(line).find()
              && parseLine(line) == null) {
            warned = true;
            out.accept(
                "Some lines have no host in them. Add --site https://your-site.example so they can be counted.");
            break;
          }
        }
      }
      long kept = 0;
      List<Object> batch = new ArrayList<>();
      int count = lines.size();
      for (int i = 0; i < count; i++) {
        Map<String, Object> found = agentFetch(lines.get(i), site, now);
        if (found != null) {
          batch.add(found);
        }
        if (batch.size() == BATCH || (i == count - 1 && !batch.isEmpty())) {
          long recorded = send(batch);
          kept += recorded;
          total += recorded;
          batch = new ArrayList<>();
          done.accept(read.ends().get(i));
        }
      }
      return kept;
    }

    /** The place to save: the file being read, by its inode and its own start, and how far in. */
    private void save(long at, long place, Head head) {
      if (state != null) {
        writeState(state, at, place, head);
      }
    }

    /** Where the last run stopped, or null with a word about it when the state cannot be read. */
    private Saved readState() {
      if (state == null || !Files.exists(Path.of(state))) {
        return null;
      }
      String text = contents(Path.of(state));
      Json.Parsed saved = Json.tryParse(text == null ? "" : text);
      Object value = saved.ok() ? saved.value() : null;
      Object at = value instanceof Map<?, ?> ? Js.get(value, "ino") : null;
      Object place = value instanceof Map<?, ?> ? Js.get(value, "offset") : null;
      if (at instanceof Number && place instanceof Number n) {
        return new Saved(
            Js.num(at), n.doubleValue(), Js.get(value, "head"), Js.get(value, "length"));
      }
      out.accept("Could not read " + state + ", so this run starts as if it were the first.");
      return null;
    }

    long read() {
      if (!Files.exists(Path.of(log))) {
        throw new IllegalStateException("No log at " + log);
      }
      if (!options.follow) {
        return once();
      }
      return follow();
    }

    private long once() {
      // Where the last run stopped, unless the log was rotated since (a new file, a shorter one, or
      // a new start).
      Saved saved = readState();
      Stat stat = stat(log);
      long place =
          saved != null
                  && saved.offset() <= stat.size()
                  && sameLog(log, saved.ino(), saved.head(), saved.length(), stat)
              ? (long) saved.offset()
              : 0;
      long count = 0;
      // A batch at a time, saving the place after each, so a failure part way resends nothing
      // already sent.
      for (; ; ) {
        Read read = readFrom(log, place);
        handle(read, at -> save(stat.ino(), at, headOf(log)));
        count += read.lines().size();
        place = read.next();
        save(stat.ino(), place, headOf(log));
        if (!read.more()) {
          break;
        }
      }
      out.accept("Sent " + total + " AI agent fetches from " + count + " new lines.");
      return total;
    }

    private long follow() {
      // Start where the state says, else at the end like tail -F. A log that was rotated since the
      // state was saved is all new, so it is read from its start.
      BooleanSupplier stop = options.stop != null ? options.stop : () -> false;
      LongConsumer sleep =
          options.sleep != null
              ? options.sleep
              : ms -> {
                try {
                  Thread.sleep(ms);
                } catch (InterruptedException e) {
                  Thread.currentThread().interrupt();
                }
              };
      Saved resumed = readState();
      Stat first = stat(log);
      ino = first.ino();
      offset =
          resumed != null
              ? (resumed.offset() <= first.size()
                      && sameLog(log, resumed.ino(), resumed.head(), resumed.length(), first)
                  ? (long) resumed.offset()
                  : 0)
              : first.size();
      out.accept(
          "Following " + log + ". AI agent fetches go to " + options.to + " as they happen.");
      // The log stays open, so when it is renamed in a rotation, what was written to it before the
      // switch is still read to the end before the new log starts. Its fingerprint is taken from
      // the open file too, so a place saved while finishing an old log names that log, never the
      // new one.
      FileChannel fd = open(log);
      try {
        known = headOf(fd, HEAD);
        // The same trouble every two seconds is said once, until something changes.
        String trouble = "";
        while (!stop.getAsBoolean() && !Thread.currentThread().isInterrupted()) {
          sleep.accept(options.pollMs);
          try {
            Stat stat = Files.exists(Path.of(log)) ? stat(log) : null;
            boolean renamed = stat == null || stat.ino() != ino;
            // Copied and truncated in place: the same file, shorter or with a new start.
            if (!renamed
                && (stat.size() < offset
                    || !sameLog(log, ino, known.head(), known.length(), stat))) {
              offset = 0;
            }
            Read read = readFrom(fd, offset);
            long sent =
                handle(
                    read,
                    at -> {
                      offset = at;
                      save(ino, offset, known);
                    });
            // Only past lines that were sent, so a failed send is tried again next time.
            offset = read.next();
            save(ino, offset, known);
            if (sent != 0) {
              out.accept("Sent " + sent + " AI agent fetches.");
            }
            if (renamed && stat != null && !read.more()) {
              // The old log is finished; the new one is read from its start.
              FileChannel next = open(log);
              close(fd);
              fd = next;
              ino = stat.ino();
              offset = 0;
            }
            // The start grows until it is HEAD bytes long, so the fingerprint is taken again.
            known = headOf(fd, HEAD);
            trouble = "";
          } catch (RuntimeException error) {
            String said =
                error instanceof SendError
                    ? "Could not send, trying again shortly: " + error.getMessage()
                    : "Could not read " + log + ", trying again shortly: " + error.getMessage();
            if (!said.equals(trouble)) {
              out.accept(said);
            }
            trouble = said;
          }
        }
      } finally {
        close(fd);
      }
      return total;
    }
  }
}
