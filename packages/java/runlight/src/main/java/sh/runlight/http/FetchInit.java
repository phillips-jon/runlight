package sh.runlight.http;

import java.util.ArrayList;
import java.util.List;
import sh.runlight.Js;

/**
 * What fetch's init takes, where it applies, plus the limits the SDK reads a body with: a method
 * (GET), headers, a body, "manual" redirects that hand back the 3xx answer, a whole-request timeout
 * (30 seconds), a byte cap that throws {@link BodyTooLong} or, with truncate, hands back the first
 * bytes, and "host:port:address" pins so a checked address is the one connected to.
 */
public final class FetchInit {
  public String method = "GET";
  public Headers headers = new Headers();
  public byte[] body;
  public String redirect = "follow";
  public long timeoutMs = 30_000;
  public Long maxBytes;
  public boolean truncate;
  public List<String> resolve = new ArrayList<>();

  public FetchInit method(String value) {
    method = value;
    return this;
  }

  public FetchInit header(String name, String value) {
    headers.set(name, value);
    return this;
  }

  public FetchInit headers(Headers value) {
    headers = new Headers(value);
    return this;
  }

  public FetchInit body(String value) {
    body = value == null ? null : Js.utf8(value);
    return this;
  }

  public FetchInit body(byte[] value) {
    body = value;
    return this;
  }

  public FetchInit redirect(String value) {
    redirect = value;
    return this;
  }

  public FetchInit timeoutMs(long value) {
    timeoutMs = value;
    return this;
  }

  public FetchInit maxBytes(long value) {
    maxBytes = value;
    return this;
  }

  public FetchInit truncate(boolean value) {
    truncate = value;
    return this;
  }

  public FetchInit resolve(String pin) {
    resolve.add(pin);
    return this;
  }

  /** The body as text, for fakes and logs. */
  public String bodyText() {
    return body == null ? null : Js.decodeUtf8(body);
  }

  @Override
  public String toString() {
    return "FetchInit[" + method + "]";
  }
}
