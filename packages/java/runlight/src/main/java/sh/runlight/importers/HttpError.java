package sh.runlight.importers;

import java.util.Map;

/** A service answered with a status that is not success. */
public final class HttpError extends ImportError {
  private static final long serialVersionUID = 1L;

  private final int status;

  public HttpError(String message, int status, String code) {
    this(message, status, code, Map.of());
  }

  public HttpError(String message, int status, String code, Map<String, Object> params) {
    super(message, code, params);
    this.status = status;
  }

  public int status() {
    return status;
  }
}
