package sh.runlight;

/**
 * JavaScript's RangeError, as the SDK throws it for a thing that does not exist ("Unknown link"),
 * so the routes can answer 404 for it and for nothing else.
 */
public class RangeError extends RuntimeException {
  private static final long serialVersionUID = 1L;

  public RangeError(String message) {
    super(message);
  }
}
