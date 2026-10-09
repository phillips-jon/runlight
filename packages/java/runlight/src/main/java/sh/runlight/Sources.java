package sh.runlight;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import sh.runlight.data.Sources.SourcePattern;
import sh.runlight.http.SearchParams;
import sh.runlight.http.Url;

/**
 * Where a visit came from: the page's campaign tags and the referrer, read into a source and a
 * channel (Direct, Organic Search, Paid Search, Social, Email, AI, Referral, or Campaign).
 *
 * <p>A page is an object with hostname, path, utm (source, medium, campaign, term, content), ref (a
 * ref or source query parameter, used when there is no utm_source), and paid (a click id such as
 * gclid was present; the id itself is never kept). An attribution is an object with referrerHost,
 * referrerPath, source, and channel.
 */
public final class Sources {
  private Sources() {}

  private static final List<String> CLICK_IDS =
      List.of(
          "gclid",
          "gbraid",
          "wbraid",
          "dclid",
          "fbclid",
          "msclkid",
          "ttclid",
          "twclid",
          "li_fat_id",
          "yclid");
  private static final Pattern PAID_MEDIUMS =
      Pattern.compile(
          "^(cpc|ppc|paid|paidsearch|paid_search|paid-search|sem|cpm|cpv|display|banner|retargeting)\\z");
  private static final Pattern EMAIL_MEDIUMS = Pattern.compile("^(e-?mail|newsletter|mail)\\z");
  private static final Pattern SOCIAL_MEDIUMS =
      Pattern.compile(
          "^(social|social-network|social-media|sm|social_network|social_media|paid_social|paid-social|paidsocial)\\z");

  private static final Map<String, Map<String, Object>> BY_HOST = new HashMap<>();
  private static final Map<String, Map<String, Object>> BY_ALIAS = new HashMap<>();

  static {
    for (Map<String, Object> source : sh.runlight.data.Sources.SOURCES) {
      for (Object host : Js.list(source.get("hosts"))) {
        BY_HOST.put((String) host, source);
      }
      Object aliases = source.get("aliases");
      if (aliases != null) {
        for (Object alias : Js.list(aliases)) {
          BY_ALIAS.put((String) alias, source);
        }
      }
    }
  }

  private static String clip(String value) {
    return clip(value, 200);
  }

  private static String clip(String value, int max) {
    return Js.slice(Js.trim(value == null ? "" : value), 0, max);
  }

  private static final Pattern WWW = Pattern.compile("^www\\.");

  public static String stripWww(String host) {
    return WWW.matcher(Js.lower(host)).replaceFirst("");
  }

  /**
   * The most specific known source for a host: mail.google.com before google.com. Android apps send
   * their package name as the referrer (com.google.android.gm for Gmail), which is matched the same
   * way. Hosts known only by their shape (click trackers, webmail) come last.
   */
  public static Map<String, Object> sourceForHost(String host) {
    String clean = stripWww(host);
    String candidate = clean;
    while (candidate.contains(".")) {
      Map<String, Object> found = BY_HOST.get(candidate);
      if (found != null) {
        return found;
      }
      candidate = candidate.substring(candidate.indexOf('.') + 1);
    }
    for (SourcePattern rule : sh.runlight.data.Sources.SOURCE_PATTERNS) {
      if (rule.pattern().matcher(clean).find()) {
        return Json.object(
            "name",
            rule.name() != null ? rule.name() : clean,
            "kind",
            rule.kind(),
            "hosts",
            List.of());
      }
    }
    return null;
  }

  public static Map<String, Object> sourceForAlias(String value) {
    String key = Js.trim(Js.lower(value));
    Map<String, Object> found = BY_ALIAS.get(key);
    if (found != null) {
      return found;
    }
    return BY_HOST.get(stripWww(key));
  }

  private static final Pattern HTTP = Pattern.compile("^https?://", Pattern.CASE_INSENSITIVE);

  /**
   * A path a person wrote, in the form paths are recorded: the path of a pasted URL, with a leading
   * slash, percent-encoded as the browser's URL parser encodes it, and with a hash route kept, as
   * parsePage keeps it. Null when it is not a path or a URL.
   */
  public static String recordedPath(String input) {
    Url url =
        HTTP.matcher(input).find()
            ? Url.parse(input)
            : Url.parse(input.startsWith("/") ? input : "/" + input, "https://x.invalid");
    return url == null ? null : (String) parsePage(url).get("path");
  }

