package sh.runlight;

import java.util.Map;

/**
 * What went wrong with the assistant, as a code the dashboard says in its own words; a service's
 * own text goes in {@code params().get("detail")}.
 */
public final class AssistantError extends CodedError {
  private static final long serialVersionUID = 1L;

  public AssistantError(String message, String code) {
    super(message, code);
  }

  public AssistantError(String message, String code, Map<String, Object> params) {
    super(message, code, params);
  }
}
