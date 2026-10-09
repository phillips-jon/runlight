package sh.runlight.http;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.zip.GZIPInputStream;
import java.util.zip.Inflater;
import java.util.zip.InflaterInputStream;
import javax.net.ssl.SNIHostName;
import javax.net.ssl.SSLParameters;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;

/**
 * The default {@link Fetcher}: a small HTTP/1.1 client over a socket, the Java counterpart of the
 * PHP port's CurlFetcher. java.net.http.HttpClient cannot be told which address to connect to, and
 * {@link FetchInit#resolve} pins must be kept, so the address Safefetch checked is the one
 * connected to. TLS still checks the certificate against the host name and sends it as SNI.
 *
 * <p>It honours everything in FetchInit: the method, headers, and body; redirects followed as
 * fetch() follows them (a 303, and a 301 or 302 answering a POST, become a GET) or, with "manual",
 * handed back; one timeout for the whole request, redirects included; and maxBytes, past which it
 * stops reading and throws {@link BodyTooLong} or, with truncate, hands back the start. Bodies come
 * chunked, with a Content-Length, or until the connection closes, and gzip or deflate ones are
 * decoded. Throws {@link FetchError} when no answer comes back.
 */
public final class JdkFetcher implements Fetcher {
  private static final int MAX_REDIRECTS = 20;
  private static final long CONNECT_TIMEOUT_MS = 15_000;
  private static final Pattern PIN = Pattern.compile("^(.+):(\\d+):(.+)\\z");
  private static final Pattern STATUS_LINE = Pattern.compile("^HTTP/\\S+\\s+(\\d{3})(?:\\s.*)?\\z");

  /** Headers fetch() drops from a request whose body a redirect turned into a GET. */
  private static final List<String> BODY_HEADERS =
      List.of(
          "content-encoding",
          "content-language",
          "content-location",
          "content-type",
          "content-length");

  /** Headers fetch() drops on a redirect to another origin. */
  private static final List<String> CREDENTIAL_HEADERS =
      List.of("authorization", "proxy-authorization", "cookie", "host");

  private final SSLSocketFactory tls;

  /** A fetcher that trusts the JDK's certificate authorities. */
  public JdkFetcher() {
    this((SSLSocketFactory) SSLSocketFactory.getDefault());
  }

  /** A fetcher whose TLS connections come from this factory, such as one trusting a test's CA. */
  public JdkFetcher(SSLSocketFactory tls) {
    this.tls = tls;
  }

  @Override
  public Response fetch(String target, FetchInit init) {
    long until = System.nanoTime() + Math.max(0, init.timeoutMs) * 1_000_000L;
    Url url = Url.parse(target);
    if (url == null) {
      throw new FetchError("Failed to parse URL from " + target);
    }
    String method = init.method == null ? "GET" : init.method.toUpperCase(Locale.ROOT);
    Headers headers = new Headers(init.headers);
    byte[] body = init.body;
    for (int redirects = 0; ; redirects++) {
      if (!url.protocol.equals("http:") && !url.protocol.equals("https:")) {
        throw new FetchError("fetch failed: unsupported protocol " + url.protocol);
      }
      boolean follow = !"manual".equals(init.redirect);
      Exchange exchange = new Exchange(url, until);
      try {
        exchange.open(init.resolve);
        exchange.send(method, headers, body);
        Response answer = exchange.receive(method, init, follow);
        if (answer == null) {
          // A redirect to follow: its answer was not read, and the connection is done with.
          String location = exchange.location;
          if (redirects >= MAX_REDIRECTS) {
            throw new FetchError("fetch failed: redirect count exceeded");
          }
          Url next = Url.parse(location, url.href());
          if (next == null) {
            throw new FetchError("fetch failed: bad redirect location");
          }
          int status = exchange.status;
          if ((status == 303 && !method.equals("HEAD"))
              || ((status == 301 || status == 302) && method.equals("POST"))) {
            method = "GET";
            body = null;
            for (String name : BODY_HEADERS) {
              headers.delete(name);
            }
          }
          if (!next.origin().equals(url.origin())) {
            for (String name : CREDENTIAL_HEADERS) {
              headers.delete(name);
            }
          }
          url = next;
          continue;
        }
        return answer;
      } catch (SocketTimeoutException e) {
        throw timedOut(e);
      } catch (IOException e) {
        if (System.nanoTime() - until >= 0) {
          throw timedOut(e);
        }
        String message = e.getMessage();
        throw new FetchError(
            "fetch failed: " + (message == null ? e.getClass().getSimpleName() : message),
            false,
            e);
      } finally {
        exchange.close();
      }
    }
  }

