package sh.runlight.servlet;

import java.io.IOException;

/** A request body past its limit, answered with 413 rather than passed on empty. */
public final class BodyTooLarge extends IOException {
  private static final long serialVersionUID = 1L;

  /** The body was over {@code limit} bytes. */
  public BodyTooLarge(long limit) {
    super("Request body over " + limit + " bytes");
  }
}
