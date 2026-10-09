package sh.runlight.mail;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.fail;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyStore;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Supplier;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.TrustManagerFactory;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.function.Executable;
import sh.runlight.Fixtures;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.RecordingFetcher;
import sh.runlight.http.FetchError;
import sh.runlight.http.Response;
import sh.runlight.http.SearchParams;

/**
 * Ports mail.test.ts, and replays outbound.json: every service sends the TypeScript SDK's exact
 * requests.
 */
class MailTest {
  private static Map<String, Object> message() {
    return Json.object(
        "to", "jon@example.com",
        "from", "reports@example.com",
        "fromName", "Runlight",
        "subject", "Hello",
        "html", "<p>Hi</p>",
        "text", "Hi",
        "headers", Json.object("List-Unsubscribe", "<https://x/u>"));
  }

  private static Map<String, Object> message(Object... changes) {
    Map<String, Object> m = message();
    m.putAll(Json.object(changes));
    return m;
  }

  private static Map<String, Object> fixture() {
    return Fixtures.load("outbound");
  }

  private static RecordingFetcher capture(int status) {
    return new RecordingFetcher((url, init) -> new Response(status == 200 ? "{}" : "nope", status));
  }

  /** A UUID stand-in that counts from 1, as the fixture script's does. */
  private static Supplier<String> uuids() {
    AtomicInteger n = new AtomicInteger();
    return () -> String.format("00000000-0000-4000-8000-%012d", n.incrementAndGet());
  }

  private static Map<String, Object> config(Object... pairs) {
    return Json.object(pairs);
  }

  private static Map<String, Object> error(MailError e) {
    return Json.object("message", e.getMessage(), "code", e.code(), "params", e.params());
  }

  private static void assertThrowsMatching(String pattern, Executable run) {
    MailError error = assertThrows(MailError.class, run);
    assertTrue(
        java.util.regex.Pattern.compile(pattern).matcher(error.getMessage()).find(),
        error.getMessage());
  }

  @Test
  void sealedKeysOpenOnlyWithTheSameSecret() {
    String sealed = Secret.seal("{\"apiKey\":\"re_123\"}", "server secret");
    assertTrue(sealed.startsWith("v1:") && !sealed.contains("re_123"));
    assertEquals("{\"apiKey\":\"re_123\"}", Secret.unseal(sealed, "server secret"));
    assertNull(Secret.unseal(sealed, "another secret"));
    assertEquals(
        "x", Secret.unseal(Secret.seal("x", null), null), "with no secret the value is as typed");
    assertNull(Secret.unseal("v1:AAAA:AAAA", "server secret"), "damaged");
    assertNull(Secret.unseal("v2:a:b", "server secret"));
    assertNull(Secret.unseal("v1:!!:??", "server secret"));
    assertNull(Secret.unseal(sealed, null));
  }

  @Test
  void keysSealedByTypeScriptOpenHere() {
    for (Map<String, Object> c : Fixtures.cases(fixture(), "sealed")) {
      String value = (String) c.get("value");
      String secret = (String) c.get("secret");
      assertEquals(value, Secret.unseal((String) c.get("sealed"), secret));
      assertNull(Secret.unseal((String) c.get("sealed"), secret + "!"));
      // A value of null is a sealed form TypeScript cannot open (an IV under 12 bytes), so there is
      // nothing to seal again.
      if (value != null) {
        assertEquals(value, Secret.unseal(Secret.seal(value, secret), secret));
      }
    }
  }

  @Test
  void sigV4MatchesAwsPublishedExample() {
    // https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html (ListUsers)
    Map<String, Object> headers =
        Ses.signV4(
            Json.object(
                "method", "GET",
                "url", "https://iam.amazonaws.com/?Action=ListUsers&Version=2010-05-08",
                "body", "",
                "region", "us-east-1",
                "service", "iam",
                "accessKeyId", "AKIDEXAMPLE",
                "secretAccessKey", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
                "now", Instant.parse("2015-08-30T12:36:00Z").toEpochMilli(),
                "headers",
                    Json.object(
                        "content-type", "application/x-www-form-urlencoded; charset=utf-8")));
    assertEquals(
        "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/iam/aws4_request,"
            + " SignedHeaders=content-type;host;x-amz-date,"
            + " Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7",
        headers.get("authorization"));
  }

