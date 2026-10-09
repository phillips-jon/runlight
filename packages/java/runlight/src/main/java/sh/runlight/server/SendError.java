package sh.runlight.server;

/**
 * A failure to reach Runlight or have it take a batch, told apart from a failure to read the log.
 */
public final class SendError extends RuntimeException {
  private static final long serialVersionUID = 1L;

  public SendError(String message) {
    super(message);
  }

  public SendError(String message, Throwable cause) {
    super(message, cause);
  }
}
