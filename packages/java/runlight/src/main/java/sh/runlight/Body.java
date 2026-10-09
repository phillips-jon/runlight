package sh.runlight;

import sh.runlight.http.BodyTooLong;
import sh.runlight.http.Response;

/**
 * Capped reads of an answer's body. In Java the cap belongs on the request: pass {@code maxBytes}
 * to the Fetcher, which stops reading past it and throws BodyTooLong, so an install or a page that
 * answers without end never fills memory. These check the same limit again on an answer already
 * read, for a Fetcher that does not take the option, and decode the text as TextDecoder does.
 */
public final class Body {
  private Body() {}

  /** The body as text, up to maxBytes; past that, {@link BodyTooLong}. */
  public static String readTextCapped(Response response, long maxBytes) {
    double declared = Js.toNumber(response.headers().get("content-length"));
    if (declared > maxBytes) {
      throw new BodyTooLong("Body over " + maxBytes + " bytes");
    }
    byte[] bytes = response.bytes();
    if (bytes.length > maxBytes) {
      throw new BodyTooLong("Body over " + maxBytes + " bytes");
    }
    return Js.decodeUtf8(bytes);
  }

  /**
   * The body as JSON, up to maxBytes, as readTextCapped reads it. Throws {@link
   * sh.runlight.Json.JsonException} when it is not JSON.
   */
  public static Object readJsonCapped(Response response, long maxBytes) {
    return Json.parse(readTextCapped(response, maxBytes));
  }
}