  @Test
  void sigV4MatchesTypeScript() {
    for (Map<String, Object> c : Fixtures.cases(fixture(), "signatures")) {
      Map<String, Object> input = Js.map(c.get("input"));
      Fixtures.assertJson(c.get("headers"), Ses.signV4(input), (String) input.get("url"));
    }
  }

  @Test
  void eachServiceGetsTheRequestItDocuments() {
    RecordingFetcher calls = capture(200);
    Transports.send(config("service", "resend", "apiKey", "re_1"), message(), calls);
    Map<String, Object> first = calls.requests.get(0);
    assertEquals("https://api.resend.com/emails", first.get("url"));
    assertEquals("Bearer re_1", Js.map(first.get("headers")).get("authorization"));
    Map<String, Object> body = Js.map(Json.parse((String) first.get("body")));
    assertEquals(List.of("jon@example.com"), body.get("to"));
    assertEquals("Runlight <reports@example.com>", body.get("from"));

    calls = capture(200);
    Transports.send(config("service", "postmark", "serverToken", "pm"), message(), calls);
    first = calls.requests.get(0);
    assertEquals("pm", Js.map(first.get("headers")).get("x-postmark-server-token"));
    assertEquals("outbound", Js.map(Json.parse((String) first.get("body"))).get("MessageStream"));

    calls = capture(200);
    Transports.send(
        config("service", "mailgun", "apiKey", "key", "domain", "mg.example.com", "region", "eu"),
        message(),
        calls);
    first = calls.requests.get(0);
    assertEquals("https://api.eu.mailgun.net/v3/mg.example.com/messages", first.get("url"));
    assertEquals(
        "Basic " + Base64.getEncoder().encodeToString("api:key".getBytes(StandardCharsets.UTF_8)),
        Js.map(first.get("headers")).get("authorization"));
    assertEquals(
        "<https://x/u>", new SearchParams((String) first.get("body")).get("h:List-Unsubscribe"));

    calls = capture(200);
    Transports.send(
        config(
            "service", "ses",
            "region", "eu-west-1",
            "accessKeyId", "AKID",
            "secretAccessKey", "secret"),
        message(),
        calls);
    first = calls.requests.get(0);
    assertEquals(
        "https://email.eu-west-1.amazonaws.com/v2/email/outbound-emails", first.get("url"));
    assertTrue(
        ((String) Js.map(first.get("headers")).get("authorization"))
            .matches("^AWS4-HMAC-SHA256 Credential=AKID/\\d{8}/eu-west-1/ses/aws4_request.*"));

    calls = capture(200);
    Transports.send(
        config("service", "webhook", "url", "https://hooks.example.com/mail", "secret", "s"),
        message(),
        calls);
    assertTrue(
        ((String) Js.map(calls.requests.get(0).get("headers")).get("x-runlight-signature"))
            .matches("^sha256=[a-f0-9]{64}\\z"));

    RecordingFetcher refused = capture(401);
    assertThrowsMatching(
        "api.sendgrid.com answered 401",
        () -> Transports.send(config("service", "sendgrid", "apiKey", "bad"), message(), refused));
    assertThrowsMatching(
        "must use https",
        () ->
            Transports.send(
                config("service", "webhook", "url", "http://example.com/x"), message(), refused));
    assertThrowsMatching(
        "Enter the api key",
        () -> Transports.send(config("service", "resend"), message(), refused));
  }

  @Test
  void everyServiceSendsTheTypeScriptRequestsExactly() {
    long now = Js.asLong(fixture().get("now"));
    List<Map<String, Object>> cases = Fixtures.cases(fixture(), "mail");
    assertTrue(cases.size() > 50);
    for (int i = 0; i < cases.size(); i++) {
      Map<String, Object> c = cases.get(i);
      Object answer = c.get("answer");
      RecordingFetcher fetcher =
          new RecordingFetcher(
              (url, init) -> {
                if ("unreachable".equals(answer)) {
                  throw new FetchError("fetch failed");
                }
                Map<String, Object> a = Js.map(answer);
                return new Response((String) a.get("body"), (int) Js.asLong(a.get("status")));
              });
      Object error = null;
      try {
        Transports.send(Js.map(c.get("config")), Js.map(c.get("message")), fetcher, now);
      } catch (MailError e) {
        error = error(e);
      }
      String label = "case " + i + ": " + Json.stringify(c.get("config"));
      Fixtures.assertJson(c.get("requests"), fetcher.requests, label);
      Fixtures.assertJson(c.get("error"), error, label);
    }
  }

