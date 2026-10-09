package sh.runlight.conformance;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import sh.runlight.Env;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.Routes;
import sh.runlight.Runlight;
import sh.runlight.accounts.Crypto;
import sh.runlight.http.Headers;
import sh.runlight.http.Request;
import sh.runlight.http.Response;
import sh.runlight.http.SearchParams;
import sh.runlight.http.Url;
import sh.runlight.store.SqlStore;

/**
 * Plays a scenario from conformance/http.json exactly as play() in
 * packages/sdk/test/http-conformance.ts does, and returns each step's answer, normalized, in the
 * shape of the file's expect: status, headers, body, text, files, found, fetched, or pass.
 */
public final class Player {
  /** Environment the SDK reads defaults from, cleared while a scenario plays. */
  public static final List<String> ENV =
      List.of(
          "RUNLIGHT_TOKEN", "RUNLIGHT_SECRET", "CRON_SECRET", "RUNLIGHT_OBSERVE_KEY", "NODE_ENV");

  /** The content type JavaScript's Request gives a string body sent with none. */
  public static final String TEXT_BODY_TYPE = "text/plain;charset=UTF-8";

  private static final Pattern TOTP = Pattern.compile("\\{\\{totp:(\\w+)\\}\\}");
  private static final Pattern TEMPLATE = Pattern.compile("\\{\\{(\\w+)\\}\\}");
  private static final Pattern CLEARS =
      Pattern.compile(
          "^[" + Js.SPACE + "]*max-age=0[" + Js.SPACE + "]*\\z", Pattern.CASE_INSENSITIVE);

  /** The clock, in epoch milliseconds, as the scenario's steps move it. */
  private final AtomicLong now = new AtomicLong();

  /** The Runlight a scenario plays against, its routes, and its short-link handler. */
  private record Target(Runlight rl, Routes routes) {}

  /** Runs a scenario's steps on a store and returns each answer, normalized. */
  public List<Object> play(Map<String, Object> scenario, SqlStore store) {
    for (String name : ENV) {
      Env.override(name, null);
    }
    try {
      return steps(scenario, store, new UpstreamFetcher(scenario.get("upstream")));
    } finally {
      Env.reset();
    }
  }

  private static Map<String, Object> options(Map<String, Object> scenario) {
    Map<String, Object> options = Js.map(scenario.get("options"));
    return options != null ? options : Map.of();
  }

  @SuppressWarnings("unchecked")
  private Runlight.Options runlightOptions(
      Map<String, Object> scenario, SqlStore store, UpstreamFetcher fetcher) {
    Map<String, Object> options = options(scenario);
    Runlight.Options out = new Runlight.Options().store(store).now(now::get).fetcher(fetcher);
    if (Js.truthy(options.get("managedSites"))) {
      out.managedSites(true);
    } else if (scenario.get("sites") != null) {
      out.sites((List<Map<String, Object>>) scenario.get("sites"));
    } else {
      out.site(Js.map(scenario.get("site")));
    }
    if (options.get("secret") instanceof String secret && !secret.isEmpty()) {
      out.secret(secret);
    }
    if (options.containsKey("rateLimit")) {
      out.rateLimit(options.get("rateLimit"));
    }
    return out;
  }

  /**
   * The routes options. The token is always there: a string, "" for none, or null to leave the
   * routes open, never left out, which would read RUNLIGHT_TOKEN.
   */
  private static Routes.Options routesOptions(Map<String, Object> scenario) {
    Map<String, Object> options = options(scenario);
    Routes.Options out =
        new Routes.Options()
            .token((String) scenario.get("token"))
            .observeKey(Js.strOr(options.get("observeKey"), ""))
            .cronSecret(Js.strOr(options.get("cronSecret"), ""));
    if (Js.truthy(options.get("accounts"))) {
      out.accounts(true);
    }
    if (Js.truthy(options.get("origin"))) {
      out.origin((String) options.get("origin"));
    }
    return out;
  }

