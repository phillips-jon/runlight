package sh.runlight;

import java.net.InetAddress;
import java.net.UnknownHostException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.function.Function;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import sh.runlight.http.FetchError;
import sh.runlight.http.FetchInit;
import sh.runlight.http.Fetcher;
import sh.runlight.http.JdkFetcher;
import sh.runlight.http.Response;
import sh.runlight.http.Url;

/**
 * Fetches from addresses that other people's input names, such as the icon links on a site's home
 * page or a link domain, and only from the public internet. Only https is fetched, never a private,
 * loopback, link-local, or metadata address, and redirects are followed by hand under the same
 * rules. The name is resolved and every address it gives is checked before each hop, and the
 * request is pinned to the checked addresses (the Fetcher's {@code resolve}), so a name that
 * answers differently a moment later gets nowhere.
 */
public final class Safefetch {
  private Safefetch() {}

  private static final Pattern V4_PART = Pattern.compile("^\\d{1,3}\\z");
  private static final Pattern V4_TAIL = Pattern.compile("(\\d{1,3}(?:\\.\\d{1,3}){3})\\z");
  private static final Pattern V6_GROUP = Pattern.compile("^[0-9a-f]{1,4}\\z");
  private static final Pattern BRACKETS = Pattern.compile("^\\[|\\]\\z");

  /** An install on this machine: http://localhost or http://127.0.0.1, with any port. */
  private static final Pattern LOCAL_INSTALL =
      Pattern.compile("^http://(localhost|127\\.0\\.0\\.1)(:\\d+)?(/|\\z)");

  private static final Pattern HTTPS_ADDRESS = Pattern.compile("^https://[^/]+");

  private static int[] v4(String text) {
    String[] parts = text.split("\\.", -1);
    if (parts.length != 4) {
      return null;
    }
    int[] out = new int[4];
    for (int i = 0; i < 4; i++) {
      if (!V4_PART.matcher(parts[i]).matches() || Integer.parseInt(parts[i]) > 255) {
        return null;
      }
      out[i] = Integer.parseInt(parts[i]);
    }
    return out;
  }

  private static boolean publicV4(int[] four) {
    int a = four[0];
    int b = four[1];
    int c = four[2];
    if (a == 0 || a == 10 || a == 127 || a >= 224) {
      return false;
    }
    if (a == 100 && b >= 64 && b < 128) {
      return false;
    }
    if (a == 169 && b == 254) {
      return false;
    }
    if (a == 172 && b >= 16 && b < 32) {
      return false;
    }
    if (a == 192 && b == 168) {
      return false;
    }
    if (a == 192 && b == 0 && (c == 0 || c == 2)) {
      return false;
    }
    if (a == 198 && (b == 18 || b == 19)) {
      return false;
    }
    if (a == 198 && b == 51 && c == 100) {
      return false;
    }
    return !(a == 203 && b == 0 && c == 113);
  }

  /** An IPv6 address as eight 16-bit groups, or null when it is not one. */
  private static int[] v6(String text) {
    String address = Js.lower(BRACKETS.matcher(text).replaceAll("").split("%", -1)[0]);
    // A trailing IPv4 address becomes the last two groups.
    Matcher tail = V4_TAIL.matcher(address);
    if (tail.find()) {
      int[] four = v4(tail.group(1));
      if (four == null) {
        return null;
      }
      address =
          address.substring(0, address.length() - tail.group(1).length())
              + Integer.toHexString((four[0] << 8) | four[1])
              + ":"
              + Integer.toHexString((four[2] << 8) | four[3]);
    }
    String[] halves = address.split("::", -1);
    if (halves.length > 2) {
      return null;
    }
    List<String> head = halves[0].isEmpty() ? List.of() : List.of(halves[0].split(":", -1));
    List<String> rest =
        halves.length == 2 && !halves[1].isEmpty() ? List.of(halves[1].split(":", -1)) : List.of();
    int missing = 8 - head.size() - rest.size();
    if (halves.length == 1 ? missing != 0 : missing < 1) {
      return null;
    }
    List<String> groups = new ArrayList<>(head);
    for (int i = 0; i < (halves.length == 2 ? missing : 0); i++) {
      groups.add("0");
    }
    groups.addAll(rest);
    int[] out = new int[8];
    for (int i = 0; i < 8; i++) {
      if (!V6_GROUP.matcher(groups.get(i)).matches()) {
        return null;
      }
      out[i] = Integer.parseInt(groups.get(i), 16);
    }
    return out;
  }

  private static int[] embedded(int hi, int lo) {
    return new int[] {hi >> 8, hi & 255, lo >> 8, lo & 255};
  }

  private static boolean zero(int[] groups, int from, int to) {
    for (int i = from; i < to; i++) {
      if (groups[i] != 0) {
        return false;
      }
    }
    return true;
  }

