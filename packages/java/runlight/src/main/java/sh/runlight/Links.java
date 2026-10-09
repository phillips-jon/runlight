package sh.runlight;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.LongSupplier;
import java.util.regex.Pattern;
import sh.runlight.CodedError.LinkError;
import sh.runlight.http.Url;
import sh.runlight.store.SqlStore;

/**
 * Short links: create, change, delete, and import, with the rules every route shares.
 *
 * <p>A LinkInput is a map with {@code url}, and optionally {@code name}, {@code slug}, and {@code
 * domain} (a link domain added in Settings, or "" for the app's own). A key left out, or set to
 * {@link Json#UNDEFINED}, is TS's undefined.
 */
public final class Links {
  public static final Pattern SLUG_PATTERN = Pattern.compile("^[A-Za-z0-9][A-Za-z0-9_-]{0,99}\\z");
  private static final String ALPHABET = "abcdefghijkmnpqrstuvwxyz23456789";

  private final SqlStore store;
  private final Runnable init;
  private final LongSupplier now;

  /**
   * @param store the Runlight's store
   * @param init the Runlight's init(), run before each change
   * @param now the Runlight's clock, in milliseconds
   */
  public Links(SqlStore store, Runnable init, LongSupplier now) {
    this.store = store;
    this.init = init;
    this.now = now;
  }

  /** Six characters from an alphabet without look-alikes (no 0/o, 1/l). */
  public static String randomSlug() {
    StringBuilder slug = new StringBuilder();
    for (byte b : Hash.randomBytes(6)) {
      slug.append(ALPHABET.charAt((b & 0xFF) % ALPHABET.length()));
    }
    return slug.toString();
  }

  private static boolean given(Map<String, Object> input, String key) {
    return input.containsKey(key) && input.get(key) != Json.UNDEFINED;
  }

  /** String(value ?? "").trim(). */
  private static String text(Object value) {
    return Js.trim(value == null || value == Json.UNDEFINED ? "" : Js.string(value));
  }

  private static String cleanUrl(Object value) {
    String text = text(value);
    Url url = Url.parse(text);
    if (url == null) {
      throw new LinkError("The destination must be a full URL, starting with https://", "link_url");
    }
    if (!url.protocol.equals("https:") && !url.protocol.equals("http:")) {
      throw new LinkError("The destination must start with http:// or https://", "link_protocol");
    }
    if (text.length() > 2000) {
      throw new LinkError("The destination is longer than 2,000 characters", "link_long");
    }
    return url.href();
  }

  private static String defaultName(String url) {
    Url u = new Url(url);
    return Js.slice(
        Sources.stripWww(u.hostname) + (u.pathname.equals("/") ? "" : u.pathname), 0, 100);
  }

  private String domainFor(String site, Object value) {
    String domain = Sources.stripWww(text(value));
    if (domain.isEmpty()) {
      return "";
    }
    for (Map<String, Object> d : store.linkDomains()) {
      if (domain.equals(d.get("domain")) && site.equals(d.get("site"))) {
        return domain;
      }
    }
    throw new LinkError(
        "Add " + domain + " as a link domain in Settings first",
        "link_domain",
        Map.of("domain", domain));
  }

  /** Slugs are unique across every domain, so a link can always fall back to the app's own path. */
  private String freeSlug(String wanted, String except) {
    if (wanted != null && !wanted.isEmpty()) {
      if (!SLUG_PATTERN.matcher(wanted).find()) {
        throw new LinkError(
            "A slug is letters, digits, dashes, and underscores, up to 100", "link_slug");
      }
      Map<String, Object> taken = store.linkBySlug(wanted);
      if (taken != null && !taken.get("id").equals(except)) {
        throw new LinkError(
            "/" + wanted + " is already taken", "link_taken", Map.of("slug", wanted));
      }
      return wanted;
    }
    for (int i = 0; i < 8; i++) {
      String slug = randomSlug();
      if (store.linkBySlug(slug) == null) {
        return slug;
      }
    }
    throw new LinkError("Could not find a free slug; try again", "link_no_slug");
  }