  @Test
  void serviceMessagesMatchTypeScript() {
    for (Map<String, Object> c : Fixtures.cases(fixture(), "replies")) {
      assertEquals(
          c.get("message"),
          Transports.serviceMessage((String) c.get("reply")),
          (String) c.get("reply"));
    }
  }

  @Test
  void mimeMatchesTypeScript() {
    for (Map<String, Object> c : Fixtures.cases(fixture(), "mimes")) {
      assertEquals(
          c.get("mime"),
          Smtp.mime(
              Js.map(c.get("message")), (String) c.get("from"), Js.asLong(c.get("now")), uuids()));
    }
    String raw = Smtp.mime(message("subject", "Café report"), "Runlight <reports@example.com>");
    assertTrue(raw.contains("Subject: =?UTF-8?B?"), raw);
    assertTrue(
        java.util.regex.Pattern.compile(
                "boundary=\"rl-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\"")
            .matcher(raw)
            .find(),
        raw);
  }

  @Test
  void smtpSendsTheTypeScriptConversation() throws Exception {
    try (FakeSmtp server = new FakeSmtp(false)) {
      for (Map<String, Object> c : Fixtures.cases(fixture(), "smtp")) {
        Map<String, Object> config = new LinkedHashMap<>(Js.map(c.get("config")));
        config.put("service", "smtp");
        config.put("host", "127.0.0.1");
        config.put("port", Integer.toString(server.port()));
        Object error = null;
        try {
          Smtp.send(
              config,
              Js.map(c.get("message")),
              (String) c.get("from"),
              60_000,
              Js.asLong(fixture().get("now")),
              uuids());
        } catch (MailError e) {
          error = error(e);
        }
        Fixtures.assertJson(c.get("error"), error);
        Map<String, Object> conversation = server.conversation(5000);
        assertEquals(c.get("received"), conversation == null ? null : conversation.get("received"));
      }
    }
  }

  @Test
  void smtpStartTlsRefusedIsAnErrorAndAPlainRelayTakesTheMessage() throws Exception {
    try (FakeSmtp server = new FakeSmtp(false)) {
      Map<String, Object> base =
          config("service", "smtp", "host", "127.0.0.1", "port", Integer.toString(server.port()));
      Map<String, Object> starttls = new LinkedHashMap<>(base);
      starttls.put("security", "starttls");
      assertThrowsMatching(
          "does not offer STARTTLS", () -> Smtp.send(starttls, message(), "reports@example.com"));
      server.conversation(5000);
      Map<String, Object> plain = new LinkedHashMap<>(base);
      plain.putAll(config("security", "none", "username", "jon", "password", "pw"));
      Smtp.send(plain, message("text", ".starts with a dot"), "Runlight <reports@example.com>");
      String received = (String) server.conversation(5000).get("received");
      List<String> seen = new ArrayList<>();
      boolean inData = false;
      StringBuilder data = new StringBuilder();
      for (String line : received.split("\r\n", -1)) {
        if (inData) {
          if (line.equals(".")) {
            inData = false;
          } else {
            data.append(line).append('\n');
          }
          continue;
        }
        if (!line.isEmpty()) {
          seen.add(line.split(" ", -1)[0]);
        }
        inData = line.equals("DATA");
      }
      assertEquals(List.of("EHLO", "AUTH", "MAIL", "RCPT", "DATA", "QUIT"), seen);
      assertTrue(data.toString().contains("Subject: Hello"));
      assertTrue(data.toString().contains("List-Unsubscribe: <https://x/u>"));
      assertTrue(data.toString().contains("multipart/alternative"));
    }
  }

