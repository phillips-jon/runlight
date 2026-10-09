package sh.runlight.http;

import java.io.ByteArrayOutputStream;
import java.net.IDN;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import sh.runlight.Js;

/**
 * An absolute URL, parsed the way browsers and JavaScript's URL do for http and https: the host
 * lowercased, backslashes read as slashes, dot segments resolved, and the path and query
 * percent-encoded with the WHATWG sets, so a path recorded here matches what the tracker sent and
 * what the TypeScript SDK stores.
 */
public final class Url {
  public String protocol;
  public String username = "";
  public String password = "";
  public String hostname;
  public String port;
  public String pathname;
  public String search;
  public String hash;

  /**
   * A URL of another scheme written with an authority, such as
   * android-app://com.google.android.gm/.
   */
  private boolean hasAuthority;

  private static final Map<String, String> DEFAULT_PORTS =
      Map.of("http:", "80", "https:", "443", "ws:", "80", "wss:", "443", "ftp:", "21");

  private static final Pattern SCHEME =
      Pattern.compile("^([a-zA-Z][a-zA-Z0-9+.\\-]*):(.*)\\z", Pattern.DOTALL);

  /** Thrown where {@code new URL()} throws a TypeError. */
  public static final class InvalidUrl extends IllegalArgumentException {
    private static final long serialVersionUID = 1L;

    public InvalidUrl(String message) {
      super(message);
    }
  }

  /** Parses an absolute URL; throws {@link InvalidUrl} when it is not one. */
  public Url(String input) {
    this(input, null);
  }

  /** Parses a URL against a base, as {@code new URL(input, base)}. */
  public Url(String input, String base) {
    input = stripControls(input);
    input = input.replace("\t", "").replace("\n", "").replace("\r", "");
    Matcher m = SCHEME.matcher(input);
    if (!m.matches()) {
      if (base == null) {
        throw new InvalidUrl("Invalid URL: " + input);
      }
      resolve(input, new Url(base));
      return;
    }
    protocol = m.group(1).toLowerCase(Locale.ROOT) + ":";
    String rest = m.group(2);
    if (!DEFAULT_PORTS.containsKey(protocol)) {
      // Not a special scheme (mailto:, data:, javascript:): kept as it came.
      hostname = "";
      port = "";
      if (rest.startsWith("//")) {
        // An authority after the scheme is an opaque host, kept in its case.
        rest = rest.substring(2);
        int end = cspan(rest, "/?#");
        opaqueAuthority(rest.substring(0, end));
        hasAuthority = true;
        tail(rest.substring(end), "");
        return;
      }
      String[] h = cut(rest, '#');
      hash = h[1];
      String[] q = cut(h[0], '?');
      pathname = q[0];
      search = q[1];
      return;
    }
    rest = rest.replace('\\', '/');
    int slashes = 0;
    while (slashes < rest.length() && rest.charAt(slashes) == '/') {
      slashes++;
    }
    rest = rest.substring(slashes);
    int end = cspan(rest, "/?#");
    authority(rest.substring(0, end));
    tail(rest.substring(end), "/");
  }

  /** The URL, or null where {@code new URL()} would throw. */
  public static Url parse(String input) {
    return parse(input, null);
  }

  public static Url parse(String input, String base) {
    try {
      return new Url(input, base);
    } catch (IllegalArgumentException e) {
      return null;
    }
  }

  public static boolean canParse(String input) {
    return parse(input) != null;
  }

  /** A copy, to change without touching this one. */
  public Url copy() {
    Url url = new Url();
    url.protocol = protocol;
    url.username = username;
    url.password = password;
    url.hostname = hostname;
    url.port = port;
    url.pathname = pathname;
    url.search = search;
    url.hash = hash;
    url.hasAuthority = hasAuthority;
    return url;
  }

  private Url() {}

  public String host() {
    return port.isEmpty() ? hostname : hostname + ":" + port;
  }

  public String origin() {
    return DEFAULT_PORTS.containsKey(protocol) ? protocol + "//" + host() : "null";
  }

  public String href() {
    if (!DEFAULT_PORTS.containsKey(protocol) && !hasAuthority) {
      return protocol + pathname + search + hash;
    }
    String auth =
        !username.isEmpty() || !password.isEmpty()
            ? username + (!password.isEmpty() ? ":" + password : "") + "@"
            : "";
    return protocol + "//" + auth + host() + pathname + search + hash;
  }