  private static FetchError timedOut(Throwable cause) {
    return new FetchError("The operation was aborted due to timeout", true, cause);
  }

  /** One request and its answer, on a connection of its own. */
  private final class Exchange {
    private final Url url;
    private final long until;
    private final String host;
    private final int port;
    private Socket socket;
    private InputStream in;
    int status;
    String location;

    Exchange(Url url, long until) {
      this.url = url;
      this.until = until;
      String name = url.hostname;
      this.host =
          name.startsWith("[") && name.endsWith("]") ? name.substring(1, name.length() - 1) : name;
      this.port =
          url.port.isEmpty()
              ? (url.protocol.equals("https:") ? 443 : 80)
              : Integer.parseInt(url.port);
    }

    /** Milliseconds left, at least 1; past the deadline, a timeout. */
    private int left() throws SocketTimeoutException {
      long ms = Math.floorDiv(until - System.nanoTime(), 1_000_000L);
      if (ms <= 0) {
        throw new SocketTimeoutException("deadline");
      }
      return (int) Math.min(ms, Integer.MAX_VALUE);
    }

    /** The addresses to try: a pin's for this host and port, else what the name resolves to. */
    private List<InetAddress> addresses(List<String> pins) throws IOException {
      for (String pin : pins) {
        Matcher m = PIN.matcher(pin);
        if (!m.matches()
            || !m.group(1).equalsIgnoreCase(host)
            || Integer.parseInt(m.group(2)) != port) {
          continue;
        }
        List<InetAddress> out = new ArrayList<>();
        for (String one : m.group(3).split(",", -1)) {
          String bare = one.trim();
          if (bare.startsWith("[") && bare.endsWith("]")) {
            bare = bare.substring(1, bare.length() - 1);
          }
          // A literal address, so no lookup happens here.
          if (!bare.isEmpty() && (bare.contains(":") || bare.matches("^[0-9.]+\\z"))) {
            out.add(InetAddress.getByName(bare));
          }
        }
        if (!out.isEmpty()) {
          return out;
        }
      }
      return List.of(InetAddress.getAllByName(host));
    }

    void open(List<String> pins) throws IOException {
      List<InetAddress> addresses = addresses(pins);
      IOException last = null;
      for (InetAddress address : addresses) {
        Socket candidate = new Socket();
        try {
          candidate.connect(
              new InetSocketAddress(address, port), (int) Math.min(left(), CONNECT_TIMEOUT_MS));
          socket = candidate;
          break;
        } catch (SocketTimeoutException e) {
          candidate.close();
          if (System.nanoTime() - until >= 0) {
            throw e;
          }
          last = e;
        } catch (IOException e) {
          candidate.close();
          last = e;
        }
      }
      if (socket == null) {
        throw last != null ? last : new IOException("no address to connect to");
      }
      socket.setTcpNoDelay(true);
      if (url.protocol.equals("https:")) {
        SSLSocket secured = (SSLSocket) tls.createSocket(socket, host, port, true);
        SSLParameters parameters = secured.getSSLParameters();
        // The certificate is checked against the name, whichever address was connected to.
        parameters.setEndpointIdentificationAlgorithm("HTTPS");
        if (!host.contains(":") && !host.matches("^[0-9.]+\\z")) {
          parameters.setServerNames(List.of(new SNIHostName(host)));
        }
        secured.setSSLParameters(parameters);
        secured.setSoTimeout(left());
        secured.startHandshake();
        socket = secured;
      }
      in = new DeadlineInput(socket, this);
    }

    void send(String method, Headers headers, byte[] body) throws IOException {
      StringBuilder head = new StringBuilder();
      head.append(method)
          .append(' ')
          .append(url.pathname)
          .append(url.search)
          .append(" HTTP/1.1\r\n");
      if (!headers.has("host")) {
        head.append("host: ").append(url.host()).append("\r\n");
      }
      boolean sends = body != null && !method.equals("GET") && !method.equals("HEAD");
      for (Map.Entry<String, List<String>> entry : headers.all().entrySet()) {
        String name = entry.getKey();
        if (name.equals("content-length")
            || name.equals("connection")
            || name.equals("transfer-encoding")) {
          continue;
        }
        for (String value : entry.getValue()) {
          head.append(name).append(": ").append(value).append("\r\n");
        }
      }
      if (!headers.has("accept")) {
        head.append("accept: */*\r\n");
      }
      if (!headers.has("accept-encoding")) {
        head.append("accept-encoding: gzip, deflate\r\n");
      }
      if (sends) {
        head.append("content-length: ").append(body.length).append("\r\n");
      } else if (method.equals("POST") || method.equals("PUT") || method.equals("PATCH")) {
        head.append("content-length: 0\r\n");
      }
      head.append("connection: close\r\n\r\n");
      OutputStream out = socket.getOutputStream();
      // Header values are Latin-1 on the wire; Headers already took out any line break.
      out.write(head.toString().getBytes(StandardCharsets.ISO_8859_1));
      if (sends) {
        out.write(body);
      }
      out.flush();
    }

