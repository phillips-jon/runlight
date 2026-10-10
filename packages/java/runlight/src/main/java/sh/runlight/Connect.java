package sh.runlight;

import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Function;
import java.util.function.LongSupplier;
import java.util.regex.Pattern;
import sh.runlight.http.BodyTooLong;
import sh.runlight.http.FetchError;
import sh.runlight.http.Fetcher;
import sh.runlight.http.Response;
import sh.runlight.http.SearchParams;
import sh.runlight.http.Url;
import sh.runlight.store.SqlStore;

/**
 * Connecting another Runlight to this one (a hub) without copying a token: this server registers
 * itself with the install's OAuth server, sends the owner to that install's consent page, and on
 * the way back swaps the code for a manage token, limited there to the one site the owner picked.
 *
 * <p>A pending attempt is kept in settings as {@code connect:<state>}: the install's {@code url},
 * the {@code client} id it gave, the PKCE {@code verifier}, the {@code redirect} address, its
 * {@code token} endpoint, and when it {@code expires}.
 *
 * <p>Each call takes the Runlight's store, fetcher, and clock, and finishing takes its addSite,
 * which adds the connected site and returns its row.
 */
public final class Connect {
  private Connect() {}

  private static final long PENDING_MS = 15 * 60_000L;

  /** The most an install's answer while connecting may weigh; a real one is under a kilobyte. */
  private static final long MAX_BYTES = 64 * 1024;

  private static final Pattern STATE = Pattern.compile("^[a-f0-9]{32}\\z");

  /** The install's address as its dashboard is, without a trailing slash. */
  public static String installUrl(Object value) {
    return installUrl(value, false);
  }

  /**
   * The install's address as its dashboard is, without a trailing slash.
   *
   * @param local whether an install may be at http://localhost or http://127.0.0.1
   */
  public static String installUrl(Object value, boolean local) {
    String url =
        Js.trim(Js.string(value == null || value == Json.UNDEFINED ? "" : value))
            .replaceFirst("/+\\z", "");
    // The pattern says which addresses are allowed; the parser, that it is an address at all
    // ("https://[" is not).
    if (!Safefetch.installAddress(url, local) || !Url.canParse(url)) {
      throw new ConnectError(
          "Enter the install's address, like https://example.com/runlight", "url");
    }
    return url;
  }

  /**
   * A saved attempt, or null when it cannot be read or has no time it runs out, which counts as
   * expired.
   */
  private static Object pendingFrom(String value, long now) {
    Json.Parsed parsed = Json.tryParse(value == null ? "" : value);
    if (!parsed.ok() || !(parsed.value() instanceof Map<?, ?> pending)) {
      return null;
    }
    return pending.get("expires") instanceof Number expires && expires.doubleValue() >= now
        ? pending
        : null;
  }

  /** Attempts nobody came back from are removed, so they do not pile up in settings. */
  private static void clearExpired(SqlStore store, LongSupplier now) {
    for (Map<String, Object> setting : store.settingsStartingWith("connect:")) {
      if (pendingFrom((String) setting.get("value"), now.getAsLong()) == null) {
        store.setSetting((String) setting.get("key"), null);
      }
    }
  }

  /** The PKCE challenge for a verifier: SHA-256, base64url without padding (oauth.ts's s256). */
  private static String s256(String verifier) {
    return Base64.getUrlEncoder()
        .withoutPadding()
        .encodeToString(Hash.sha256Bytes(Js.utf8(verifier)));
  }

  /** A JSON body, or null when it is not JSON, as {@code answer.json().catch(() => null)}. */
  private static Object json(Response answer) {
    Json.Parsed parsed = Json.tryParse(answer.text());
    return parsed.ok() ? parsed.value() : null;
  }

  /** Starts connecting: returns the address of the install's consent page. */
  public static String startConnect(
      SqlStore store, Fetcher fetcher, LongSupplier now, Object input, String back) {
    return startConnect(store, fetcher, now, input, back, "", false);
  }

  /**
   * Starts connecting: returns the address of the install's consent page, for an install at a
   * public https address.
   *
   * @param site which of its sites to offer first, or ""
   */
  public static String startConnect(
      SqlStore store, Fetcher fetcher, LongSupplier now, Object input, String back, String site) {
    return startConnect(store, fetcher, now, input, back, site, false);
  }