  /**
   * Whether an IP address, v4 or v6, is on the public internet. Anything that is not an address is
   * not.
   */
  public static boolean publicAddress(String ip) {
    int[] four = v4(ip);
    if (four != null) {
      return publicV4(four);
    }
    int[] g = v6(ip);
    if (g == null) {
      return false;
    }
    // IPv4 inside IPv6: mapped (::ffff:0:0/96), the old compatible form (::/96), and NAT64
    // (64:ff9b::/96).
    if (zero(g, 0, 5) && (g[5] == 0xffff || g[5] == 0)) {
      return g[5] == 0 && g[6] == 0 && g[7] <= 1 ? false : publicV4(embedded(g[6], g[7]));
    }
    if (g[0] == 0x64 && g[1] == 0xff9b && zero(g, 2, 6)) {
      return publicV4(embedded(g[6], g[7]));
    }
    // 6to4 carries an IPv4 address in its second and third groups.
    if (g[0] == 0x2002) {
      return publicV4(embedded(g[1], g[2]));
    }
    if ((g[0] & 0xfe00) == 0xfc00 || (g[0] & 0xffc0) == 0xfe80 || (g[0] & 0xff00) == 0xff00) {
      return false;
    }
    // Teredo, documentation, and discard prefixes.
    if (g[0] == 0x2001 && (g[1] == 0 || g[1] == 0xdb8)) {
      return false;
    }
    return !(g[0] == 0x100 && zero(g, 1, 4));
  }

  /**
   * Every address a name resolves to, v4 and v6, as getaddrinfo() gives them (the hosts file
   * included). Empty when it does not resolve.
   */
  public static List<String> lookup(String name) {
    String bare = BRACKETS.matcher(name).replaceAll("");
    if (v4(bare) != null || v6(bare) != null) {
      return List.of(bare);
    }
    LinkedHashSet<String> found = new LinkedHashSet<>();
    try {
      for (InetAddress address : InetAddress.getAllByName(bare)) {
        String text = address.getHostAddress();
        int scope = text.indexOf('%');
        found.add(scope < 0 ? text : text.substring(0, scope));
      }
    } catch (UnknownHostException | SecurityException e) {
      return List.of();
    }
    return new ArrayList<>(found);
  }

  /**
   * The public addresses a name resolves to, for setting up DNS records. None where it does not.
   */
  public static List<String> publicAddresses(String name) {
    return publicAddresses(name, null);
  }

  /**
   * The public addresses a name resolves to.
   *
   * @param lookup stands in for DNS in tests; null for {@link #lookup}
   */
  public static List<String> publicAddresses(String name, Function<String, List<String>> lookup) {
    List<String> addresses;
    try {
      addresses =
          (lookup != null ? lookup : (Function<String, List<String>>) Safefetch::lookup)
              .apply(name);
    } catch (RuntimeException e) {
      return List.of();
    }
    LinkedHashSet<String> out = new LinkedHashSet<>();
    for (String address : addresses) {
      if (publicAddress(address)) {
        out.add(address);
      }
    }
    return new ArrayList<>(out);
  }

  /** Whether a name resolves to an address off the public internet. False when it does not. */
  public static boolean resolvesPrivately(String name) {
    return resolvesPrivately(name, null);
  }

  /**
   * Whether a name resolves to an address off the public internet.
   *
   * @param lookup stands in for DNS in tests; null for {@link #lookup}
   */
  public static boolean resolvesPrivately(String name, Function<String, List<String>> lookup) {
    List<String> addresses;
    try {
      addresses =
          (lookup != null ? lookup : (Function<String, List<String>>) Safefetch::lookup)
              .apply(name);
    } catch (RuntimeException e) {
      return false;
    }
    for (String address : addresses) {
      if (!publicAddress(address)) {
        return true;
      }
    }
    return false;
  }

