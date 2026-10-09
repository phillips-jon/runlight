package sh.runlight.mail;

import java.util.ArrayList;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import sh.runlight.Hash;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.http.FetchError;
import sh.runlight.http.FetchInit;
import sh.runlight.http.Fetcher;
import sh.runlight.http.Headers;
import sh.runlight.http.JdkFetcher;
import sh.runlight.http.Response;
import sh.runlight.http.SearchParams;
import sh.runlight.http.Url;

/**
 * Sends mail through the service a site picked. A message is a map shaped as TS's Message: {@code
 * to}, {@code from}, {@code fromName} (optional), {@code subject}, {@code html}, {@code text}, and
 * {@code headers} (optional extra headers, such as List-Unsubscribe, a map of names to values). A
 * config is {@code service} plus its fields, every value a string, as typed in the dashboard.
 */
public final class Transports {
  private Transports() {}

  /** Every service Runlight can send through, and what each needs. */
  public static final List<Map<String, Object>> SERVICES =
      List.of(
          service(
              "ses",
              "Amazon SES",
              field("region", "Region", "placeholder", "us-east-1"),
              field("accessKeyId", "Access key ID"),
              field("secretAccessKey", "Secret access key", "secret", true)),
          service(
              "resend",
              "Resend",
              field("apiKey", "API key", "secret", true, "placeholder", "re_...")),
          service(
              "postmark",
              "Postmark",
              field("serverToken", "Server API token", "secret", true),
              field("stream", "Message stream", "optional", true, "placeholder", "outbound")),
          service(
              "sendgrid",
              "SendGrid",
              field("apiKey", "API key", "secret", true, "placeholder", "SG....")),
          service(
              "mailgun",
              "Mailgun",
              field("domain", "Sending domain", "placeholder", "mg.example.com"),
              field("apiKey", "API key", "secret", true),
              field("region", "Region", "options", List.of("us", "eu"))),
          service(
              "brevo",
              "Brevo",
              field("apiKey", "API key", "secret", true, "placeholder", "xkeysib-...")),
          service(
              "mailjet",
              "Mailjet",
              field("apiKey", "API key"),
              field("secretKey", "Secret key", "secret", true)),
          service(
              "mailersend",
              "MailerSend",
              field("apiKey", "API token", "secret", true, "placeholder", "mlsn....")),
          service(
              "sparkpost",
              "SparkPost",
              field("apiKey", "API key", "secret", true),
              field("region", "Region", "options", List.of("us", "eu"))),
          service(
              "smtp",
              "SMTP",
              field("host", "Host", "placeholder", "smtp.example.com"),
              field("port", "Port", "placeholder", "587"),
              field("security", "Security", "options", List.of("starttls", "tls", "none")),
              field("username", "Username", "optional", true),
              field("password", "Password", "secret", true, "optional", true)),
          service(
              "webhook",
              "Webhook",
              field("url", "URL", "placeholder", "https://example.com/hooks/mail"),
              field("secret", "Signing secret", "secret", true, "optional", true)));

  private static Map<String, Object> service(String id, String name, Map<?, ?>... fields) {
    return java.util.Collections.unmodifiableMap(
        Json.object("id", id, "name", name, "fields", List.of(fields)));
  }

  private static Map<String, Object> field(String name, String label, Object... rest) {
    Map<String, Object> field = Json.object("name", name, "label", label);
    field.putAll(Json.object(rest));
    return java.util.Collections.unmodifiableMap(field);
  }

  /** A config or message field as a string, or null when it is not set. */
  static String value(Map<String, Object> map, String name) {
    Object value = map == null ? null : map.get(name);
    return value == null || value == Json.UNDEFINED ? null : Js.string(value);
  }

  private static boolean truthy(String value) {
    return value != null && !value.isEmpty();
  }

  /** The From address, with the name when there is one. */
  public static String address(Map<String, Object> m) {
    String name = value(m, "fromName");
    return truthy(name)
        ? name.replaceAll("[\"\\\\\r\n]", "") + " <" + value(m, "from") + ">"
        : value(m, "from");
  }

  private static final Pattern XML_MESSAGE = Pattern.compile("<Message>([^<]{1,200})</Message>");

