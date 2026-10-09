package sh.runlight;

/**
 * A JSON-RPC error with its own code, such as -32602 for an unknown tool, answered with its message
 * as it is.
 */
public final class McpError extends RuntimeException {
  private static final long serialVersionUID = 1L;

  private final int code;

  public McpError(String message, int code) {
    super(message);
    this.code = code;
  }

  public int code() {
    return code;
  }
}
