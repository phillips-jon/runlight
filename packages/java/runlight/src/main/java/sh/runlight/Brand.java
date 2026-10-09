package sh.runlight;

/** The Runlight mark. */
public final class Brand {
  private Brand() {}

  /**
   * The Runlight mark for the dashboard's tab: an R in a rounded lamp housing, one corner lit. A
   * data: URL, read from the assets the TypeScript SDK's RUNLIGHT_ICON is copied into.
   */
  public static String runlightIcon() {
    return Version.runlightIcon();
  }
}
