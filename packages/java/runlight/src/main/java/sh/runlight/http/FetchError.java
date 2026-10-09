package sh.runlight.http;

/**
 * No answer came back: the connection was refused, timed out, or failed TLS. fetch() rejects with a
 * TypeError then.
 */
public class FetchError extends RuntimeException {
  private static final long serialVersionUID = 1L;

  private final boolean timedOut;

  public FetchError(String message) {
    this(message, false, null);
  }

  public FetchError(String message, boolean timedOut, Throwable cause) {
    super(message, cause);
    this.timedOut = timedOut;
  }

  public boolean timedOut() {
    return timedOut;
  }
}