  @Test
  void smtpThroughTransportsSendsToo() throws Exception {
    try (FakeSmtp server = new FakeSmtp(false)) {
      Transports.send(
          config(
              "service", "smtp",
              "host", "127.0.0.1",
              "port", Integer.toString(server.port()),
              "security", "none"),
          message(),
          null);
      assertTrue(
          ((String) server.conversation(5000).get("received"))
              .contains("From: Runlight <reports@example.com>\r\n"));
    }
  }

  @Test
  void smtpServerThatTricklesIsCutOffAtTheDeadline() throws Exception {
    try (FakeSmtp server = new FakeSmtp(true)) {
      long started = System.nanoTime();
      MailError error =
          assertThrows(
              MailError.class,
              () ->
                  Smtp.send(
                      config(
                          "service", "smtp",
                          "host", "127.0.0.1",
                          "port", Integer.toString(server.port()),
                          "security", "none"),
                      message(),
                      "reports@example.com",
                      600,
                      null,
                      null));
      assertEquals("mail_slow", error.code(), error.getMessage());
      assertEquals(Json.object("host", "127.0.0.1:" + server.port()), error.params());
      assertEquals(
          "SMTP: 127.0.0.1:" + server.port() + " took longer than 1 s", error.getMessage());
      assertTrue((System.nanoTime() - started) / 1_000_000 < 2000, "it gives up at its deadline");
      Map<String, Object> conversation = server.conversation(2000);
      assertNotNull(conversation);
      assertEquals(true, conversation.get("closed"), "the connection is closed");
    }
  }

  /**
   * A server on 127.0.0.1 that writes each of {@code parts} to the first connection, pausing
   * between them so each is a read of its own, and then hangs up.
   */
  private static ServerSocket sayAndHangUp(byte[]... parts) throws IOException {
    ServerSocket server = new ServerSocket(0, 1, InetAddress.getLoopbackAddress());
    Thread thread =
        new Thread(
            () -> {
              try (Socket socket = server.accept()) {
                socket.setTcpNoDelay(true);
                OutputStream out = socket.getOutputStream();
                for (int i = 0; i < parts.length; i++) {
                  if (i > 0) {
                    Thread.sleep(150);
                  }
                  out.write(parts[i]);
                  out.flush();
                }
              } catch (IOException | InterruptedException e) {
                // The test sees what came of it.
              }
            },
            "say-and-hang-up");
    thread.setDaemon(true);
    thread.start();
    return server;
  }

  @Test
  void smtpReplyJustBeforeTheServerClosesIsTheErrorNotTheClose() throws Exception {
    try (ServerSocket server = sayAndHangUp("535 no\r\n".getBytes(StandardCharsets.US_ASCII))) {
      SmtpSession session =
          new SmtpSession(
              "127.0.0.1", server.getLocalPort(), System.nanoTime() + 5_000_000_000L, "late", null);
      session.connect(false, 5000);
      // Both the reply and the close are in before anyone asks.
      Thread.sleep(300);
      assertEquals(Json.object("code", 535L, "text", "no"), session.next(5000, false));
      MailError closed = assertThrows(MailError.class, () -> session.next(5000, false));
      assertEquals("SMTP: the server closed the connection", closed.getMessage());
      session.close();
    }
    try (ServerSocket server = sayAndHangUp("535 no\r\n".getBytes(StandardCharsets.US_ASCII))) {
      assertThrowsMatching(
          "^SMTP greeting: 535 no\\z",
          () ->
              Smtp.send(
                  config(
                      "service", "smtp",
                      "host", "127.0.0.1",
                      "port", Integer.toString(server.getLocalPort()),
                      "security", "none"),
                  message(),
                  "reports@example.com"));
    }
  }

  @Test
  void smtpCharacterSplitAcrossTwoReadsComesThroughWhole() throws Exception {
    byte[] bytes = "250 caf\u00e9 ok\r\n".getBytes(StandardCharsets.UTF_8);
    int split = "250 caf".length() + 1;
    try (ServerSocket server =
        sayAndHangUp(
            Arrays.copyOfRange(bytes, 0, split), Arrays.copyOfRange(bytes, split, bytes.length))) {
      SmtpSession session =
          new SmtpSession(
              "127.0.0.1", server.getLocalPort(), System.nanoTime() + 5_000_000_000L, "late", null);
      session.connect(false, 5000);
      assertEquals(Json.object("code", 250L, "text", "caf\u00e9 ok"), session.next(5000, false));
      session.close();
    }
  }