  private List<Object> steps(
      Map<String, Object> scenario, SqlStore store, UpstreamFetcher fetcher) {
    now.set(Js.asLong(scenario.get("start")));
    Runlight rl = new Runlight(runlightOptions(scenario, store, fetcher));
    Target target = new Target(rl, rl.routes(routesOptions(scenario)));
    Map<String, String> kept = new LinkedHashMap<>();
    Map<String, Map<String, String>> jars = new LinkedHashMap<>();
    List<Object> answers = new ArrayList<>();
    List<Object> steps = Js.list(scenario.get("steps"));
    for (int i = 0; i < steps.size(); i++) {
      Map<String, Object> step = Js.map(steps.get(i));
      try {
        answers.add(step(step, target, fetcher, kept, jars));
      } catch (RuntimeException error) {
        throw new IllegalStateException(
            scenario.get("name")
                + ": step "
                + (i + 1)
                + ", "
                + step.get("method")
                + " "
                + step.get("path")
                + ": "
                + error,
            error);
      }
    }
    return answers;
  }

  private Object step(
      Map<String, Object> step,
      Target target,
      UpstreamFetcher fetcher,
      Map<String, String> kept,
      Map<String, Map<String, String>> jars) {
    now.addAndGet(step.get("advance") == null ? 0 : Js.asLong(step.get("advance")));
    Map<String, String> headers = new LinkedHashMap<>();
    Map<String, Object> given = Js.map(step.get("headers"));
    if (given != null) {
      for (Map.Entry<String, Object> e : given.entrySet()) {
        headers.put(Js.lower(e.getKey()), fillTotp(Js.string(e.getValue()), kept));
      }
    }
    String body = null;
    if (step.get("form") != null) {
      Map<String, String> fields = new LinkedHashMap<>();
      for (Map.Entry<String, Object> e : Js.map(fillDeep(step.get("form"), kept)).entrySet()) {
        fields.put(e.getKey(), Js.string(e.getValue()));
      }
      body = new SearchParams(fields).toString();
      headers.putIfAbsent("content-type", "application/x-www-form-urlencoded");
    } else if (step.containsKey("body")) {
      Object raw = step.get("body");
      body = raw instanceof String s ? fillTotp(s, kept) : Json.stringify(fillDeep(raw, kept));
    }
    // JavaScript's Request gives a string body this type when none is named.
    if (body != null) {
      headers.putIfAbsent("content-type", TEXT_BODY_TYPE);
    }
    Object jarName = step.containsKey("jar") ? step.get("jar") : "main";
    Map<String, String> jar = null;
    if (!Boolean.FALSE.equals(jarName)) {
      jar = jars.computeIfAbsent(Js.string(jarName), key -> new LinkedHashMap<>());
    }
    if (jar != null && !jar.isEmpty() && !headers.containsKey("cookie")) {
      List<String> pairs = new ArrayList<>();
      for (Map.Entry<String, String> e : jar.entrySet()) {
        pairs.add(e.getKey() + "=" + e.getValue());
      }
      headers.put("cookie", String.join("; ", pairs));
    }
    String to = step.get("to") instanceof String s ? s : "routes";
    String prefix = to.equals("routes") && !Js.truthy(step.get("absolute")) ? "/runlight" : "";
    String host = step.get("host") instanceof String h ? h : "example.com";
    String raw = "https://" + host + prefix + fillTotp(Js.string(step.get("path")), kept);
    // request.url is the parsed URL, as new Request(url) gives it.
    Url parsed = Url.parse(raw);
    String url = parsed != null ? parsed.href() : raw;
    Request request =
        new Request(
            url,
            Js.string(step.get("method")),
            Headers.of(headers),
            body == null ? new byte[0] : Js.utf8(body),
            "");
    fetcher.take();
    Response answer =
        switch (to) {
          case "links" -> target.rl().linkHandler().apply(request);
          case "linkDomain" -> target.rl().linkDomainResponse(request);
          default -> target.routes().handle(request);
        };
    // Work the request started after answering (retention) finishes before the next one.
    target.rl().idle();
    List<UpstreamFetcher.Sent> sentOut = fetcher.take();
    List<Object> outbound = new ArrayList<>();
    for (UpstreamFetcher.Sent sent : sentOut) {
      outbound.add(Normalizer.normalize(sent.seen()));
    }
    if (answer == null) {
      Map<String, Object> out = Json.object("pass", true);
      if (!outbound.isEmpty()) {
        out.put("fetched", outbound);
      }
      return out;
    }
    return answer(step, answer, sentOut, outbound, kept, jar);
  }

