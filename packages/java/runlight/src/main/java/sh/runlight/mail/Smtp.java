package sh.runlight.mail;

import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.function.Supplier;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import sh.runlight.Js;
import sh.runlight.Json;

/**
 * A small SMTP client: implicit TLS (465), STARTTLS (587), or plain (local relays), with AUTH
 * PLAIN, over a socket.
 */
public final class Smtp {
  private Smtp() {}

  /** Each reply must come within this long. */
  private static final long REPLY_TIMEOUT_MS = 20_000;

  private static final Pattern PRINTABLE = Pattern.compile("^[\\x20-\\x7e]*\\z");
  private static final Pattern NAMED = Pattern.compile("^(" + Js.DOT + "*)<(" + Js.DOT + "+)>\\z");
  private static final Pattern STARTTLS = Pattern.compile("STARTTLS", Pattern.CASE_INSENSITIVE);
  private static final DateTimeFormatter DATE =
      DateTimeFormatter.ofPattern("EEE, dd MMM yyyy HH:mm:ss", Locale.ENGLISH)
          .withZone(ZoneOffset.UTC);

  private static String b64(String text) {
    return Base64.getEncoder().encodeToString(Js.utf8(text));
  }

  private static String encodeWord(String text) {
    return PRINTABLE.matcher(text).matches() ? text : "=?UTF-8?B?" + b64(text) + "?=";
  }

  /** Base64 in lines of 76, each ending in CRLF, as {@code .replace(/.{1,76}/g, "$&\r\n")}. */
  private static String wrap(String text) {
    StringBuilder out = new StringBuilder();
    for (int i = 0; i < text.length(); i += 76) {
      out.append(text, i, Math.min(text.length(), i + 76)).append("\r\n");
    }
    return out.toString();
  }

  /** The message as MIME on the wall clock, with random UUIDs. */
  public static String mime(Map<String, Object> m, String from) {
    return mime(m, from, null, null);
  }

  /**
   * The message as MIME: text and HTML alternatives, both base64. Public for its test.
   *
   * @param now milliseconds; null for the clock
   * @param uuid stands in for crypto.randomUUID() in tests; null for random ones
   */
  public static String mime(Map<String, Object> m, String from, Long now, Supplier<String> uuid) {
    Supplier<String> ids = uuid != null ? uuid : () -> UUID.randomUUID().toString();
    long at = now != null ? now : System.currentTimeMillis();
    String boundary = "rl-" + ids.get();
    String[] at1 = Transports.value(m, "from").split("@", -1);
    String domain = at1.length > 1 ? at1[1] : "runlight.local";
    Matcher named = NAMED.matcher(from);
    String fromHeader =
        named.matches() ? encodeWord(Js.trim(named.group(1))) + " <" + named.group(2) + ">" : from;
    List<String> headers = new ArrayList<>();
    headers.add("From: " + fromHeader);
    headers.add("To: " + Transports.value(m, "to"));
    headers.add("Subject: " + encodeWord(Transports.value(m, "subject")));
    // Date's toUTCString(), with +0000 for GMT.
    headers.add("Date: " + DATE.format(Instant.ofEpochMilli(at)) + " +0000");
    headers.add("Message-ID: <" + ids.get() + "@" + domain + ">");
    headers.add("MIME-Version: 1.0");
    Map<String, Object> extra = Js.map(m.get("headers"));
    if (extra != null) {
      for (Map.Entry<String, Object> entry : extra.entrySet()) {
        headers.add(entry.getKey() + ": " + Js.string(entry.getValue()).replaceAll("[\r\n]", ""));
      }
    }
    headers.add("Content-Type: multipart/alternative; boundary=\"" + boundary + "\"");
    return String.join(
        "\r\n",
        String.join("\r\n", headers),
        "",
        "--" + boundary,
        "Content-Type: text/plain; charset=utf-8",
        "Content-Transfer-Encoding: base64",
        "",
        wrap(b64(Transports.value(m, "text"))),
        "--" + boundary,
        "Content-Type: text/html; charset=utf-8",
        "Content-Transfer-Encoding: base64",
        "",
        wrap(b64(Transports.value(m, "html"))),
        "--" + boundary + "--",
        "");
  }

