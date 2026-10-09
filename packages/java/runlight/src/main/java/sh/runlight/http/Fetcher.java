package sh.runlight.http;

/**
 * Outgoing requests, the Java stand-in for JavaScript's fetch(). Everything that calls another
 * server (mail services, importers, connected installs, the assistant's providers, site icons) goes
 * through one, so tests can pass a fake.
 */
@FunctionalInterface
public interface Fetcher {
  /**
   * Sends the request and returns the answer.
   *
   * @throws FetchError when no answer comes back (refused, timed out, bad TLS)
   * @throws BodyTooLong when the answer is longer than {@link FetchInit#maxBytes} allows
   */
  Response fetch(String url, FetchInit init);

  /** A GET with nothing else set. */
  default Response fetch(String url) {
    return fetch(url, new FetchInit());
  }
}