  /**
   * Fetches an https URL on the public internet, following up to {@code redirects} redirects that
   * stay on it, within {@code timeoutMs} in all. Only a GET follows redirects; anything else comes
   * back with the redirect as it is. Throws a {@link PrivateAddressError} for an address off it,
   * and a {@link FetchError} with {@code timedOut()} when time runs out. A redirect past the last
   * one comes back as it is. {@code maxBytes} and {@code truncate} go to the Fetcher, for a capped
   * read.
   *
   * @param init {@code timeoutMs} (required), and optionally {@code method} ("GET"), {@code body}
   *     (a string or bytes), {@code headers} (a map of names to values), {@code redirects} (0),
   *     {@code maxBytes}, {@code truncate}, and {@code lookup} (a {@code Function<String,
   *     List<String>>} standing in for DNS; the fetcher's own by default)
   * @param fetcher what sends each request; null for a {@link JdkFetcher}
   */
  public static Response publicFetch(String target, Map<String, Object> init, Fetcher fetcher) {
    Fetcher sender = fetcher != null ? fetcher : new JdkFetcher();
    Function<String, List<String>> lookup = lookupOf(init.get("lookup"), sender);
    long until = System.nanoTime() + Js.asLong(init.get("timeoutMs")) * 1_000_000L;
    String method = init.get("method") instanceof String given ? Js.upper(given) : "GET";
    long redirects =
        init.get("redirects") == null || !method.equals("GET")
            ? 0
            : Js.asLong(init.get("redirects"));
    Url url = new Url(target);
    for (int hop = 0; ; hop++) {
      if (!url.protocol.equals("https:")) {
        throw new PrivateAddressError(url.href());
      }
      String host = Js.lower(BRACKETS.matcher(url.hostname).replaceAll(""));
      boolean literal = v4(host) != null || v6(host) != null;
      if (literal && !publicAddress(host)) {
        throw new PrivateAddressError(host);
      }
      if (host.equals("localhost") || host.endsWith(".localhost")) {
        throw new PrivateAddressError(host);
      }
      String pin = null;
      if (!literal) {
        // The address checked is the address used: every one the name gives must be public, and
        // the connection is pinned to them, so a second lookup cannot hand back another.
        List<String> addresses = lookup.apply(host);
        if (addresses.isEmpty()) {
          throw new FetchError("getaddrinfo ENOTFOUND " + host);
        }
        List<String> written = new ArrayList<>();
        for (String address : addresses) {
          if (!publicAddress(address)) {
            throw new PrivateAddressError(host);
          }
          written.add(address.contains(":") ? "[" + address + "]" : address);
        }
        String port = url.port.isEmpty() ? "443" : url.port;
        pin = host + ":" + port + ":" + String.join(",", written);
      }
      long left = Math.floorDiv(until - System.nanoTime(), 1_000_000L);
      if (left <= 0) {
        throw timedOut();
      }
      FetchInit options = request(init).method(method).timeoutMs(left);
      if (init.get("truncate") != null) {
        options.truncate(Js.truthy(init.get("truncate")));
      }
      if (pin != null) {
        options.resolve(pin);
      }
      Response answer;
      try {
        answer = sender.fetch(url.href(), options);
      } catch (FetchError error) {
        // Whichever way the request gave up, the caller hears that time ran out.
        if (error.timedOut() || System.nanoTime() - until >= 0) {
          throw timedOut();
        }
        throw error;
      }
      String location = answer.headers().get("location");
      if (answer.status() < 300
          || answer.status() >= 400
          || location == null
          || location.isEmpty()
          || hop >= redirects) {
        return answer;
      }
      url = new Url(location, url.href());
    }
  }

  @SuppressWarnings("unchecked") // The init map holds the lookup as a plain Object.
  private static Function<String, List<String>> lookupOf(Object value, Fetcher fetcher) {
    return value == null ? fetcher::lookup : (Function<String, List<String>>) value;
  }

  /** The headers, body, and cap a request sends, as an init map holds them, with no redirects. */
  private static FetchInit request(Map<String, Object> init) {
    FetchInit options = new FetchInit().redirect("manual");
    if (init.get("headers") instanceof Map<?, ?> headers) {
      for (Map.Entry<?, ?> entry : headers.entrySet()) {
        options.headers.append(String.valueOf(entry.getKey()), String.valueOf(entry.getValue()));
      }
    }
    if (init.get("body") instanceof String body) {
      options.body(body);
    } else if (init.get("body") instanceof byte[] body) {
      options.body(body);
    }
    if (init.get("maxBytes") != null) {
      options.maxBytes(Js.asLong(init.get("maxBytes")));
    }
    return options;
  }

  /**
   * Whether an address can be another Runlight install's: https, or, with {@code local}, an install
   * on this machine, which only code can allow.
   */
  public static boolean installAddress(String url, boolean local) {
    return HTTPS_ADDRESS.matcher(url).find() || (local && LOCAL_INSTALL.matcher(url).find());
  }

  /**
   * Fetches from another Runlight install, which someone signed in named: a public address as
   * {@link #publicFetch} fetches it, with no redirect followed, so a token sent there goes nowhere
   * else. With {@code local}, an install on this machine is fetched as it is, still without
   * following a redirect.
   *
   * @param init as {@link #publicFetch} takes it, less {@code redirects}
   * @param local whether an install may be at http://localhost or http://127.0.0.1
   * @param fetcher what sends each request; null for a {@link JdkFetcher}
   */
  public static Response installFetch(
      String target, Map<String, Object> init, boolean local, Fetcher fetcher) {
    if (local && LOCAL_INSTALL.matcher(target).find()) {
      Fetcher sender = fetcher != null ? fetcher : new JdkFetcher();
      String method = init.get("method") instanceof String given ? Js.upper(given) : "GET";
      return sender.fetch(
          target, request(init).method(method).timeoutMs(Js.asLong(init.get("timeoutMs"))));
    }
    Map<String, Object> once = new HashMap<>(init);
    once.put("redirects", 0L);
    return publicFetch(target, once, fetcher);
  }

  private static FetchError timedOut() {
    return new FetchError("The operation was aborted due to timeout", true, null);
  }
}