  @Override
  public String toString() {
    return href();
  }

  public SearchParams searchParams() {
    return new SearchParams(search);
  }

  /** Replaces the query with these parameters, as assigning url.search does. */
  public void setSearchParams(SearchParams params) {
    String text = params.toString();
    search = text.isEmpty() ? "" : "?" + text;
  }

  /** Replaces the path, as assigning url.pathname does. */
  public void setPathname(String path) {
    path = path.replace("\t", "").replace("\n", "").replace("\r", "");
    if (DEFAULT_PORTS.containsKey(protocol)) {
      path = path.replace('\\', '/');
    }
    pathname = path(path.isEmpty() || path.charAt(0) != '/' ? "/" + path : path);
  }

  /** Replaces the query, as assigning url.search does for http and https. */
  public void setSearch(String value) {
    if (value.isEmpty()) {
      search = "";
      return;
    }
    value = value.replace("\t", "").replace("\n", "").replace("\r", "");
    search = "?" + query(value.startsWith("?") ? value.substring(1) : value);
  }

  /** Replaces the fragment, as assigning url.hash does. */
  public void setHash(String value) {
    if (value.isEmpty()) {
      hash = "";
      return;
    }
    hash = "#" + fragment(value.startsWith("#") ? value.substring(1) : value);
  }

  private static String stripControls(String input) {
    int start = 0;
    int end = input.length();
    while (start < end && input.charAt(start) <= 0x20) {
      start++;
    }
    while (end > start && input.charAt(end - 1) <= 0x20) {
      end--;
    }
    return input.substring(start, end);
  }

  private void resolve(String input, Url base) {
    protocol = base.protocol;
    boolean special = DEFAULT_PORTS.containsKey(protocol);
    if (special) {
      input = input.replace('\\', '/');
    }
    if (input.startsWith("//")) {
      // A special scheme skips any further slashes before the host: ///x is the host x.
      String rest;
      if (special) {
        int slashes = 0;
        while (slashes < input.length() && input.charAt(slashes) == '/') {
          slashes++;
        }
        rest = input.substring(slashes);
      } else {
        rest = input.substring(2);
      }
      int end = cspan(rest, "/?#");
      authority(rest.substring(0, end));
      tail(rest.substring(end), "/");
      return;
    }
    username = base.username;
    password = base.password;
    hostname = base.hostname;
    port = base.port;
    hasAuthority = base.hasAuthority;
    if (input.isEmpty()) {
      pathname = base.pathname;
      search = base.search;
      hash = "";
      return;
    }
    char first = input.charAt(0);
    if (first == '#') {
      pathname = base.pathname;
      search = base.search;
      hash = input.length() > 1 ? "#" + fragment(input.substring(1)) : "";
      return;
    }
    if (first == '?') {
      pathname = base.pathname;
      String[] parts = cut(input.substring(1), '#');
      search = parts[0].isEmpty() ? "" : "?" + query(parts[0]);
      hash = parts[1].isEmpty() ? "" : "#" + fragment(parts[1].substring(1));
      return;
    }
    if (first == '/') {
      tail(input, "/");
      return;
    }
    String dir = base.pathname.substring(0, base.pathname.lastIndexOf('/') + 1);
    tail(dir + input, "/");
  }

  private void authority(String authority) {
    int at = authority.lastIndexOf('@');
    if (at >= 0) {
      String user = authority.substring(0, at);
      authority = authority.substring(at + 1);
      String[] parts = cut(user, ':');
      username = encode(parts[0], USERINFO);
      password = parts[1].isEmpty() ? "" : encode(parts[1].substring(1), USERINFO);
    }
    String host;
    String portText = "";
    if (authority.startsWith("[")) {
      int close = authority.indexOf(']');
      if (close < 0) {
        throw new InvalidUrl("Invalid URL");
      }
      host = authority.substring(0, close + 1).toLowerCase(Locale.ROOT);
      String after = authority.substring(close + 1);
      if (!after.isEmpty()) {
        if (after.charAt(0) != ':') {
          throw new InvalidUrl("Invalid URL");
        }
        portText = after.substring(1);
      }
    } else {
      int colon = authority.lastIndexOf(':');
      host = colon < 0 ? authority : authority.substring(0, colon);
      portText = colon < 0 ? "" : authority.substring(colon + 1);
      host = domain(host);
    }
    if (host.isEmpty()) {
      throw new InvalidUrl("Invalid URL");
    }
    if (!portText.isEmpty()) {
      int number = portNumber(portText);
      if (number < 0) {
        throw new InvalidUrl("Invalid URL");
      }
      portText = Integer.toString(number);
      if (portText.equals(DEFAULT_PORTS.get(protocol))) {
        portText = "";
      }
    }
    hostname = host;
    port = portText;
  }

