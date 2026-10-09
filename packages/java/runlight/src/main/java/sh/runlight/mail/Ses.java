package sh.runlight.mail;

import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
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
import sh.runlight.http.Url;

/**
 * Amazon SES (API v2) with a hand-rolled Signature Version 4, so there is no AWS SDK to install.
 * https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html
 */
public final class Ses {
  private Ses() {}

  private static final DateTimeFormatter AMZ_DATE =
      DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss'Z'").withZone(ZoneOffset.UTC);
  private static final Pattern SPACES = Pattern.compile("[" + Js.SPACE + "]+");
  private static final Pattern REGION = Pattern.compile("^[a-z]{2}(-[a-z]+)+-\\d\\z");

  private static byte[] hmac(byte[] key, String text) {
    return Hash.hmacBytes(key, Js.utf8(text));
  }

  /**
   * Signs a request; public for its test against AWS's published example.
   *
   * @param input {@code method}, {@code url} (a String or {@link Url}), {@code body}, {@code
   *     region}, {@code service}, {@code accessKeyId}, {@code secretAccessKey}, {@code now} (in
   *     milliseconds), and {@code headers} (a map of names to values)
   * @return the headers to send: the input's, then host, x-amz-date, and authorization
   */
  public static Map<String, Object> signV4(Map<String, Object> input) {
    Url url = input.get("url") instanceof Url u ? u : new Url((String) input.get("url"));
    String amzDate = AMZ_DATE.format(Instant.ofEpochMilli(Js.asLong(input.get("now"))));
    String day = amzDate.substring(0, 8);
    String payloadHash = Hash.sha256((String) input.get("body"));
    Map<String, Object> headers = new LinkedHashMap<>();
    Map<String, Object> given = Js.map(input.get("headers"));
    if (given != null) {
      headers.putAll(given);
    }
    headers.put("host", url.host());
    headers.put("x-amz-date", amzDate);
    List<String> names = new ArrayList<>();
    Map<String, String> lower = new LinkedHashMap<>();
    for (Map.Entry<String, Object> entry : headers.entrySet()) {
      names.add(Js.lower(entry.getKey()));
      lower.put(
          Js.lower(entry.getKey()),
          SPACES.matcher(Js.trim(Js.string(entry.getValue()))).replaceAll(" "));
    }
    names.sort(null);
    List<String> segments = new ArrayList<>();
    for (String part : url.pathname.split("/", -1)) {
      String decoded = Js.decodeURIComponent(part);
      if (decoded == null) {
        throw new IllegalArgumentException("URI malformed");
      }
      segments.add(Js.encodeURIComponent(decoded));
    }
    String path = String.join("/", segments);
    List<Map.Entry<String, String>> pairs = new ArrayList<>(url.searchParams().entries());
    // A stable sort on the name alone, as Array.prototype.sort is.
    pairs.sort((a, b) -> a.getKey().compareTo(b.getKey()));
    List<String> query = new ArrayList<>();
    for (Map.Entry<String, String> pair : pairs) {
      query.add(
          Js.encodeURIComponent(pair.getKey()) + "=" + Js.encodeURIComponent(pair.getValue()));
    }
    StringBuilder canonicalHeaders = new StringBuilder();
    for (String name : names) {
      canonicalHeaders.append(name).append(':').append(lower.get(name)).append('\n');
    }
    String signed = String.join(";", names);
    String canonical =
        String.join(
            "\n",
            (String) input.get("method"),
            path.isEmpty() ? "/" : path,
            String.join("&", query),
            canonicalHeaders,
            signed,
            payloadHash);
    String scope = day + "/" + input.get("region") + "/" + input.get("service") + "/aws4_request";
    String toSign = String.join("\n", "AWS4-HMAC-SHA256", amzDate, scope, Hash.sha256(canonical));
    byte[] key = hmac(Js.utf8("AWS4" + input.get("secretAccessKey")), day);
    key = hmac(key, (String) input.get("region"));
    key = hmac(key, (String) input.get("service"));
    key = hmac(key, "aws4_request");
    String signature = HexFormat.of().formatHex(hmac(key, toSign));
    Map<String, Object> out = new LinkedHashMap<>(headers);
    out.put(
        "authorization",
        "AWS4-HMAC-SHA256 Credential="
            + input.get("accessKeyId")
            + "/"
            + scope
            + ", SignedHeaders="
            + signed
            + ", Signature="
            + signature);
    return out;
  }

  /**
   * Sends one message through SES.
   *
   * @param fetcher what sends the request; null for a {@link JdkFetcher}
   * @param now milliseconds, for the signature; null for the clock
   */
  public static void send(
      Map<String, Object> config, Map<String, Object> m, String from, Fetcher fetcher, Long now) {
    String region = Js.trim(Js.string(config.get("region")));
    if (!REGION.matcher(region).matches()) {
      throw new MailError(
          "That is not an AWS region, like us-east-1", "mail_region", Json.object());
    }
    Url url = new Url("https://email." + region + ".amazonaws.com/v2/email/outbound-emails");
    List<Object> headerList = new ArrayList<>();
    Map<String, Object> extra = Js.map(m.get("headers"));
    if (extra != null) {
      for (Map.Entry<String, Object> entry : extra.entrySet()) {
        headerList.add(Json.object("Name", entry.getKey(), "Value", entry.getValue()));
      }
    }
    String body =
        Json.stringify(
            Json.object(
                "FromEmailAddress",
                from,
                "Destination",
                Json.object("ToAddresses", Json.array(m.get("to"))),
                "Content",
                Json.object(
                    "Simple",
                    Json.object(
                        "Subject",
                        Json.object("Data", m.get("subject"), "Charset", "UTF-8"),
                        "Body",
                        Json.object(
                            "Html",
                            Json.object("Data", m.get("html"), "Charset", "UTF-8"),
                            "Text",
                            Json.object("Data", m.get("text"), "Charset", "UTF-8")),
                        "Headers",
                        headerList))));
    Map<String, Object> headers =
        signV4(
            Json.object(
                "method",
                "POST",
                "url",
                url,
                "body",
                body,
                "region",
                region,
                "service",
                "ses",
                "accessKeyId",
                Js.trim(Js.string(config.get("accessKeyId"))),
                "secretAccessKey",
                Js.trim(Js.string(config.get("secretAccessKey"))),
                "now",
                now != null ? now : System.currentTimeMillis(),
                "headers",
                Json.object("content-type", "application/json")));
    headers.remove("host");
    Headers sent = new Headers();
    for (Map.Entry<String, Object> entry : headers.entrySet()) {
      sent.set(entry.getKey(), Js.string(entry.getValue()));
    }
    Response response;
    try {
      response =
          (fetcher != null ? fetcher : new JdkFetcher())
              .fetch(
                  url.href(),
                  new FetchInit().method("POST").headers(sent).body(body).timeoutMs(20_000));
    } catch (FetchError error) {
      throw new MailError(
          "Could not reach Amazon SES: " + error.getMessage(),
          "mail_unreachable",
          Json.object("host", "Amazon SES", "detail", error.getMessage()));
    }
    if (!response.ok()) {
      String message = Transports.serviceMessage(response.text());
      throw new MailError(
          "Amazon SES answered " + response.status() + (message.isEmpty() ? "" : ": " + message),
          "mail_refused",
          Json.object(
              "host",
              "Amazon SES",
              "detail",
              response.status() + (message.isEmpty() ? "" : " " + message)));
    }
  }
}