  /**
   * The error a mail service explains itself with, from its JSON or XML reply, and never the raw
   * body: a reply is shown to the dashboard, so an address that is not a mail service must not be
   * able to put its page there.
   */
  public static String serviceMessage(String reply) {
    Json.Parsed parsed = Json.tryParse(reply);
    // JSON.parse fails, or reading a field of null does, and either way the XML form is tried.
    if (!parsed.ok() || parsed.value() == null) {
      Matcher m = XML_MESSAGE.matcher(reply);
      return m.find() ? Js.trim(m.group(1)) : "";
    }
    Map<String, Object> object = Js.map(parsed.value());
    for (String name : List.of("message", "Message", "error", "errors", "ErrorMessage")) {
      String text = first(object == null ? null : object.get(name));
      if (!text.isEmpty()) {
        return Js.slice(text, 0, 200);
      }
    }
    return "";
  }

  private static String first(Object v) {
    if (v instanceof String s) {
      return s;
    }
    if (v instanceof List<?> list) {
      return first(list.isEmpty() ? null : list.get(0));
    }
    if (v instanceof Map<?, ?> map) {
      return first(map.get("message"));
    }
    return "";
  }

  /** POSTs to a service, with the errors the dashboard shows. */
  private static void post(
      Fetcher fetcher, String url, Map<String, String> headers, String body, boolean explains) {
    Response response;
    try {
      response =
          fetcher.fetch(
              url,
              new FetchInit()
                  .method("POST")
                  .headers(Headers.of(headers))
                  .body(body)
                  .timeoutMs(20_000));
    } catch (FetchError error) {
      String host = new Url(url).host();
      throw new MailError(
          "Could not reach " + host + ": " + error.getMessage(),
          "mail_unreachable",
          Json.object("host", host, "detail", error.getMessage()));
    }
    if (response.ok()) {
      return;
    }
    String message = explains ? serviceMessage(response.text()) : "";
    String host = new Url(url).host();
    throw new MailError(
        host + " answered " + response.status() + (message.isEmpty() ? "" : ": " + message),
        "mail_refused",
        Json.object(
            "host", host, "detail", response.status() + (message.isEmpty() ? "" : " " + message)));
  }

  private static Map<String, String> json(String... pairs) {
    Map<String, String> headers = new LinkedHashMap<>();
    headers.put("content-type", "application/json");
    for (int i = 0; i + 1 < pairs.length; i += 2) {
      headers.put(pairs[i], pairs[i + 1]);
    }
    return headers;
  }

  /** Basic auth over the UTF-8 bytes, so a key with any character is sent. */
  private static String basic(String user, String pass) {
    return "Basic " + Base64.getEncoder().encodeToString(Js.utf8(user + ":" + pass));
  }

  private static final Pattern WEBHOOK_HTTPS = Pattern.compile("^https://");
  private static final Pattern WEBHOOK_LOCAL =
      Pattern.compile("^http://(localhost|127\\.0\\.0\\.1)(:\\d+)?(/|\\z)");

  /** Checks a config has what its service needs, before anything is saved or sent. */
  public static void checkConfig(Map<String, Object> config) {
    Map<String, Object> service = null;
    for (Map<String, Object> s : SERVICES) {
      if (s.get("id").equals(value(config, "service"))) {
        service = s;
      }
    }
    if (service == null) {
      throw new MailError("Pick a mail service", "mail_service", Json.object());
    }
    for (Object item : Js.list(service.get("fields"))) {
      Map<String, Object> f = Js.map(item);
      String name = (String) f.get("name");
      String label = (String) f.get("label");
      String value = value(config, name);
      if (!Boolean.TRUE.equals(f.get("optional")) && (value == null || Js.trim(value).isEmpty())) {
        throw new MailError(
            "Enter the " + Js.lower(label), "mail_field", Json.object("field", name));
      }
      List<Object> options = Js.list(f.get("options"));
      if (options != null && truthy(value) && !options.contains(value)) {
        String joined = String.join(", ", Js.strings(options));
        throw new MailError(
            label + " must be one of " + joined,
            "mail_option",
            Json.object("field", name, "options", joined));
      }
    }
    String url = value(config, "url");
    url = url == null ? "" : url;
    if ("webhook".equals(value(config, "service"))
        && !WEBHOOK_HTTPS.matcher(url).find()
        && !WEBHOOK_LOCAL.matcher(url).find()) {
      throw new MailError("The webhook URL must use https", "mail_https", Json.object());
    }
    if ("webhook".equals(value(config, "service")) && !Url.canParse(url)) {
      throw new MailError(
          "Enter the webhook's whole URL, like https://example.com/hooks/mail",
          "mail_url",
          Json.object());
    }
    // A port a socket can connect to, read with Number() as the SMTP client reads it.
    Object given = config.get("port");
    double port = Js.toNumber(given == null ? Json.UNDEFINED : given);
    if ("smtp".equals(value(config, "service"))
        && !(port == Math.floor(port) && port >= 1 && port <= 65535)) {
      throw new MailError(
          "The port must be a whole number from 1 to 65535", "mail_port", Json.object());
    }
  }

