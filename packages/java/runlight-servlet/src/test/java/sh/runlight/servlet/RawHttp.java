package sh.runlight.servlet;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * A plain HTTP/1.1 client over a socket, since the JDK's client will not send a Host of the test's
 * choosing. Each request is on a connection of its own, closed after the answer.
 */
final class RawHttp {
  private RawHttp() {}

  /** An answer: its status, its header lines in order (names lowercased), and its body. */
  static final class Answer {
    private final int status;
    private final List<Map.Entry<String, String>> headers;
    private final byte[] body;

    Answer(int status, List<Map.Entry<String, String>> headers, byte[] body) {
      this.status = status;
      this.headers = headers;
      this.body = body;
    }

    int status() {
      return status;
    }

    byte[] body() {
      return body.clone();
    }

    /** The first value of a header, or null. */
    String header(String name) {
      for (Map.Entry<String, String> h : headers) {
        if (h.getKey().equals(name)) {
          return h.getValue();
        }
      }
      return null;
    }

    /** Every value of a header, one per line. */
    List<String> all(String name) {
      List<String> out = new ArrayList<>();
      for (Map.Entry<String, String> h : headers) {
        if (h.getKey().equals(name)) {
          out.add(h.getValue());
        }
      }
      return out;
    }

    String text() {
      return new String(body, StandardCharsets.UTF_8);
    }
  }

  static Answer get(int port, String target, String... headers) throws IOException {
    return send(port, "GET", target, null, headers);
  }

  /** Sends one request; headers are name and value pairs, Host defaulting to example.com. */
  static Answer send(int port, String method, String target, byte[] body, String... headers)
      throws IOException {
    StringBuilder head = new StringBuilder(method + " " + target + " HTTP/1.1\r\n");
    boolean host = false;
    for (int i = 0; i + 1 < headers.length; i += 2) {
      host |= headers[i].equalsIgnoreCase("host");
      head.append(headers[i]).append(": ").append(headers[i + 1]).append("\r\n");
    }
    if (!host) {
      head.append("Host: example.com\r\n");
    }
    if (body != null) {
      head.append("Content-Length: ").append(body.length).append("\r\n");
    }
    head.append("Connection: close\r\n\r\n");
    try (Socket socket = new Socket(InetAddress.getByAddress(new byte[] {127, 0, 0, 1}), port)) {
      socket.setSoTimeout(30_000);
      OutputStream out = socket.getOutputStream();
      out.write(head.toString().getBytes(StandardCharsets.UTF_8));
      if (body != null) {
        try {
          out.write(body);
        } catch (IOException e) {
          // The server answered and closed before taking all of it.
        }
      }
      out.flush();
      return read(socket.getInputStream());
    }
  }

  private static Answer read(InputStream in) throws IOException {
    String status = line(in);
    int code = Integer.parseInt(status.split(" ", 3)[1]);
    List<Map.Entry<String, String>> headers = new ArrayList<>();
    for (String line = line(in); !line.isEmpty(); line = line(in)) {
      int colon = line.indexOf(':');
      headers.add(
          Map.entry(
              line.substring(0, colon).trim().toLowerCase(Locale.ROOT),
              line.substring(colon + 1).trim()));
    }
    Answer partial = new Answer(code, headers, new byte[0]);
    String encoding = partial.header("transfer-encoding");
    ByteArrayOutputStream body = new ByteArrayOutputStream();
    if (encoding != null && encoding.toLowerCase(Locale.ROOT).contains("chunked")) {
      while (true) {
        String size = line(in);
        int n = Integer.parseInt(size.split(";", 2)[0].trim(), 16);
        if (n == 0) {
          break;
        }
        body.write(in.readNBytes(n));
        line(in);
      }
    } else if (partial.header("content-length") != null) {
      body.write(in.readNBytes(Integer.parseInt(partial.header("content-length"))));
    } else {
      body.write(in.readAllBytes());
    }
    return new Answer(code, headers, body.toByteArray());
  }

  private static String line(InputStream in) throws IOException {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    int c;
    while ((c = in.read()) != -1 && c != '\n') {
      if (c != '\r') {
        out.write(c);
      }
    }
    return out.toString(StandardCharsets.ISO_8859_1);
  }
}
