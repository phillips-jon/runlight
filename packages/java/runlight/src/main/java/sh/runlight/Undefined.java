package sh.runlight;

/**
 * JavaScript's undefined, for the few answers that build an object with a field that may be left
 * out: {@link Json} skips a field holding it.
 */
public final class Undefined {
  /** The one undefined. */
  public static final Undefined VALUE = new Undefined();

  private Undefined() {}

  @Override
  public String toString() {
    return "undefined";
  }
}
