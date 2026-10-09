package sh.runlight.core;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static sh.runlight.core.Harness.utc;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.function.Executable;
import sh.runlight.Fixtures;
import sh.runlight.Hash;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.RecordingFetcher;
import sh.runlight.Reports;
import sh.runlight.Runlight;
import sh.runlight.http.Response;
import sh.runlight.mail.MailError;
import sh.runlight.store.SqlStore;
import sh.runlight.store.Stores;

/**
 * The mail service's settings and the reports sent through it, as mail.test.ts and audit.test.ts
 * test them without routes.
 */
class ReportMailTest {
  private int status = 200;
  private final RecordingFetcher fetcher =
      new RecordingFetcher((url, init) -> new Response(status == 200 ? "{}" : "nope", status));

  private Runlight runlight(AtomicLong now, Runlight.Options options) {
    return new Runlight(options.store(Stores.sqlite(":memory:")).now(now::get).fetcher(fetcher));
  }

  private static Runlight.Options example(String timezone) {
    return new Runlight.Options()
        .site(
            Json.object(
                "name", "Example", "hostnames", List.of("example.com"), "timezone", timezone));
  }

  /** A report as the routes add one: a period already due counts as sent. */
  private static void addReport(Runlight rl, String email, String frequency, String lang) {
    Map<String, Object> site = rl.site("default");
    Map<String, Object> due =
        Reports.lastPeriod(frequency, rl.now(), (String) site.get("timezone"));
    Map<String, Object> r = new LinkedHashMap<>();
    r.put("id", Hash.randomId());
    r.put("site", "default");
    r.put("email", email);
    r.put("frequency", frequency);
    r.put("lang", lang);
    r.put("token", Hash.randomId(16));
    r.put("origin", "https://stats.example.com/runlight");
    r.put("lastPeriod", rl.now() >= Js.asLong(due.get("dueAt")) ? due.get("key") : "");
    r.put("lastSentAt", null);
    r.put("createdAt", rl.now());
    rl.store.insertReport(r);
  }

  private static MailError mailError(Executable fn) {
    return assertThrows(MailError.class, fn);
  }

  private static Map<String, Object> counts(long sent, long failed) {
    return Json.object("sent", sent, "failed", failed);
  }

  private Map<String, Object> body(int index) {
    return Js.map(Json.parse((String) fetcher.requests.get(index).get("body")));
  }

  @Test
  void reportsGoOutOncePerPeriodRetryAfterAFailureAndKeepKeysFromTheBrowser() {
    AtomicLong now = new AtomicLong(utc(2026, 10, 8, 15));
    Runlight rl = runlight(now, example("America/Toronto").secret("s3cret"));
    rl.init();

    MailError badFrom =
        mailError(
            () ->
                rl.saveMailSettings(
                    Json.object(
                        "service", "resend", "apiKey", "re_live_key", "from", "not an address")));
    assertEquals("mail_from", badFrom.code(), "a code the dashboard says in its own language");
    Fixtures.assertJson(Map.of(), badFrom.params());
    MailError noKey =
        mailError(
            () ->
                rl.saveMailSettings(
                    Json.object("service", "resend", "apiKey", "", "from", "reports@example.com")));
    assertEquals("mail_field", noKey.code());
    Fixtures.assertJson(Json.object("field", "apiKey"), noKey.params());
    assertEquals(
        "mail_service",
        mailError(() -> rl.saveMailSettings(Json.object("service", "pigeon"))).code());
    rl.saveMailSettings(
        Json.object(
            "service",
            "resend",
            "apiKey",
            "re_live_key",
            "from",
            "reports@example.com",
            "fromName",
            "Runlight"));
    String stored = rl.store.setting("mail");
    assertTrue(stored.startsWith("v1:"));
    assertFalse(stored.contains("re_live_key"), "the key is encrypted at rest");
    Fixtures.assertJson(
        Json.object(
            "service",
            "resend",
            "apiKey",
            "re_live_key",
            "from",
            "reports@example.com",
            "fromName",
            "Runlight",
            "source",
            "dashboard"),
        rl.mailSettings());
    // Saving again with the key left blank keeps it.
    rl.saveMailSettings(
        Json.object("service", "resend", "apiKey", "", "from", "reports@example.com"));
    assertEquals("re_live_key", rl.mailSettings().get("apiKey"));

    addReport(rl, "jon@example.com", "weekly", "fr");
    Fixtures.assertJson(
        counts(0, 0), rl.sendReports(), "a report added on a Wednesday waits for the next Monday");
    assertEquals(0, fetcher.requests.size());
    now.addAndGet(7 * 86_400_000L);
    status = 500;
    Fixtures.assertJson(counts(0, 1), rl.sendReports());
    status = 200;
    fetcher.requests.clear();
    Fixtures.assertJson(counts(1, 0), rl.sendReports(), "a failed send is tried again");
    Map<String, Object> body = body(0);
    assertEquals("https://api.resend.com/emails", fetcher.requests.get(0).get("url"));
    assertEquals("jon@example.com", Js.list(body.get("to")).get(0));
    assertEquals("Example : 0 personne la semaine dernière", body.get("subject"));
    String html = (String) body.get("html");
    assertTrue(html.contains("du 5 oct. au 11 oct. 2026"), html);
    assertTrue(
        html.contains("0 personne a visité le site la semaine dernière."),
        "French counts zero as one");
    Map<String, Object> headers = Js.map(body.get("headers"));
    assertTrue(
        ((String) headers.get("List-Unsubscribe"))
            .matches("^<https://stats\\.example\\.com/runlight/unsubscribe/[a-f0-9]{32}>\\z"));
    assertEquals("List-Unsubscribe=One-Click", headers.get("List-Unsubscribe-Post"));
    assertTrue(
        ((String) body.get("text")).contains("https://stats.example.com/runlight/?site=default"));
    Fixtures.assertJson(counts(0, 0), rl.sendReports(), "the same period never goes twice");
    now.addAndGet(7 * 86_400_000L);
    Fixtures.assertJson(counts(1, 0), rl.sendReports(), "the next week does");
    Fixtures.assertJson(Json.object("ok", true, "reports", counts(0, 0)), rl.check());
  }