  /**
   * A self-signed certificate for 127.0.0.1, made by keytool for this run: the server's keys, and a
   * client that trusts only it.
   */
  private record SelfSigned(SSLContext server, SSLContext client) {
    static SelfSigned make() throws Exception {
      Path dir = Files.createTempDirectory("runlight-smtp-tls");
      Path store = dir.resolve("smtp.p12");
      char[] password = "runlight-test".toCharArray();
      Process keytool =
          new ProcessBuilder(
                  Path.of(System.getProperty("java.home"), "bin", "keytool").toString(),
                  "-genkeypair",
                  "-alias",
                  "smtp",
                  "-keyalg",
                  "EC",
                  "-groupname",
                  "secp256r1",
                  "-dname",
                  "CN=127.0.0.1",
                  "-ext",
                  "SAN=ip:127.0.0.1",
                  "-validity",
                  "2",
                  "-storetype",
                  "PKCS12",
                  "-keystore",
                  store.toString(),
                  "-storepass",
                  new String(password),
                  "-keypass",
                  new String(password))
              .redirectErrorStream(true)
              .start();
      String output = new String(keytool.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
      assertEquals(0, keytool.waitFor(), output);
      KeyStore keys = KeyStore.getInstance("PKCS12");
      try (InputStream in = Files.newInputStream(store)) {
        keys.load(in, password);
      }
      Files.delete(store);
      Files.delete(dir);
      KeyManagerFactory keyManagers =
          KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
      keyManagers.init(keys, password);
      SSLContext server = SSLContext.getInstance("TLS");
      server.init(keyManagers.getKeyManagers(), null, null);
      KeyStore trusted = KeyStore.getInstance(KeyStore.getDefaultType());
      trusted.load(null, null);
      trusted.setCertificateEntry("smtp", keys.getCertificate("smtp"));
      TrustManagerFactory trustManagers =
          TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
      trustManagers.init(trusted);
      SSLContext client = SSLContext.getInstance("TLS");
      client.init(null, trustManagers.getTrustManagers(), null);
      return new SelfSigned(server, client);
    }
  }

  /** The commands a client sent, the message's lines left out. */
  private static List<String> commands(String received) {
    List<String> seen = new ArrayList<>();
    boolean inData = false;
    for (String line : received.split("\r\n", -1)) {
      if (inData) {
        inData = !line.equals(".");
        continue;
      }
      if (!line.isEmpty()) {
        seen.add(line.split(" ", -1)[0]);
      }
      inData = line.equals("DATA");
    }
    return seen;
  }

  @Test
  void smtpStartTlsAndImplicitTls() throws Exception {
    SelfSigned certificate = SelfSigned.make();
    try (FakeSmtp server = new FakeSmtp(certificate.server(), false)) {
      Map<String, Object> config =
          config(
              "service", "smtp",
              "host", "127.0.0.1",
              "port", Integer.toString(server.port()),
              "security", "starttls");
      Smtp.send(
          config,
          message(),
          "Runlight <reports@example.com>",
          60_000,
          null,
          null,
          certificate.client().getSocketFactory());
      String received = (String) server.conversation(5000).get("received");
      assertTrue(
          received.startsWith(
              "EHLO example.com\r\nSTARTTLS\r\nEHLO example.com\r\nMAIL FROM:<reports@example.com>\r\n"),
          received);
      assertTrue(received.endsWith("\r\n.\r\nQUIT\r\n"), received);
      // Without the certificate trusted, the JDK's default refuses it.
      MailError refused =
          assertThrows(MailError.class, () -> Smtp.send(config, message(), "reports@example.com"));
      assertEquals("mail_failed", refused.code());
      assertTrue(refused.getMessage().startsWith("SMTP: TLS failed: "), refused.getMessage());
      server.conversation(5000);
    }
    try (FakeSmtp server = new FakeSmtp(certificate.server(), true)) {
      Map<String, Object> config =
          config(
              "service", "smtp",
              "host", "127.0.0.1",
              "port", Integer.toString(server.port()),
              "security", "tls");
      Smtp.send(
          config,
          message(),
          "reports@example.com",
          60_000,
          null,
          null,
          certificate.client().getSocketFactory());
      assertEquals(
          List.of("EHLO", "MAIL", "RCPT", "DATA", "QUIT"),
          commands((String) server.conversation(5000).get("received")));
      MailError refused =
          assertThrows(MailError.class, () -> Smtp.send(config, message(), "reports@example.com"));
      assertEquals("mail_unreachable", refused.code());
      assertEquals("127.0.0.1:" + server.port(), refused.params().get("host"));
      assertTrue(
          refused
              .getMessage()
              .startsWith("SMTP: could not connect to 127.0.0.1:" + server.port() + ": "),
          refused.getMessage());
    }
  }