  private Object answer(
      Map<String, Object> step,
      Response answer,
      List<UpstreamFetcher.Sent> sentOut,
      List<Object> outbound,
      Map<String, String> kept,
      Map<String, String> jar) {
    byte[] bytes = answer.bytes();
    String text = Js.decodeUtf8(bytes);
    String contentType = answer.headers().get("content-type");
    String type = Js.trim((contentType == null ? "" : contentType).split(";", -1)[0]);
    Object parsed = null;
    boolean hasParsed = false;
    if (!type.equals("application/zip") && !text.isEmpty()) {
      Json.Parsed tried = Json.tryParse(text);
      if (tried.ok()) {
        parsed = tried.value();
        hasParsed = true;
      }
    }
    Map<String, Object> capture = Js.map(step.get("capture"));
    if (capture != null) {
      for (Map.Entry<String, Object> e : capture.entrySet()) {
        kept.put(
            e.getKey(),
            capture(Js.string(e.getValue()), answer, text, hasParsed ? parsed : null, sentOut));
      }
    }
    for (String cookie : answer.headers().getSetCookie()) {
      if (jar == null) {
        continue;
      }
      String[] attributes = cookie.split(";", -1);
      String pair = attributes[0];
      int at = pair.indexOf('=');
      // As pair.slice(0, pair.indexOf("=")): with no "=", indexOf is -1, and the last character is
      // cut.
      String name = Js.trim(at < 0 ? Js.slice(pair, 0, -1) : pair.substring(0, at));
      String value = Js.trim(at < 0 ? pair : pair.substring(at + 1));
      boolean clears = false;
      for (int i = 1; i < attributes.length; i++) {
        if (CLEARS.matcher(attributes[i]).find()) {
          clears = true;
        }
      }
      if (value.isEmpty() || clears) {
        jar.remove(name);
      } else {
        jar.put(name, value);
      }
    }
    Map<String, Object> sent = new LinkedHashMap<>();
    for (String name : Normalizer.HEADERS) {
      if (name.equals("set-cookie")) {
        List<String> cookies = answer.headers().getSetCookie();
        if (!cookies.isEmpty()) {
          List<Object> shaped = new ArrayList<>();
          for (String c : cookies) {
            shaped.add(Normalizer.cookieShape(c));
          }
          sent.put(name, shaped);
        }
        continue;
      }
      String value = answer.headers().get(name);
      if (value != null && !value.isEmpty()) {
        sent.put(
            name,
            name.equals("content-type")
                ? Js.trim(value.split(";", -1)[0])
                : Normalizer.normalize(value));
      }
    }
    Map<String, Object> out = new LinkedHashMap<>();
    out.put("status", (long) answer.status());
    if (!sent.isEmpty()) {
      out.put("headers", sent);
    }
    if (hasParsed) {
      out.put("body", Normalizer.normalize(parsed));
    }
    if (!hasParsed && (type.equals("text/plain") || type.equals("text/csv"))) {
      out.put("text", Normalizer.normalize(text));
    }
    if (type.equals("application/zip")) {
      List<Object> files = new ArrayList<>();
      for (Map<String, Object> f : Unzip.unzip(bytes)) {
        files.add(Json.object("name", f.get("name"), "text", Normalizer.normalize(f.get("text"))));
      }
      out.put("files", files);
    }
    if (step.get("look") instanceof List<?> look) {
      List<Object> found = new ArrayList<>();
      for (Object s : look) {
        found.add(text.contains(Js.string(s)));
      }
      out.put("found", found);
    }
    if (!outbound.isEmpty()) {
      out.put("fetched", outbound);
    }
    return out;
  }

