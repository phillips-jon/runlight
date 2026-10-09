package sh.runlight.mail;

import java.io.IOException;
import java.io.InputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;
import javax.net.ssl.SNIHostName;
import javax.net.ssl.SSLParameters;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;
import sh.runlight.Js;
import sh.runlight.Json;

/**
 * One SMTP connection for {@link Smtp#send}: the socket, the replies read from it (multi-line
 * included, one at a time), and the whole send's deadline, which every wait is held to.
 */
public final class SmtpSession {
  private static final Pattern LITERAL = Pattern.compile("^[0-9.]+\\z|:");

  private final String host;
  private final int port;
  private final long deadline;
  private final String lateMessage;
  private final SSLSocketFactory tls;
  private Socket socket;
  private InputStream in;
  private final StringBuilder buffer = new StringBuilder();
  private final List<String> lines = new ArrayList<>();

  /**
   * A session, not yet connected.
   *
   * @param deadline when the whole send must be done, on {@link System#nanoTime()}
   * @param lateMessage what the error says once the deadline passes
   * @param tls where TLS connections come from; null for the JDK's default
   */
  public SmtpSession(
      String host, int port, long deadline, String lateMessage, SSLSocketFactory tls) {
    this.host = host;
    this.port = port;
    this.deadline = deadline;
    this.lateMessage = lateMessage;
    this.tls = tls != null ? tls : (SSLSocketFactory) SSLSocketFactory.getDefault();
  }

  private MailError late() {
    close();
    return new MailError(lateMessage, "mail_slow", Json.object("host", host + ":" + port));
  }

  /** Milliseconds left before the deadline. */
  private long left() {
    return Math.floorDiv(deadline - System.nanoTime(), 1_000_000L);
  }

  private static int millis(long ms) {
    return (int) Math.max(1, Math.min(ms, Integer.MAX_VALUE));
  }

  public void connect(boolean secure, long timeoutMs) {
    long wait = Math.min(timeoutMs, left());
    if (wait <= 0) {
      throw late();
    }
    Socket candidate = new Socket();
    try {
      candidate.connect(new InetSocketAddress(host, port), millis(wait));
      socket = candidate;
      if (secure) {
        socket = secure(socket);
      }
      in = socket.getInputStream();
    } catch (IOException e) {
      try {
        candidate.close();
      } catch (IOException ignored) {
        // Already gone.
      }
      socket = null;
      if (left() <= 0) {
        throw late();
      }
      String detail =
          e instanceof SocketTimeoutException
              ? "timed out"
              : e.getMessage() != null ? e.getMessage() : "connection failed";
      throw new MailError(
          "SMTP: could not connect to " + host + ":" + port + ": " + detail,
          "mail_unreachable",
          Json.object("host", host + ":" + port, "detail", detail));
    }
  }

  /** TLS over a connected socket, the certificate checked against the host name. */
  private Socket secure(Socket plain) throws IOException {
    SSLSocket secured = (SSLSocket) tls.createSocket(plain, host, port, true);
    SSLParameters parameters = secured.getSSLParameters();
    parameters.setEndpointIdentificationAlgorithm("HTTPS");
    if (!LITERAL.matcher(host).find()) {
      parameters.setServerNames(List.of(new SNIHostName(host)));
    }
    secured.setSSLParameters(parameters);
    long wait = left();
    if (wait <= 0) {
      throw new SocketTimeoutException("deadline");
    }
    secured.setSoTimeout(millis(wait));
    secured.startHandshake();
    return secured;
  }

  public void write(String line) {
    writeRaw(line + "\r\n");
  }

  public void writeRaw(String data) {
    if (socket == null) {
      throw new MailError("SMTP: the server closed the connection");
    }
    if (left() <= 0) {
      throw late();
    }
    try {
      socket.getOutputStream().write(Js.utf8(data));
      socket.getOutputStream().flush();
    } catch (IOException e) {
      if (left() <= 0) {
        throw late();
      }
      throw new MailError("SMTP: the server closed the connection");
    }
  }

  /**
   * The next whole reply, as {@code code} and {@code text}. Throws when none comes within {@code
   * timeoutMs} (or, with {@code quiet}, gives null then), and a mail_slow error once the deadline
   * passes.
   */
  public Map<String, Object> next(long timeoutMs, boolean quiet) {
    long idleUntil = System.nanoTime() + timeoutMs * 1_000_000L;
    byte[] chunk = new byte[8192];
    for (; ; ) {
      int at;
      while ((at = buffer.indexOf("\r\n")) >= 0) {
        String line = buffer.substring(0, at);
        buffer.delete(0, at + 2);
        lines.add(line.length() > 4 ? line.substring(4) : "");
        if (line.length() < 4 || line.charAt(3) != '-') {
          // Number() of the first three characters, as TS reads the code: NaN when not a number.
          String head = line.length() > 3 ? line.substring(0, 3) : line;
          Map<String, Object> reply =
              Json.object("code", Js.num(Js.toNumber(head)), "text", String.join(" ", lines));
          lines.clear();
          return reply;
        }
        // Activity resets the idle timer, as Node's socket timeout does.
        idleUntil = System.nanoTime() + timeoutMs * 1_000_000L;
      }
      if (socket == null) {
        throw new MailError("SMTP: the server closed the connection");
      }
      long deadlineLeft = left();
      if (deadlineLeft <= 0) {
        throw late();
      }
      long idleLeft = Math.floorDiv(idleUntil - System.nanoTime(), 1_000_000L);
      if (idleLeft <= 0) {
        if (quiet) {
          return null;
        }
        close();
        throw new MailError("SMTP: timed out");
      }
      int n;
      try {
        socket.setSoTimeout(millis(Math.min(deadlineLeft, idleLeft)));
        n = in.read(chunk);
      } catch (SocketTimeoutException e) {
        // Nothing came in the time left; the checks above decide what that means.
        continue;
      } catch (IOException e) {
        close();
        throw new MailError("SMTP: the server closed the connection");
      }
      if (n < 0) {
        close();
        throw new MailError("SMTP: the server closed the connection");
      }
      if (n > 0) {
        // Each chunk decoded on its own, as Node's chunk.toString("utf8") does.
        buffer.append(new String(chunk, 0, n, StandardCharsets.UTF_8));
        idleUntil = System.nanoTime() + timeoutMs * 1_000_000L;
      }
    }
  }

  /**
   * Turns on TLS after STARTTLS. Anything the server sent before it is dropped, as a new reader
   * would.
   */
  public void startTls() {
    buffer.setLength(0);
    lines.clear();
    if (left() <= 0) {
      throw late();
    }
    try {
      socket = secure(socket);
      in = socket.getInputStream();
    } catch (IOException e) {
      if (left() <= 0) {
        throw late();
      }
      throw new MailError(
          "SMTP: TLS failed: " + (e.getMessage() != null ? e.getMessage() : "handshake failed"));
    }
  }

  public void close() {
    if (socket != null) {
      try {
        socket.close();
      } catch (IOException e) {
        // Already gone.
      }
      socket = null;
    }
  }
}
