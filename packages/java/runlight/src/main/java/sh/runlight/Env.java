package sh.runlight;

import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Environment variables, trimmed, or null when one is empty or unset, as the TypeScript SDK's
 * envValue() reads process.env.
 */
public final class Env {
  private Env() {}

  /** Values tests put in place of the real environment, which Java cannot change. */
  private static final Map<String, Optional<String>> OVERRIDES = new ConcurrentHashMap<>();

  /** An environment variable, trimmed, or null when it is empty or unset. */
  public static String get(String name) {
    Optional<String> set = OVERRIDES.get(name);
    String value = set != null ? set.orElse(null) : System.getenv(name);
    if (value == null) {
      return null;
    }
    value = Js.trim(value);
    return value.isEmpty() ? null : value;
  }

  /**
   * Sets a variable for this process, in place of the real environment, for tests. A null value
   * reads as unset however the environment has it.
   */
  public static void override(String name, String value) {
    OVERRIDES.put(name, Optional.ofNullable(value));
  }

  /** Forgets every override, so the real environment is read again. */
  public static void reset() {
    OVERRIDES.clear();
  }
}
