package sh.runlight.http;

import java.util.Locale;
import sh.runlight.Js;
import sh.runlight.Json;

/**
 * An incoming request, shaped like the Fetch API's Request so the routes read the same as the
 * TypeScript SDK's: an absolute URL, a method, headers, and a body read as text or JSON.
 */
public final class Request {
  private final String url;
  private final String method;
  private final Headers headers;
  private final byte[] body;
  private final String remoteAddress;

  public Request(String url) {
    this(url, "GET", new Headers(), new byte[0], "");
  }

  /**
   * A request.
   *
   * @param remoteAddress the address the request came from, before any proxy header is read
   */
  public Request(String url, String method, Headers headers, byte[] body, String remoteAddress) {
    this.url = url;
    this.method = method.toUpperCase(Locale.ROOT);
    this.headers = new Headers(headers);
    this.body = body == null ? new byte[0] : body;
    this.remoteAddress = remoteAddress == null ? "" : remoteAddress;
  }

  /** A request with a text body. */
  public Request(String url, String method, Headers headers, String body) {
    this(url, method, headers, body == null ? new byte[0] : Js.utf8(body), "");
  }

  public String url() {
    return url;
  }

  public String method() {
    return method;
  }

  public Headers headers() {
    return headers;
  }

  /** The address the request came from, before any proxy header is read. */
  public String remoteAddress() {
    return remoteAddress;
  }

  public byte[] bytes() {
    return body;
  }

  public String text() {
    return Js.decodeUtf8(body);
  }

  /** The body as JSON; throws {@link Json.JsonException} when it is not. */
  public Object json() {
    return Json.parse(text());
  }

  public Url parsedUrl() {
    return new Url(url);
  }

  /** The same request at another URL. */
  public Request withUrl(String other) {
    return new Request(other, method, headers, body, remoteAddress);
  }

  /** The same request with other headers. */
  public Request withHeaders(Headers other) {
    return new Request(url, method, other, body, remoteAddress);
  }

  /** The same request with another body. */
  public Request withBody(byte[] other) {
    return new Request(url, method, headers, other, remoteAddress);
  }

  /** The same request from another address. */
  public Request withRemoteAddress(String other) {
    return new Request(url, method, headers, body, other);
  }

  @Override
  public String toString() {
    return "Request[" + method + "]";
  }
}
