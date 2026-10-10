package sh.runlight.http;

import java.util.List;
import sh.runlight.Safefetch;

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

  /**
   * Every address a name resolves to, for the fetches that check where they go before they send
   * anything ({@code Safefetch.publicFetch}). A fake can stand in for DNS here.
   */
  default List<String> lookup(String name) {
    return Safefetch.lookup(name);
  }

  /** A GET with nothing else set. */
  default Response fetch(String url) {
    return fetch(url, new FetchInit());
  }
}
