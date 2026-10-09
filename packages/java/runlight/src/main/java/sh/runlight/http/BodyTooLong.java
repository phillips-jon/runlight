package sh.runlight.http;

/** A body longer than the reader allows. */
public final class BodyTooLong extends RuntimeException {
  private static final long serialVersionUID = 1L;

  public BodyTooLong(String message) {
    super(message);
  }
}