  /**
   * Starts connecting: returns the address of the install's consent page.
   *
   * @param site which of its sites to offer first, or ""
   * @param local the Runlight's localInstalls: whether an install may be at http://localhost or
   *     http://127.0.0.1
   */
  public static String startConnect(
      SqlStore store,
      Fetcher fetcher,
      LongSupplier now,
      Object input,
      String back,
      String site,
      boolean local) {
    String url = installUrl(input, local);
    String host = new Url(url).host();
    Response answer;
    try {
      answer =
          Safefetch.installFetch(
              url + "/.well-known/oauth-authorization-server",
              Json.object("timeoutMs", 10_000L, "maxBytes", MAX_BYTES),
              local,
              fetcher);
    } catch (BodyTooLong e) {
      throw new ConnectError(
          url + " did not answer like a Runlight install", "not_runlight", Json.object("url", url));
    } catch (FetchError | PrivateAddressError e) {
      throw new ConnectError("Could not reach " + url, "unreachable", Json.object("host", host));
    }
    Object meta = answer.ok() ? json(answer) : null;
    Object authorization = Js.get(meta, "authorization_endpoint");
    Object tokenEndpoint = Js.get(meta, "token_endpoint");
    Object registration = Js.get(meta, "registration_endpoint");
    if (!Js.truthy(authorization) || !Js.truthy(tokenEndpoint) || !Js.truthy(registration)) {
      throw new ConnectError(
          url + " did not answer like a Runlight install", "not_runlight", Json.object("url", url));
    }
    // Its endpoints must be its own, so an address cannot steer this server into requests
    // elsewhere.
    String origin = new Url(url).origin();
    for (Object endpoint : List.of(authorization, tokenEndpoint, registration)) {
      Url parsed = Url.parse(Js.string(endpoint));
      if (parsed == null || !parsed.origin().equals(origin)) {
        throw new ConnectError(
            url + " named endpoints on another address", "endpoints", Json.object("url", url));
      }
    }
    Object scopes = Js.get(meta, "scopes_supported");
    if (!(scopes instanceof List<?> list && list.contains("manage"))) {
      throw new ConnectError(
          url
              + " runs an older Runlight. Update it, or connect it with an API token from its Settings.",
          "old",
          Json.object("url", url));
    }

    Response registered;
    try {
      registered =
          Safefetch.installFetch(
              Js.string(registration),
              Json.object(
                  "method",
                  "POST",
                  "headers",
                  Map.of("content-type", "application/json"),
                  "body",
                  Json.stringify(
                      Json.object(
                          "client_name",
                          "Runlight at " + new Url(back).host(),
                          "redirect_uris",
                          Json.array(back))),
                  "timeoutMs",
                  10_000L,
                  "maxBytes",
                  MAX_BYTES),
              local,
              fetcher);
    } catch (FetchError | PrivateAddressError | BodyTooLong e) {
      throw new ConnectError("Could not reach " + url, "unreachable", Json.object("host", host));
    }
    Object client = json(registered);
    Object clientId = Js.get(client, "client_id");
    if (!registered.ok() || !Js.truthy(clientId)) {
      // Say why, in the install's own words when it gives them.
      Object description = Js.get(client, "error_description");
      String reason =
          Js.truthy(description)
              ? Js.slice(Js.string(description), 0, 200) + "."
              : registered.status() == 400
                  ? "This server's address must use https."
                  : "It answered " + registered.status() + ".";
      throw new ConnectError(
          url + " would not let this server connect. " + reason,
          "register",
          Json.object("url", url, "reason", reason));
    }
    clearExpired(store, now);

    String state = Hash.randomId(16);
    String verifier = Hash.randomId(32) + Hash.randomId(32);
    Map<String, Object> pending =
        Json.object(
            "url", url,
            "client", clientId,
            "verifier", verifier,
            "redirect", back,
            "token", tokenEndpoint,
            "expires", now.getAsLong() + PENDING_MS);
    store.setSetting("connect:" + state, Json.stringify(pending));
    Url to = new Url(Js.string(authorization));
    Map<String, String> query = new LinkedHashMap<>();
    query.put("response_type", "code");
    query.put("client_id", Js.string(clientId));
    query.put("redirect_uri", back);
    query.put("code_challenge", s256(verifier));
    query.put("code_challenge_method", "S256");
    query.put("scope", "manage");
    query.put("state", state);
    // Which of its sites to offer first, when connecting again for a site already here.
    if (!site.isEmpty()) {
      query.put("site", site);
    }
    to.setSearch(new SearchParams(query).toString());
    return to.href();
  }