  /**
   * Makes a link (a LinkRow).
   *
   * @throws LinkError when the link cannot be made
   */
  public Map<String, Object> create(String site, Map<String, Object> input) {
    init.run();
    String url = cleanUrl(input.get("url"));
    String domain = domainFor(site, input.get("domain"));
    String slug = freeSlug(given(input, "slug") ? text(input.get("slug")) : null, null);
    long at = now.getAsLong();
    String name = given(input, "name") ? text(input.get("name")) : "";
    Map<String, Object> link = new LinkedHashMap<>();
    link.put("id", Hash.randomId());
    link.put("site", site);
    link.put("domain", domain);
    link.put("slug", slug);
    link.put("name", Js.slice(name.isEmpty() ? defaultName(url) : name, 0, 100));
    link.put("url", url);
    link.put("createdAt", at);
    link.put("updatedAt", at);
    store.insertLink(link);
    return link;
  }

  /**
   * Changes a link; keys left out are left alone.
   *
   * @throws LinkError when the change cannot be made
   * @throws RangeError ("Unknown link") when there is no such link
   */
  public Map<String, Object> update(String id, Map<String, Object> input) {
    init.run();
    Map<String, Object> link = store.linkById(id);
    if (link == null) {
      throw new RangeError("Unknown link");
    }
    Map<String, Object> next = new LinkedHashMap<>(link);
    if (given(input, "url")) {
      next.put("url", cleanUrl(input.get("url")));
    }
    if (given(input, "name")) {
      String name = Js.slice(Js.trim(Js.string(input.get("name"))), 0, 100);
      next.put("name", name.isEmpty() ? defaultName((String) next.get("url")) : name);
    }
    // Keeping a link's domain needs no check, even while that domain is removed.
    if (given(input, "domain")
        && !Sources.stripWww(text(input.get("domain"))).equals(link.get("domain"))) {
      next.put("domain", domainFor((String) link.get("site"), input.get("domain")));
    }
    if (given(input, "slug")) {
      next.put("slug", freeSlug(text(input.get("slug")), (String) link.get("id")));
    }
    next.put("updatedAt", now.getAsLong());
    store.updateLink(next);
    return next;
  }

  /**
   * Deletes a link, freeing its slug.
   *
   * @throws RangeError ("Unknown link") when there is no such link
   */
  public void remove(String id) {
    init.run();
    if (store.linkById(id) == null) {
      throw new RangeError("Unknown link");
    }
    store.deleteLink(id, now.getAsLong());
  }

  /**
   * Creates many links at once, as from a CSV. Rows that fail are reported with their reason and
   * the rest go in. Headers match the Umami fork's export: name or link_name, url or
   * destination_url, slug or link_slug, domain or tracking_domain.
   *
   * @return {@code {created, failed: [{row, reason, code, params}]}}
   */
  public Map<String, Object> importRows(String site, List<?> rows) {
    List<Object> failed = new ArrayList<>();
    long created = 0;
    for (int i = 0; i < rows.size(); i++) {
      Object raw = rows.get(i);
      Map<String, Object> input = new LinkedHashMap<>();
      String url = pick(raw, "url", "destination_url");
      input.put("url", url == null ? "" : url);
      input.put("name", undefinedIfNull(pick(raw, "name", "link_name")));
      input.put("slug", undefinedIfNull(pick(raw, "slug", "link_slug")));
      input.put("domain", undefinedIfNull(pick(raw, "domain", "tracking_domain")));
      try {
        create(site, input);
        created++;
      } catch (LinkError error) {
        // A bad row is reported and skipped; a failing database stops the whole import.
        failed.add(
            Json.object(
                "row",
                (long) i + 1,
                "reason",
                error.getMessage(),
                "code",
                error.code(),
                "params",
                new LinkedHashMap<>(error.params())));
      }
    }
    return Json.object("created", created, "failed", failed);
  }

  private static Object undefinedIfNull(String value) {
    return value == null ? Json.UNDEFINED : value;
  }

  private static String pick(Object raw, String... keys) {
    for (String key : keys) {
      if (Js.get(raw, key) instanceof String value && !Js.trim(value).isEmpty()) {
        return Js.trim(value);
      }
    }
    return null;
  }
}
