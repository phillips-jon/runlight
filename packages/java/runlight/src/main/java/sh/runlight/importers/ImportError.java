package sh.runlight.importers;

import java.util.Map;
import sh.runlight.CodedError;

/** Why an import stopped, as a code the dashboard says in its own words. */
public class ImportError extends CodedError {
  private static final long serialVersionUID = 1L;

  public ImportError(String message, String code) {
    super(message, code);
  }

  public ImportError(String message, String code, Map<String, Object> params) {
    super(message, code, params);
  }
}