  /** Sends one message through the configured service, on the wall clock. */
  public static void send(Map<String, Object> config, Map<String, Object> m, Fetcher fetcher) {
    send(config, m, fetcher, null);
  }

  /**
   * Sends one message through the configured service.
   *
   * @param fetcher what sends each request; null for a {@link JdkFetcher}
   * @param now milliseconds, for SES's signature and the SMTP message's date; null for the clock
   */
  public static void send(
      Map<String, Object> config, Map<String, Object> m, Fetcher fetcher, Long now) {
    checkConfig(config);
    if (fetcher == null) {
      fetcher = new JdkFetcher();
    }
    Map<String, Object> headers = Js.map(m.get("headers"));
    if (headers == null) {
      headers = new LinkedHashMap<>();
    }
    boolean hasName = truthy(value(m, "fromName"));
    String service = value(config, "service");
    switch (service) {
      case "resend" -> {
        post(
            fetcher,
            "https://api.resend.com/emails",
            json("authorization", "Bearer " + value(config, "apiKey")),
            Json.stringify(
                Json.object(
                    "from", address(m),
                    "to", Json.array(m.get("to")),
                    "subject", m.get("subject"),
                    "html", m.get("html"),
                    "text", m.get("text"),
                    "headers", headers)),
            true);
        return;
      }
      case "postmark" -> {
        List<Object> list = new ArrayList<>();
        for (Map.Entry<String, Object> entry : headers.entrySet()) {
          list.add(Json.object("Name", entry.getKey(), "Value", entry.getValue()));
        }
        String stream = value(config, "stream");
        post(
            fetcher,
            "https://api.postmarkapp.com/email",
            json(
                "accept",
                "application/json",
                "x-postmark-server-token",
                value(config, "serverToken")),
            Json.stringify(
                Json.object(
                    "From", address(m),
                    "To", m.get("to"),
                    "Subject", m.get("subject"),
                    "HtmlBody", m.get("html"),
                    "TextBody", m.get("text"),
                    "MessageStream", truthy(stream) ? stream : "outbound",
                    "Headers", list)),
            true);
        return;
      }
      case "sendgrid" -> {
        post(
            fetcher,
            "https://api.sendgrid.com/v3/mail/send",
            json("authorization", "Bearer " + value(config, "apiKey")),
            Json.stringify(
                Json.object(
                    "personalizations",
                    Json.array(Json.object("to", Json.array(Json.object("email", m.get("to"))))),
                    "from",
                    named("email", m.get("from"), "name", m, hasName),
                    "subject",
                    m.get("subject"),
                    "content",
                    Json.array(
                        Json.object("type", "text/plain", "value", m.get("text")),
                        Json.object("type", "text/html", "value", m.get("html"))),
                    "headers",
                    headers)),
            true);
        return;
      }
      case "mailgun" -> {
        Map<String, String> fields = new LinkedHashMap<>();
        fields.put("from", address(m));
        fields.put("to", value(m, "to"));
        fields.put("subject", value(m, "subject"));
        fields.put("html", value(m, "html"));
        fields.put("text", value(m, "text"));
        SearchParams form = new SearchParams(fields);
        for (Map.Entry<String, Object> entry : headers.entrySet()) {
          form.set("h:" + entry.getKey(), Js.string(entry.getValue()));
        }
        String host =
            "eu".equals(value(config, "region")) ? "api.eu.mailgun.net" : "api.mailgun.net";
        Map<String, String> sent = new LinkedHashMap<>();
        sent.put("authorization", basic("api", value(config, "apiKey")));
        sent.put("content-type", "application/x-www-form-urlencoded");
        post(
            fetcher,
            "https://"
                + host
                + "/v3/"
                + Js.encodeURIComponent(value(config, "domain"))
                + "/messages",
            sent,
            form.toString(),
            true);
        return;
      }
      case "brevo" -> {
        post(
            fetcher,
            "https://api.brevo.com/v3/smtp/email",
            json("api-key", value(config, "apiKey"), "accept", "application/json"),
            Json.stringify(
                Json.object(
                    "sender", named("email", m.get("from"), "name", m, hasName),
                    "to", Json.array(Json.object("email", m.get("to"))),
                    "subject", m.get("subject"),
                    "htmlContent", m.get("html"),
                    "textContent", m.get("text"),
                    "headers", headers)),
            true);
        return;
      }
      case "mailjet" -> {
        post(
            fetcher,
            "https://api.mailjet.com/v3.1/send",
            json("authorization", basic(value(config, "apiKey"), value(config, "secretKey"))),
            Json.stringify(
                Json.object(
                    "Messages",
                    Json.array(
                        Json.object(
                            "From", named("Email", m.get("from"), "Name", m, hasName),
                            "To", Json.array(Json.object("Email", m.get("to"))),
                            "Subject", m.get("subject"),
                            "TextPart", m.get("text"),
                            "HTMLPart", m.get("html"),
                            "Headers", headers)))),
            true);
        return;
      }
      case "mailersend" -> {
        List<Object> list = new ArrayList<>();
        for (Map.Entry<String, Object> entry : headers.entrySet()) {
          list.add(Json.object("name", entry.getKey(), "value", entry.getValue()));
        }
        Map<String, Object> body =
            Json.object(
                "from", named("email", m.get("from"), "name", m, hasName),
                "to", Json.array(Json.object("email", m.get("to"))),
                "subject", m.get("subject"),
                "html", m.get("html"),
                "text", m.get("text"));
        if (!list.isEmpty()) {
          body.put("headers", list);
        }
        post(
            fetcher,
            "https://api.mailersend.com/v1/email",
            json("authorization", "Bearer " + value(config, "apiKey")),
            Json.stringify(body),
            true);
        return;
      }
      case "sparkpost" -> {
        post(
            fetcher,
            "https://"
                + ("eu".equals(value(config, "region"))
                    ? "api.eu.sparkpost.com"
                    : "api.sparkpost.com")
                + "/api/v1/transmissions",
            json("authorization", value(config, "apiKey")),
            Json.stringify(
                Json.object(
                    "recipients",
                    Json.array(Json.object("address", Json.object("email", m.get("to")))),
                    "content",
                    Json.object(
                        "from",
                        hasName
                            ? Json.object("email", m.get("from"), "name", m.get("fromName"))
                            : m.get("from"),
                        "subject",
                        m.get("subject"),
                        "html",
                        m.get("html"),
                        "text",
                        m.get("text"),
                        "headers",
                        headers))),
            true);
        return;
      }
      case "ses" -> {
        Ses.send(config, m, address(m), fetcher, now);
        return;
      }
      case "smtp" -> {
        Smtp.send(config, m, address(m), 60_000, now, null);
        return;
      }
      case "webhook" -> {
        String fromName = value(m, "fromName");
        String body =
            Json.stringify(
                Json.object(
                    "to", m.get("to"),
                    "from", m.get("from"),
                    "fromName", fromName == null ? "" : fromName,
                    "subject", m.get("subject"),
                    "html", m.get("html"),
                    "text", m.get("text"),
                    "headers", headers));
        String secret = value(config, "secret");
        Map<String, String> sent =
            truthy(secret)
                ? json("x-runlight-signature", "sha256=" + Hash.hmac(secret, body))
                : json();
        // A webhook can be any address, so only its status comes back.
        post(fetcher, value(config, "url"), sent, body, false);
        return;
      }
      default -> {
        // Refused below, as an unknown service.
      }
    }
    throw new MailError("Unknown mail service \"" + service + "\"", "mail_service", Json.object());
  }

  /** {@code { [key]: from, ...(m.fromName ? { [nameKey]: m.fromName } : {}) }}. */
  private static Map<String, Object> named(
      String key, Object from, String nameKey, Map<String, Object> m, boolean hasName) {
    Map<String, Object> out = Json.object(key, from);
    if (hasName) {
      out.put(nameKey, m.get("fromName"));
    }
    return out;
  }
}