  /**
   * A value kept from an answer: a dotted path into its JSON body, header:&lt;name&gt;, text, or
   * fetched, any of them followed by ~&lt;regex&gt; to keep the regex's first group instead.
   */
  static String capture(
      String spec,
      Response answer,
      String text,
      Object parsed,
      List<UpstreamFetcher.Sent> sentOut) {
    int cut = spec.indexOf('~');
    String source = cut < 0 ? spec : spec.substring(0, cut);
    String pattern = cut < 0 ? null : spec.substring(cut + 1);
    String value;
    if (source.equals("text")) {
      value = text;
    } else if (source.equals("fetched")) {
      List<String> bodies = new ArrayList<>();
      for (UpstreamFetcher.Sent s : sentOut) {
        bodies.add(s.text());
      }
      value = String.join("\n", bodies);
    } else if (source.startsWith("header:")) {
      String header = Js.lower(source.substring("header:".length()));
      String got = answer.headers().get(header);
      value =
          header.equals("set-cookie")
              ? String.join("\n", answer.headers().getSetCookie())
              : got != null ? got : "";
    } else {
      value = jsString(dig(parsed, source));
    }
    if (pattern == null) {
      return value;
    }
    Matcher m = Pattern.compile(pattern).matcher(value);
    return m.find() && m.groupCount() >= 1 && m.group(1) != null ? m.group(1) : "";
  }

  /** path.split(".").reduce((v, k) => (v && typeof v === "object" ? v[k] : undefined), value). */
  static Object dig(Object value, String path) {
    for (String k : path.split("\\.", -1)) {
      if (value instanceof Map<?, ?> || value instanceof List<?>) {
        Object next = Js.get(value, k);
        value = next == Json.UNDEFINED ? null : next;
      } else {
        return null;
      }
    }
    return value;
  }

  /** String(value ?? ""), as JavaScript writes a JSON value as text. */
  static String jsString(Object value) {
    return value == null ? "" : Js.string(value);
  }

  /** {{totp:name}} as the six-digit code for the captured secret at the step's clock. */
  private String fillTotp(String text, Map<String, String> kept) {
    String out = text;
    Matcher m = TOTP.matcher(text);
    while (m.find()) {
      int at = out.indexOf(m.group());
      if (at >= 0) {
        String secret = kept.getOrDefault(m.group(1), "");
        out =
            out.substring(0, at)
                + Crypto.totp(secret, Math.floorDiv(now.get(), 30_000L))
                + out.substring(at + m.group().length());
      }
    }
    return fill(out, kept);
  }

  /** {{name}} as the value captured earlier, empty when nothing was. */
  private static String fill(String text, Map<String, String> kept) {
    Matcher m = TEMPLATE.matcher(text);
    StringBuilder out = new StringBuilder();
    while (m.find()) {
      m.appendReplacement(out, Matcher.quoteReplacement(kept.getOrDefault(m.group(1), "")));
    }
    m.appendTail(out);
    return out.toString();
  }

  private Object fillDeep(Object value, Map<String, String> kept) {
    if (value instanceof String s) {
      return fillTotp(s, kept);
    }
    if (value instanceof List<?> list) {
      List<Object> out = new ArrayList<>();
      for (Object item : list) {
        out.add(fillDeep(item, kept));
      }
      return out;
    }
    if (value instanceof Map<?, ?> map) {
      Map<String, Object> out = new LinkedHashMap<>();
      for (Map.Entry<?, ?> e : map.entrySet()) {
        out.put(String.valueOf(e.getKey()), fillDeep(e.getValue(), kept));
      }
      return out;
    }
    return value;
  }
}