    /** The answer, or null for a redirect to follow (with status and location set). */
    Response receive(String method, FetchInit init, boolean follow) throws IOException {
      Headers headers;
      for (; ; ) {
        String line = line();
        if (line == null) {
          throw new IOException("the server closed the connection without answering");
        }
        Matcher m = STATUS_LINE.matcher(line);
        if (!m.matches()) {
          throw new IOException("not an HTTP answer");
        }
        status = Integer.parseInt(m.group(1));
        headers = new Headers();
        for (String field = line(); field != null && !field.isEmpty(); field = line()) {
          int colon = field.indexOf(':');
          if (colon > 0) {
            headers.append(field.substring(0, colon).trim(), field.substring(colon + 1).trim());
          }
        }
        // An interim answer (100 Continue and the like) comes before the real one.
        if (status >= 200 || status == 101) {
          break;
        }
      }
      location = headers.get("location");
      boolean redirect =
          (status == 301 || status == 302 || status == 303 || status == 307 || status == 308)
              && location != null;
      if (follow && redirect) {
        return null;
      }
      boolean empty = method.equals("HEAD") || status == 204 || status == 304 || status < 200;
      Long max = init.maxBytes;
      Capped body = new Capped(max);
      if (!empty) {
        InputStream raw = bodyStream(headers);
        InputStream decoded = decoder(raw, headers.get("content-encoding"));
        byte[] buffer = new byte[16_384];
        for (int n = decoded.read(buffer); n >= 0; n = decoded.read(buffer)) {
          if (!body.add(buffer, n)) {
            break;
          }
        }
      }
      if (body.tooLong) {
        if (!init.truncate) {
          throw new BodyTooLong("Body over " + max + " bytes");
        }
      }
      return new Response(body.bytes(), status, headers);
    }

    /** The body as it arrives on the wire: chunked, a Content-Length, or until the close. */
    private InputStream bodyStream(Headers headers) throws IOException {
      String encoding = headers.get("transfer-encoding");
      if (encoding != null && encoding.toLowerCase(Locale.ROOT).contains("chunked")) {
        return new Chunked();
      }
      String length = headers.get("content-length");
      if (length != null) {
        String first = length.split(",", -1)[0].trim();
        if (first.matches("^\\d{1,18}\\z")) {
          return new Limited(in, Long.parseLong(first));
        }
      }
      return in;
    }

    /** A chunked body as one stream, read as it arrives; trailers are read and dropped. */
    private final class Chunked extends InputStream {
      private long left;
      private boolean done;

      @Override
      public int read() throws IOException {
        byte[] one = new byte[1];
        return read(one, 0, 1) < 0 ? -1 : one[0] & 0xff;
      }

      @Override
      public int read(byte[] target, int offset, int length) throws IOException {
        if (length == 0) {
          return 0;
        }
        if (left == 0 && !next()) {
          return -1;
        }
        int n = in.read(target, offset, (int) Math.min(length, left));
        if (n < 0) {
          throw new IOException("the chunked body ended early");
        }
        left -= n;
        if (left == 0) {
          // The CRLF after the chunk.
          line();
        }
        return n;
      }

      /** Reads the next chunk's size; false after the last. */
      private boolean next() throws IOException {
        if (done) {
          return false;
        }
        String size = line();
        if (size == null) {
          throw new IOException("the chunked body ended early");
        }
        int semicolon = size.indexOf(';');
        String hex = (semicolon < 0 ? size : size.substring(0, semicolon)).trim();
        try {
          left = Long.parseLong(hex, 16);
        } catch (NumberFormatException e) {
          throw new IOException("a bad chunk size", e);
        }
        if (left < 0) {
          throw new IOException("a bad chunk size");
        }
        if (left == 0) {
          done = true;
          for (String trailer = line(); trailer != null && !trailer.isEmpty(); trailer = line()) {
            // Trailers are not kept.
          }
          return false;
        }
        return true;
      }
    }

