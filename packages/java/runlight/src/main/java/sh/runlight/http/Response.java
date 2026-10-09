package sh.runlight.http;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.io.UncheckedIOException;
import sh.runlight.Js;
import sh.runlight.Json;

/**
 * An answer, shaped like the Fetch API's Response. The body is bytes, or a writer that streams its
 * parts for answers too long to hold at once.
 */
public final class Response {
  /** Writes a streamed body. */
  @FunctionalInterface
  public interface BodyWriter {
    void write(OutputStream out) throws IOException;
  }

  private byte[] body;
  private final BodyWriter writer;
  private final int status;
  private final Headers headers;

  public Response(byte[] body, int status, Headers headers) {
    this.body = body == null ? new byte[0] : body;
    this.writer = null;
    this.status = status;
    this.headers = headers == null ? new Headers() : headers;
  }

  public Response(String body, int status, Headers headers) {
    this(body == null ? new byte[0] : Js.utf8(body), status, headers);
  }

  public Response(String body, int status) {
    this(body, status, new Headers());
  }

  /** A streamed answer. */
  public Response(BodyWriter writer, int status, Headers headers) {
    this.body = null;
    this.writer = writer;
    this.status = status;
    this.headers = headers == null ? new Headers() : headers;
  }

  /** Response.json(data, { status }): the JSON text with an application/json type. */
  public static Response json(Object data, int status) {
    return new Response(
        Json.stringify(data), status, Headers.of("content-type", "application/json"));
  }

  public static Response json(Object data) {
    return json(data, 200);
  }

  public static Response redirect(String location, int status) {
    return new Response(new byte[0], status, Headers.of("location", location));
  }

  public int status() {
    return status;
  }

  public Headers headers() {
    return headers;
  }

  public boolean ok() {
    return status >= 200 && status < 300;
  }

  /** Whether the body is written as it is sent. */
  public boolean streamed() {
    return body == null;
  }

  /** The whole body; a streamed body is run and captured. */
  public byte[] bytes() {
    if (body == null) {
      ByteArrayOutputStream out = new ByteArrayOutputStream();
      try {
        writer.write(out);
      } catch (IOException e) {
        throw new UncheckedIOException(e);
      }
      body = out.toByteArray();
    }
    return body;
  }

  public String text() {
    return Js.decodeUtf8(bytes());
  }

  /** The body as JSON; throws {@link Json.JsonException} when it is not. */
  public Object json() {
    return Json.parse(text());
  }

  /** Writes the body to a server's stream. */
  public void writeTo(OutputStream out) throws IOException {
    if (body != null) {
      out.write(body);
    } else {
      writer.write(out);
    }
  }

  @Override
  public String toString() {
    return "Response[" + status + "]";
  }
}
