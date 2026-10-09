package sh.runlight;

import java.util.Map;

/**
 * Why something was refused, as a code the dashboard says in its own words, with the values its
 * message names. The TypeScript's GoalError, FunnelError, LinkError, and the others are each a
 * subclass of this.
 */
public class CodedError extends RuntimeException {
  private static final long serialVersionUID = 1L;

  private final String code;
  private final transient Map<String, Object> params;

  public CodedError(String message, String code) {
    this(message, code, Map.of());
  }

  public CodedError(String message, String code, Map<String, Object> params) {
    super(message);
    this.code = code;
    this.params = params;
  }

  public String code() {
    return code;
  }

  public Map<String, Object> params() {
    return params;
  }

  /** Why a goal was refused. */
  public static final class GoalError extends CodedError {
    private static final long serialVersionUID = 1L;

    public GoalError(String message, String code) {
      super(message, code);
    }

    public GoalError(String message, String code, Map<String, Object> params) {
      super(message, code, params);
    }
  }

  /** Why a funnel was refused. */
  public static final class FunnelError extends CodedError {
    private static final long serialVersionUID = 1L;

    public FunnelError(String message, String code) {
      super(message, code);
    }

    public FunnelError(String message, String code, Map<String, Object> params) {
      super(message, code, params);
    }
  }

  /** Why a link was refused. */
  public static final class LinkError extends CodedError {
    private static final long serialVersionUID = 1L;

    public LinkError(String message, String code) {
      super(message, code);
    }

    public LinkError(String message, String code, Map<String, Object> params) {
      super(message, code, params);
    }
  }

  /** Why a settings change was refused. */
  public static final class SettingsError extends CodedError {
    private static final long serialVersionUID = 1L;

    public SettingsError(String message, String code) {
      super(message, code);
    }

    public SettingsError(String message, String code, Map<String, Object> params) {
      super(message, code, params);
    }
  }
}