  @Test
  void smtpThatCannotConnectSaysSo() throws IOException {
    int port;
    try (ServerSocket probe = new ServerSocket(0, 1, InetAddress.getLoopbackAddress())) {
      port = probe.getLocalPort();
    }
    try {
      Smtp.send(
          config(
              "service", "smtp",
              "host", "127.0.0.1",
              "port", Integer.toString(port),
              "security", "none"),
          message(),
          "reports@example.com");
      fail("the send should fail");
    } catch (MailError error) {
      assertEquals("mail_unreachable", error.code());
      assertEquals("127.0.0.1:" + port, error.params().get("host"));
      assertTrue(
          error.getMessage().startsWith("SMTP: could not connect to 127.0.0.1:" + port + ": "),
          error.getMessage());
    }
  }

  @Test
  void errorsCarryCodesAndParams() {
    MailError error = new MailError("Something");
    assertEquals("mail_failed", error.code());
    assertEquals(Json.object("detail", "Something"), error.params());
    assertEquals("ses", Transports.SERVICES.get(0).get("id"));
  }

  /**
   * A fake SMTP server on 127.0.0.1, one connection at a time, recording every byte each client
   * sent.
   *
   * <p>relay: answers as the TS tests' relay does (AUTH PLAIN checks jon/pw, no STARTTLS). trickle:
   * sends "220-still here" every 100 ms and never finishes its greeting. With an SSLContext,
   * starttls is the relay offering STARTTLS and turning TLS on when asked, and tls is the relay
   * behind implicit TLS.
   */
  private static final class FakeSmtp implements AutoCloseable {
    private final ServerSocket server;
    private final boolean trickle;
    private final SSLContext starttls;
    private final BlockingQueue<Map<String, Object>> done = new LinkedBlockingQueue<>();
    private final Thread thread;

    FakeSmtp(boolean trickle) throws IOException {
      this(trickle, null, false);
    }

    /** The relay with TLS from {@code context}: implicit when {@code implicit}, else STARTTLS. */
    FakeSmtp(SSLContext context, boolean implicit) throws IOException {
      this(false, context, implicit);
    }

    private FakeSmtp(boolean trickle, SSLContext context, boolean implicit) throws IOException {
      this.server =
          implicit
              ? context
                  .getServerSocketFactory()
                  .createServerSocket(0, 10, InetAddress.getLoopbackAddress())
              : new ServerSocket(0, 10, InetAddress.getLoopbackAddress());
      this.trickle = trickle;
      this.starttls = implicit ? null : context;
      this.thread = new Thread(this::serve, "fake-smtp");
      thread.setDaemon(true);
      thread.start();
    }

    int port() {
      return server.getLocalPort();
    }

    /** What the next finished connection received, waiting up to this long for it. */
    Map<String, Object> conversation(long ms) throws InterruptedException {
      return done.poll(ms, TimeUnit.MILLISECONDS);
    }

    private void serve() {
      while (!server.isClosed()) {
        try (Socket socket = server.accept()) {
          done.add(trickle ? trickle(socket) : relay(socket, starttls));
        } catch (IOException e) {
          // Closed, or a client gone; the next one is served.
        }
      }
    }

