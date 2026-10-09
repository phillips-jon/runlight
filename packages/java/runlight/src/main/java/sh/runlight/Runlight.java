package sh.runlight;

import java.util.List;
import java.util.regex.Pattern;

/**
 * Runlight in an app: the sites it counts, the tracker endpoint's work, short links, email reports,
 * and the scheduled upkeep. A port of the TypeScript SDK's runlight.ts.
 */
public final class Runlight {
  /** A path on every link domain that answers when the domain reaches this Runlight. */
  public static final String LINK_DOMAIN_CHECK = "/.well-known/runlight-link-domain";

  /** The choices for how long a site keeps its visits. */
  public static final List<Long> RETENTION_MONTHS = List.of(6L, 12L, 24L, 36L, 60L);

  /** Thirty minutes without a request ends a session. */
  public static final long SESSION_IDLE_MS = 30 * 60 * 1000L;

  /**
   * What passes for an email address: something@somewhere.tld, with no spaces, quotes, or angle
   * brackets.
   */
  public static final Pattern EMAIL =
      Pattern.compile(
          "^[^"
              + Js.SPACE
              + "@<>\"]+@[^"
              + Js.SPACE
              + "@<>\"]+\\.[^"
              + Js.SPACE
              + "@<>\"]+\\z");

  private Runlight() {}
}
