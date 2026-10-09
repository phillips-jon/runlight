package sh.runlight.accounts;

import java.util.Map;
import sh.runlight.CodedError;

/**
 * A problem with an account change, to show the person making it. A RangeError in TypeScript, with
 * a {@code code} and {@code params} the dashboard words in its own language.
 */
public final class AccountError extends CodedError {
  private static final long serialVersionUID = 1L;

  public AccountError(String message, String code) {
    super(message, code);
  }

  public AccountError(String message, String code, Map<String, Object> params) {
    super(message, code, params);
  }
}