    private static Map<String, Object> trickle(Socket socket) throws IOException {
      ByteArrayOutputStream received = new ByteArrayOutputStream();
      OutputStream out = socket.getOutputStream();
      InputStream in = socket.getInputStream();
      socket.setSoTimeout(100);
      byte[] buffer = new byte[8192];
      for (; ; ) {
        try {
          out.write("220-still here\r\n".getBytes(StandardCharsets.US_ASCII));
          out.flush();
        } catch (IOException e) {
          break;
        }
        try {
          int n = in.read(buffer);
          if (n < 0) {
            break;
          }
          received.write(buffer, 0, n);
        } catch (SocketTimeoutException e) {
          // Nothing from the client this time.
        } catch (IOException e) {
          break;
        }
      }
      return Json.object("received", received.toString(StandardCharsets.UTF_8), "closed", true);
    }

    private static Map<String, Object> relay(Socket plain, SSLContext starttls) throws IOException {
      Socket socket = plain;
      ByteArrayOutputStream received = new ByteArrayOutputStream();
      OutputStream out = socket.getOutputStream();
      InputStream in = socket.getInputStream();
      try {
        out.write("220 test ESMTP\r\n".getBytes(StandardCharsets.US_ASCII));
      } catch (IOException e) {
        // A TLS client that does not trust the certificate hangs up in the handshake.
        return Json.object("received", "", "closed", true);
      }
      StringBuilder buffer = new StringBuilder();
      boolean inData = false;
      boolean open = true;
      byte[] chunk = new byte[8192];
      while (open) {
        int n;
        try {
          n = in.read(chunk);
        } catch (IOException e) {
          break;
        }
        if (n < 0) {
          break;
        }
        received.write(chunk, 0, n);
        buffer.append(new String(chunk, 0, n, StandardCharsets.ISO_8859_1));
        int at;
        while ((at = buffer.indexOf("\r\n")) >= 0) {
          String line = buffer.substring(0, at);
          buffer.delete(0, at + 2);
          String reply = null;
          if (inData) {
            if (line.equals(".")) {
              inData = false;
              reply = "250 queued\r\n";
            }
          } else if (line.startsWith("EHLO")) {
            reply =
                starttls != null && !(socket instanceof SSLSocket)
                    ? "250-test\r\n250-STARTTLS\r\n250 AUTH PLAIN\r\n"
                    : "250-test\r\n250-SIZE 1000\r\n250 AUTH PLAIN\r\n";
          } else if (line.equals("STARTTLS") && starttls != null) {
            out.write("220 go ahead\r\n".getBytes(StandardCharsets.US_ASCII));
            out.flush();
            SSLSocket secured =
                (SSLSocket)
                    starttls
                        .getSocketFactory()
                        .createSocket(socket, "127.0.0.1", socket.getPort(), true);
            secured.setUseClientMode(false);
            try {
              secured.startHandshake();
            } catch (IOException e) {
              open = false;
              break;
            }
            socket = secured;
            in = socket.getInputStream();
            out = socket.getOutputStream();
            buffer.setLength(0);
            continue;
          } else if (line.startsWith("AUTH PLAIN")) {
            String got =
                new String(Base64.getDecoder().decode(line.substring(11)), StandardCharsets.UTF_8);
            reply = got.equals("\0jon\0pw") ? "235 ok\r\n" : "535 no\r\n";
          } else if (line.equals("DATA")) {
            inData = true;
            reply = "354 go\r\n";
          } else if (line.equals("QUIT")) {
            reply = "221 bye\r\n";
            open = false;
          } else {
            reply = "250 ok\r\n";
          }
          if (reply != null) {
            out.write(reply.getBytes(StandardCharsets.US_ASCII));
            out.flush();
          }
          if (!open) {
            break;
          }
        }
      }
      if (!open) {
        // Whatever the client still sends before it hangs up.
        socket.setSoTimeout(1000);
        try {
          for (int n = in.read(chunk); n >= 0; n = in.read(chunk)) {
            received.write(chunk, 0, n);
          }
        } catch (IOException e) {
          // Timed out or closed.
        }
      }
      return Json.object("received", received.toString(StandardCharsets.UTF_8));
    }

    @Override
    public void close() throws IOException {
      server.close();
    }
  }
}