  private static final Pattern OPAQUE_FORBIDDEN = Pattern.compile("[\\x00 #/:<>?@\\[\\\\\\]^|]");

  private void opaqueAuthority(String authority) {
    int at = authority.lastIndexOf('@');
    if (at >= 0) {
      String[] parts = cut(authority.substring(0, at), ':');
      username = encode(parts[0], USERINFO);
      password = parts[1].isEmpty() ? "" : encode(parts[1].substring(1), USERINFO);
      authority = authority.substring(at + 1);
    }
    int colon = authority.lastIndexOf(':');
    String host = colon < 0 ? authority : authority.substring(0, colon);
    String portText = colon < 0 ? "" : authority.substring(colon + 1);
    if (OPAQUE_FORBIDDEN.matcher(host).find()
        || (!portText.isEmpty() && portNumber(portText) < 0)) {
      throw new InvalidUrl("Invalid URL");
    }
    hostname = encode(host, "");
    port = portText.isEmpty() ? "" : Integer.toString(portNumber(portText));
  }

  private void tail(String rest, String empty) {
    String[] h = cut(rest, '#');
    String[] q = cut(h[0], '?');
    String path = q[0];
    pathname = path.isEmpty() && empty.isEmpty() ? "" : path(path.isEmpty() ? empty : path);
    search = q[1].length() > 1 ? "?" + query(q[1].substring(1)) : "";
    hash = h[1].length() > 1 ? "#" + fragment(h[1].substring(1)) : "";
  }

  /** The part before {@code mark}, and the rest starting with it. */
  private static String[] cut(String text, char mark) {
    int at = text.indexOf(mark);
    return at < 0
        ? new String[] {text, ""}
        : new String[] {text.substring(0, at), text.substring(at)};
  }

  private static int cspan(String text, String stops) {
    for (int i = 0; i < text.length(); i++) {
      if (stops.indexOf(text.charAt(i)) >= 0) {
        return i;
      }
    }
    return text.length();
  }

  /** A port written in digits, as a number up to 65535, or -1. */
  private static int portNumber(String text) {
    if (text.isEmpty()) {
      return -1;
    }
    long value = 0;
    for (int i = 0; i < text.length(); i++) {
      char c = text.charAt(i);
      if (c < '0' || c > '9') {
        return -1;
      }
      value = value * 10 + (c - '0');
      if (value > 65535) {
        return -1;
      }
    }
    return (int) value;
  }

  private static final Pattern HOST_FORBIDDEN =
      Pattern.compile("[\\x00-\\x20#%/:<>?@\\[\\\\\\]^|]");

  private static String domain(String host) {
    host = percentDecode(host);
    if (HOST_FORBIDDEN.matcher(host).find()) {
      throw new InvalidUrl("Invalid URL");
    }
    String lower = host.toLowerCase(Locale.ROOT);
    boolean ascii = true;
    for (int i = 0; i < lower.length(); i++) {
      if (lower.charAt(i) > 0x7f) {
        ascii = false;
        break;
      }
    }
    if (!ascii) {
      try {
        lower = IDN.toASCII(lower, IDN.ALLOW_UNASSIGNED).toLowerCase(Locale.ROOT);
      } catch (IllegalArgumentException e) {
        throw new InvalidUrl("Invalid URL");
      }
      if (HOST_FORBIDDEN.matcher(lower).find() || lower.isEmpty()) {
        throw new InvalidUrl("Invalid URL");
      }
    }
    String ipv4 = ipv4(lower);
    return ipv4 != null ? ipv4 : lower;
  }

