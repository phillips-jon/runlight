package sh.runlight.mail;

import java.util.Map;
import sh.runlight.CodedError;
import sh.runlight.Json;

/**
 * A mail problem to show the person setting it up. {@code code} and {@code params} let the
 * dashboard say it in its own language; a service's own words, which only it can give, travel in
 * {@code params.detail}.
 */
public final class MailError extends CodedError {
  private static final long serialVersionUID = 1L;

  /** A mail_failed error whose params are {@code { detail: message }}, as the TS default. */
  public MailError(String message) {
    this(message, "mail_failed");
  }

  /** An error whose params are {@code { detail: message }}, as the TS default. */
  public MailError(String message, String code) {
    super(message, code, Json.object("detail", message));
  }

  public MailError(String message, String code, Map<String, Object> params) {
    super(message, code, params);
  }
}