  @Test
  void aReportAddedBeforeMondays8amStillGetsLastWeeks() {
    // Monday 5 October 2026, 7:00 in Toronto: last week is over and not yet due.
    AtomicLong now = new AtomicLong(utc(2026, 10, 5, 11));
    Runlight rl = runlight(now, example("America/Toronto"));
    rl.saveMailSettings(
        Json.object("service", "resend", "apiKey", "re_1", "from", "reports@example.com"));
    addReport(rl, "jon@example.com", "weekly", "en");
    addReport(rl, "jon@example.com", "monthly", "en");
    Fixtures.assertJson(counts(0, 0), rl.sendReports());
    now.addAndGet(2 * 3_600_000L);
    Fixtures.assertJson(counts(1, 0), rl.sendReports());
    assertTrue(((String) body(0).get("subject")).contains("last week"));
  }

  @Test
  void noMailServiceSendsNothingAndSayingSoIsAnError() {
    AtomicLong now = new AtomicLong(utc(2026, 10, 12, 15));
    Runlight rl = runlight(now, new Runlight.Options());
    rl.init();
    addReport(rl, "jon@example.com", "weekly", "en");
    rl.store.db().run("UPDATE rl_reports SET last_period = ''");
    Fixtures.assertJson(counts(0, 0), rl.sendReports());
    assertEquals(
        "mail_unset",
        mailError(
                () ->
                    rl.sendMail(
                        Json.object("to", "a@b.co", "subject", "s", "html", "h", "text", "t")))
            .code());
  }

  @Test
  void aMailServiceInCodeIsShownAndCannotBeChanged() {
    AtomicLong now = new AtomicLong(0);
    Runlight rl =
        runlight(
            now,
            new Runlight.Options()
                .mail(
                    Json.object(
                        "service", "resend", "apiKey", "re_code", "from", "r@example.com")));
    Fixtures.assertJson(
        Json.object(
            "service", "resend", "apiKey", "re_code", "from", "r@example.com", "source", "code"),
        rl.mailSettings());
    assertEquals("mail_in_code", mailError(() -> rl.saveMailSettings(null)).code());
    rl.sendMail(
        Json.object("to", "jon@example.com", "subject", "Hi", "html", "<p>Hi</p>", "text", "Hi"));
    assertEquals("r@example.com", body(0).get("from"));
  }

  @Test
  void aSavedSmtpPasswordIsKeptOnlyWhileTheServerItGoesToStaysTheSame() {
    AtomicLong now = new AtomicLong(0);
    Runlight rl = runlight(now, new Runlight.Options().secret("k".repeat(32)));
    rl.saveMailSettings(smtp("smtp.example.com", "hunter2-long", "r@example.com"));
    rl.saveMailSettings(smtp("smtp.example.com", "", "reports@example.com"));
    assertEquals(
        "hunter2-long", rl.mailSettings().get("password"), "same server, blank field: kept");
    rl.saveMailSettings(smtp("evil.example", "", "reports@example.com"));
    Object password = rl.mailSettings().get("password");
    assertEquals("", password == null ? "" : password, "a new host needs the password typed again");
    rl.saveMailSettings(null);
    assertNull(rl.mailSettings());
  }

  private static Map<String, Object> smtp(String host, String password, String from) {
    return Json.object(
        "service",
        "smtp",
        "host",
        host,
        "port",
        "587",
        "security",
        "starttls",
        "username",
        "me",
        "from",
        from,
        "password",
        password);
  }

  @Test
  void aKeySealedWithAnotherSecretReadsAsNoMailService() {
    SqlStore store = Stores.sqlite(":memory:");
    Runlight one = new Runlight(new Runlight.Options().store(store).secret("one"));
    one.saveMailSettings(
        Json.object("service", "resend", "apiKey", "re_1", "from", "r@example.com"));
    Runlight two = new Runlight(new Runlight.Options().store(store).secret("two"));
    assertNull(two.mailSettings());
  }
}