  /** Sends one message within 60 seconds. */
  public static void send(Map<String, Object> config, Map<String, Object> m, String from) {
    send(config, m, from, 60_000, null, null);
  }

  /**
   * Sends one message. Each reply must come within 20 s, and the whole send within the deadline (60
   * s), so a server that trickles a line now and then cannot hold the scheduled check that sends
   * reports. Its deadline is a parameter for its test, as are the clock and UUIDs the MIME is
   * written with.
   *
   * @param deadline milliseconds for the whole send
   * @param now milliseconds; null for the clock
   * @param uuid stands in for crypto.randomUUID() in tests; null for random ones
   */
  public static void send(
      Map<String, Object> config,
      Map<String, Object> m,
      String from,
      long deadline,
      Long now,
      Supplier<String> uuid) {
    String host = Js.trim(Transports.value(config, "host"));
    String security = Transports.value(config, "security");
    if (security == null || security.isEmpty()) {
      security = "starttls";
    }
    String portText = Transports.value(config, "port");
    double number = Js.toNumber(portText == null ? Json.UNDEFINED : portText);
    int port =
        Double.isNaN(number) || number == 0 ? (security.equals("tls") ? 465 : 587) : (int) number;
    SmtpSession session =
        new SmtpSession(
            host,
            port,
            System.nanoTime() + deadline * 1_000_000L,
            "SMTP: "
                + host
                + ":"
                + port
                + " took longer than "
                + Json.number(Js.round(deadline / 1000.0))
                + " s",
            null);
    try {
      converse(session, config, m, from, security, now, uuid);
    } finally {
      session.close();
    }
  }

  private static Map<String, Object> expect(SmtpSession s, List<Long> codes, String what) {
    Map<String, Object> reply = s.next(REPLY_TIMEOUT_MS, false);
    if (!(reply.get("code") instanceof Long code && codes.contains(code))) {
      throw new MailError(
          Js.slice(
              "SMTP " + what + ": " + Js.string(reply.get("code")) + " " + reply.get("text"),
              0,
              300));
    }
    return reply;
  }

  private static void converse(
      SmtpSession s,
      Map<String, Object> config,
      Map<String, Object> m,
      String from,
      String security,
      Long now,
      Supplier<String> uuid) {
    s.connect(security.equals("tls"), REPLY_TIMEOUT_MS);
    expect(s, List.of(220L), "greeting");
    String[] parts = from.split("@", -1);
    String name = parts.length > 1 ? parts[1].replaceAll(">\\z", "") : "";
    if (name.isEmpty()) {
      name = "localhost";
    }
    s.write("EHLO " + name);
    Map<String, Object> ehlo = expect(s, List.of(250L), "EHLO");
    if (security.equals("starttls")) {
      if (!STARTTLS.matcher((String) ehlo.get("text")).find()) {
        throw new MailError(
            "SMTP: the server does not offer STARTTLS; pick tls or none",
            "smtp_starttls",
            Json.object());
      }
      s.write("STARTTLS");
      expect(s, List.of(220L), "STARTTLS");
      s.startTls();
      s.write("EHLO " + name);
      expect(s, List.of(250L), "EHLO");
    }
    String username = Transports.value(config, "username");
    if (username != null && !username.isEmpty()) {
      String password = Transports.value(config, "password");
      s.write("AUTH PLAIN " + b64("\0" + username + "\0" + (password == null ? "" : password)));
      expect(s, List.of(235L), "sign-in");
    }
    s.write("MAIL FROM:<" + Transports.value(m, "from") + ">");
    expect(s, List.of(250L), "MAIL FROM");
    s.write("RCPT TO:<" + Transports.value(m, "to") + ">");
    expect(s, List.of(250L, 251L), "RCPT TO");
    s.write("DATA");
    expect(s, List.of(354L), "DATA");
    // A line starting with a dot gets a second one, so it is not read as the end.
    s.writeRaw(mime(m, from, now, uuid).replace("\r\n.", "\r\n..") + "\r\n.\r\n");
    expect(s, List.of(250L), "message");
    s.write("QUIT");
    // Wait for the goodbye, but never fail a sent message over it.
    try {
      s.next(2000, true);
    } catch (MailError error) {
      if (error.code().equals("mail_slow")) {
        throw error;
      }
    }
  }
}