  private static String percentDecode(String text) {
    if (text.indexOf('%') < 0) {
      return text;
    }
    byte[] source = text.getBytes(StandardCharsets.UTF_8);
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    for (int i = 0; i < source.length; i++) {
      if (source[i] == '%'
          && i + 2 < source.length
          && Character.digit(source[i + 1], 16) >= 0
          && Character.digit(source[i + 2], 16) >= 0) {
        out.write(Character.digit(source[i + 1], 16) * 16 + Character.digit(source[i + 2], 16));
        i += 2;
      } else {
        out.write(source[i]);
      }
    }
    return new String(out.toByteArray(), StandardCharsets.UTF_8);
  }

  private static final Pattern LAST_NUMBER = Pattern.compile("^(0x[0-9a-f]*|[0-9]+)\\z");

  /**
   * A host written as an IPv4 address in any form browsers accept, normalised to dotted decimal.
   */
  private static String ipv4(String host) {
    List<String> parts = new ArrayList<>(List.of(host.split("\\.", -1)));
    if (!parts.isEmpty() && parts.get(parts.size() - 1).isEmpty()) {
      parts.remove(parts.size() - 1);
    }
    if (parts.isEmpty() || parts.size() > 4) {
      return null;
    }
    if (!LAST_NUMBER.matcher(parts.get(parts.size() - 1)).matches()) {
      return null;
    }
    List<Double> numbers = new ArrayList<>();
    for (String part : parts) {
      if (part.matches("^0x[0-9a-f]*$")) {
        String hex = part.substring(2);
        numbers.add(hex.isEmpty() ? 0.0 : new java.math.BigInteger(hex, 16).doubleValue());
      } else if (part.matches("^0[0-7]+$")) {
        numbers.add(new java.math.BigInteger(part, 8).doubleValue());
      } else if (part.matches("^[0-9]+$")) {
        numbers.add(new java.math.BigInteger(part).doubleValue());
      } else {
        throw new InvalidUrl("Invalid URL");
      }
    }
    double value = numbers.remove(numbers.size() - 1);
    for (double n : numbers) {
      if (n > 255) {
        throw new InvalidUrl("Invalid URL");
      }
    }
    if (value >= Math.pow(256, 5 - parts.size())) {
      throw new InvalidUrl("Invalid URL");
    }
    for (int i = 0; i < numbers.size(); i++) {
      value += numbers.get(i) * Math.pow(256, 3 - i);
    }
    long v = (long) value;
    return ((v >> 24) & 255) + "." + ((v >> 16) & 255) + "." + ((v >> 8) & 255) + "." + (v & 255);
  }

  private static final String PATH = " \"#<>?`{}";
  private static final String QUERY = " \"#<>'";
  private static final String FRAGMENT = " \"<>`";
  private static final String USERINFO = " \"#<>?`{}/:;=@[\\]^|";

  private static String path(String path) {
    List<String> out = new ArrayList<>();
    String[] segments = path.split("/", -1);
    int count = segments.length - 1;
    for (int i = 1; i < segments.length; i++) {
      String segment = segments[i];
      String lower = segment.toLowerCase(Locale.ROOT);
      boolean last = i == count;
      if (lower.equals("..")
          || lower.equals(".%2e")
          || lower.equals("%2e.")
          || lower.equals("%2e%2e")) {
        if (!out.isEmpty()) {
          out.remove(out.size() - 1);
        }
        if (last) {
          out.add("");
        }
      } else if (lower.equals(".") || lower.equals("%2e")) {
        if (last) {
          out.add("");
        }
      } else {
        out.add(encode(segment, PATH));
      }
    }
    return "/" + String.join("/", out);
  }

  private static String query(String query) {
    return encode(query, QUERY);
  }

  private static String fragment(String fragment) {
    return encode(fragment, FRAGMENT);
  }

  /**
   * Percent-encodes C0 controls, DEL, bytes past ASCII, and {@code extra}; existing escapes stay.
   */
  public static String encode(String text, String extra) {
    StringBuilder out = new StringBuilder(text.length());
    for (byte b : Js.utf8(text)) {
      int o = b & 0xFF;
      if (o < 0x21 || o > 0x7e || extra.indexOf(o) >= 0) {
        out.append(String.format("%%%02X", o));
      } else {
        out.append((char) o);
      }
    }
    return out.toString();
  }
}