  /**
   * Finishes connecting, for an install at a public https address.
   *
   * @param addSite the Runlight's addSite
   */
  public static String finishConnect(
      SqlStore store,
      Fetcher fetcher,
      LongSupplier now,
      Function<Map<String, Object>, Map<String, Object>> addSite,
      SearchParams params) {
    return finishConnect(store, fetcher, now, addSite, params, false);
  }

  /**
   * Finishes connecting when the owner comes back from the consent page. Returns the site's id
   * here.
   *
   * @param addSite the Runlight's addSite: takes {@code {remote: {url, token, site?}}} and returns
   *     the site's row
   * @param local the Runlight's localInstalls
   */
  public static String finishConnect(
      SqlStore store,
      Fetcher fetcher,
      LongSupplier now,
      Function<Map<String, Object>, Map<String, Object>> addSite,
      SearchParams params,
      boolean local) {
    String state = params.get("state") == null ? "" : params.get("state");
    String key = "connect:" + state;
    String stored = STATE.matcher(state).find() ? store.setting(key) : null;
    boolean found = stored != null && !stored.isEmpty();
    // Each attempt works once.
    if (found) {
      store.setSetting(key, null);
    }
    Object pending = found ? pendingFrom(stored, now.getAsLong()) : null;
    if (pending == null) {
      throw new ConnectError(
          "That connection took too long or was already used. Start again.", "expired");
    }
    String error = params.get("error");
    if ("access_denied".equals(error)) {
      throw new ConnectError("The connection was not allowed.", "denied");
    }
    if (error != null && !error.isEmpty()) {
      String description = params.get("error_description");
      throw new ConnectError(description != null ? description : error, "refused");
    }

    Response answer = null;
    try {
      Map<String, String> form = new LinkedHashMap<>();
      form.put("grant_type", "authorization_code");
      form.put("code", params.get("code") == null ? "" : params.get("code"));
      form.put("client_id", Js.string(Js.get(pending, "client")));
      form.put("redirect_uri", Js.string(Js.get(pending, "redirect")));
      form.put("code_verifier", Js.string(Js.get(pending, "verifier")));
      answer =
          Safefetch.installFetch(
              Js.string(Js.get(pending, "token")),
              Json.object(
                  "method",
                  "POST",
                  "headers",
                  Map.of("content-type", "application/x-www-form-urlencoded"),
                  "body",
                  new SearchParams(form).toString(),
                  "timeoutMs",
                  10_000L,
                  "maxBytes",
                  MAX_BYTES),
              local,
              fetcher);
    } catch (FetchError | PrivateAddressError | BodyTooLong e) {
      // As fetch().catch(() => null): no answer.
    }
    Object granted = answer != null && answer.ok() ? json(answer) : null;
    Object token = Js.get(granted, "access_token");
    if (!Js.truthy(token)) {
      throw new ConnectError(
          new Url(Js.string(Js.get(pending, "url"))).host()
              + " did not give this server a token. Start again.",
          "token");
    }
    Map<String, Object> remote =
        Json.object("url", Js.get(pending, "url"), "token", token, "site", Js.get(granted, "site"));
    Map<String, Object> site = addSite.apply(Json.object("remote", defined(remote)));
    return (String) site.get("id");
  }

  /** The fields holding undefined left out, as JSON.stringify keeps an object. */
  private static Map<String, Object> defined(Map<String, Object> fields) {
    Map<String, Object> out = new LinkedHashMap<>();
    for (Map.Entry<String, Object> e : fields.entrySet()) {
      if (e.getValue() != Json.UNDEFINED) {
        out.put(e.getKey(), e.getValue());
      }
    }
    return out;
  }
}