  private static final Pattern ESCAPES = Pattern.compile("(?:%[0-9A-Fa-f]{2})+");
  private static final Pattern UNSAFE = Pattern.compile("[" + Js.SPACE + "/?#%\\p{C}]");

  /**
   * A recorded path as people write it, for showing and exporting: /caf%C3%A9 as /café. Only text
   * is decoded; an encoded slash, space, or other mark that would change the path's meaning stays
   * as it is.
   */
  public static String readablePath(String path) {
    Matcher m = ESCAPES.matcher(path);
    StringBuilder out = new StringBuilder();
    while (m.find()) {
      String run = m.group();
      String text = Js.decodeURIComponent(run);
      String replacement = text == null || UNSAFE.matcher(text).find() ? run : text;
      m.appendReplacement(out, Matcher.quoteReplacement(replacement));
    }
    m.appendTail(out);
    return out.toString();
  }

  public static Map<String, Object> parsePage(Url url) {
    SearchParams q = url.searchParams();
    String path = url.pathname.isEmpty() ? "/" : url.pathname;
    // The tracker only sends a hash when the site asked for hash routing.
    if (url.hash.length() > 1) {
      path += url.hash;
    }
    boolean paid = false;
    for (String id : CLICK_IDS) {
      if (q.has(id)) {
        paid = true;
        break;
      }
    }
    String ref = q.get("ref");
    return Json.object(
        "hostname", stripWww(url.hostname),
        "path", Js.slice(path, 0, 1000),
        "utm",
            Json.object(
                "source", clip(q.get("utm_source")),
                "medium", Js.lower(clip(q.get("utm_medium"))),
                "campaign", clip(q.get("utm_campaign")),
                "term", clip(q.get("utm_term")),
                "content", clip(q.get("utm_content"))),
        "ref", clip(ref != null ? ref : q.get("source")),
        "paid", paid);
  }

  /**
   * Where a visit came from. {@code internalHosts} are the site's own hostnames: a referrer on one
   * of them is navigation within the site, not a source.
   */
  public static Map<String, Object> attribute(
      Map<String, Object> page, String referrer, List<String> internalHosts) {
    String referrerHost = "";
    String referrerPath = "";
    if (!referrer.isEmpty()) {
      Url url = Url.parse(referrer);
      // Android apps refer as android-app://<package>/.
      if (url != null
          && (url.protocol.equals("http:")
              || url.protocol.equals("https:")
              || url.protocol.equals("android-app:"))) {
        String host = stripWww(url.hostname);
        if (!host.equals(page.get("hostname")) && !internalHosts.contains(host)) {
          referrerHost = host;
          referrerPath = url.protocol.equals("android-app:") ? "" : Js.slice(url.pathname, 0, 500);
        }
      }
    }

    Map<String, Object> utm = Js.map(page.get("utm"));
    String utmSource = (String) utm.get("source");
    String tagged = !utmSource.isEmpty() ? utmSource : (String) page.get("ref");
    Map<String, Object> known =
        !tagged.isEmpty()
            ? sourceForAlias(tagged)
            : !referrerHost.isEmpty() ? sourceForHost(referrerHost) : null;
    String source =
        known != null ? (String) known.get("name") : !tagged.isEmpty() ? tagged : referrerHost;
    String kind = known != null ? (String) known.get("kind") : null;
    if (kind == null && !referrerHost.isEmpty()) {
      Map<String, Object> byHost = sourceForHost(referrerHost);
      kind = byHost == null ? null : (String) byHost.get("kind");
    }
    String medium = (String) utm.get("medium");

    String channel;
    if ((Boolean.TRUE.equals(page.get("paid")) || PAID_MEDIUMS.matcher(medium).find())
        && "search".equals(kind)) {
      channel = "Paid Search";
    } else if ("ai".equals(kind)) {
      channel = "AI";
    } else if (EMAIL_MEDIUMS.matcher(medium).find() || "email".equals(kind)) {
      channel = "Email";
    } else if ("search".equals(kind)) {
      channel = "Organic Search";
    } else if (SOCIAL_MEDIUMS.matcher(medium).find() || "social".equals(kind)) {
      channel = "Social";
    } else if (!utmSource.isEmpty()
        || !medium.isEmpty()
        || !((String) utm.get("campaign")).isEmpty()) {
      channel = "Campaign";
    } else if (!referrerHost.isEmpty() || !((String) page.get("ref")).isEmpty()) {
      channel = "Referral";
    } else {
      channel = "Direct";
    }
    return Json.object(
        "referrerHost",
        referrerHost,
        "referrerPath",
        referrerPath,
        "source",
        source,
        "channel",
        channel);
  }
}