    /** A line of the head, without its CRLF, or null at the end of the stream. */
    private String line() throws IOException {
      ByteArrayOutputStream out = new ByteArrayOutputStream();
      for (int b = in.read(); ; b = in.read()) {
        if (b < 0) {
          return out.size() == 0 ? null : out.toString(StandardCharsets.ISO_8859_1);
        }
        if (b == '\n') {
          byte[] bytes = out.toByteArray();
          int end =
              bytes.length > 0 && bytes[bytes.length - 1] == '\r' ? bytes.length - 1 : bytes.length;
          return new String(bytes, 0, end, StandardCharsets.ISO_8859_1);
        }
        out.write(b);
        if (out.size() > 65_536) {
          throw new IOException("a header line is too long");
        }
      }
    }

    void close() {
      if (socket != null) {
        try {
          socket.close();
        } catch (IOException e) {
          // Already gone.
        }
      }
    }
  }

  /** Bytes up to a cap, noting whether more came. */
  private static final class Capped {
    private final Long max;
    private final ByteArrayOutputStream out = new ByteArrayOutputStream();
    boolean tooLong;

    Capped(Long max) {
      this.max = max;
    }

    /** Adds bytes; false once the cap is passed, so reading stops. */
    boolean add(byte[] buffer, int n) {
      if (max != null && out.size() + (long) n > max) {
        out.write(buffer, 0, (int) (max - out.size()));
        tooLong = true;
        return false;
      }
      out.write(buffer, 0, n);
      return true;
    }

    byte[] bytes() {
      return out.toByteArray();
    }
  }

  private static InputStream decoder(InputStream raw, String encoding) throws IOException {
    if (encoding == null) {
      return raw;
    }
    String kind = encoding.trim().toLowerCase(Locale.ROOT);
    if (kind.equals("gzip") || kind.equals("x-gzip")) {
      return new GZIPInputStream(raw);
    }
    if (kind.equals("deflate")) {
      // Servers send deflate both wrapped in zlib and raw; the first byte tells them apart.
      java.io.PushbackInputStream peek = new java.io.PushbackInputStream(raw, 1);
      int first = peek.read();
      if (first < 0) {
        return new ByteArrayInputStream(new byte[0]);
      }
      peek.unread(first);
      boolean zlib = (first & 0x0f) == 8;
      return new InflaterInputStream(peek, new Inflater(!zlib));
    }
    return raw;
  }

  /** At most a number of bytes from a stream: a body with a Content-Length. */
  private static final class Limited extends InputStream {
    private final InputStream in;
    private long left;

    Limited(InputStream in, long left) {
      this.in = in;
      this.left = left;
    }

    @Override
    public int read() throws IOException {
      if (left <= 0) {
        return -1;
      }
      int b = in.read();
      if (b >= 0) {
        left--;
      }
      return b;
    }

    @Override
    public int read(byte[] buffer, int offset, int length) throws IOException {
      if (left <= 0) {
        return -1;
      }
      int n = in.read(buffer, offset, (int) Math.min(length, left));
      if (n > 0) {
        left -= n;
      }
      return n;
    }
  }

  /** The socket's input, each read held to the time the whole request has left. */
  private static final class DeadlineInput extends InputStream {
    private final Socket socket;
    private final Exchange exchange;
    private final InputStream in;
    private final byte[] one = new byte[1];
    private final byte[] buffer = new byte[16_384];
    private int at;
    private int end;

    DeadlineInput(Socket socket, Exchange exchange) throws IOException {
      this.socket = socket;
      this.exchange = exchange;
      this.in = socket.getInputStream();
    }

    private boolean fill() throws IOException {
      if (at < end) {
        return true;
      }
      socket.setSoTimeout(exchange.left());
      int n = in.read(buffer);
      if (n <= 0) {
        return false;
      }
      at = 0;
      end = n;
      return true;
    }

    @Override
    public int read() throws IOException {
      return read(one, 0, 1) < 0 ? -1 : one[0] & 0xff;
    }

    @Override
    public int read(byte[] target, int offset, int length) throws IOException {
      if (length == 0) {
        return 0;
      }
      if (!fill()) {
        return -1;
      }
      int n = Math.min(length, end - at);
      System.arraycopy(buffer, at, target, offset, n);
      at += n;
      return n;
    }
  }
}
