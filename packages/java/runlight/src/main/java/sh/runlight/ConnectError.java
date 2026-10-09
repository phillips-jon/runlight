package sh.runlight;

import java.util.Map;

/**
 * Why connecting failed, as a code the dashboard says in its own words. The first four ("expired",
 * "denied", "refused", "token") come back from the consent page, the rest ("url", "unreachable",
 * "not_runlight", "endpoints", "old", "register") from starting. The page it lands on is this
 * server's own, so it never shows text that came in the address.
 */
public final class ConnectError extends CodedError {
  private static final long serialVersionUID = 1L;

  public ConnectError(String message, String code) {
    super(message, code);
  }

  public ConnectError(String message, String code, Map<String, Object> params) {
    super(message, code, params);
  }
}
