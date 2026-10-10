package sh.runlight.importers;

import java.util.ArrayList;
import java.util.List;
import java.util.function.BiFunction;
import java.util.function.Function;
import java.util.regex.Pattern;
import sh.runlight.Json;
import sh.runlight.http.FetchInit;
import sh.runlight.http.Fetcher;
import sh.runlight.http.Headers;
import sh.runlight.http.Response;
import sh.runlight.http.Url;

/**
 * A Fetcher that answers from a table of URL patterns, recording what was asked, as the TS tests'
 * serve() replaces globalThis.fetch. Each answer is a body to send as JSON, or a {@link Status}.
 */
public final class FakeService implements Fetcher {
  /** An answer with a status other than 200. */
  public record Status(int status, Object body) {}

  /** One request as it was sent. */
  public record Sent(String url, FetchInit init) {}

  private record Route(Pattern pattern, BiFunction<Url, FetchInit, Object> answer) {}

  private final List<Route> routes = new ArrayList<>();

  /** "METHOD host/path" of each request. */
  public final List<String> calls = new ArrayList<>();

  public final List<Sent> requests = new ArrayList<>();

  /** Answers URLs the pattern finds with what the function returns. */
  public FakeService route(String pattern, BiFunction<Url, FetchInit, Object> answer) {
    routes.add(new Route(Pattern.compile(pattern), answer));
    return this;
  }

  /** Answers URLs the pattern finds with this body. */
  public FakeService route(String pattern, Object body) {
    return route(pattern, (u, init) -> body);
  }

  /** Stands in for DNS: every service is on the public internet unless a test says otherwise. */
  public Function<String, List<String>> dns = name -> List.of("93.184.215.14");

  @Override
  public List<String> lookup(String name) {
    return dns.apply(name);
  }

  @Override
  public Response fetch(String url, FetchInit init) {
    Url u = new Url(url);
    calls.add(init.method + " " + u.host() + u.pathname);
    requests.add(new Sent(url, init));
    for (Route route : routes) {
      if (route.pattern().matcher(u.href()).find()) {
        Object result = route.answer().apply(u, init);
        int status = 200;
        if (result instanceof Status s) {
          status = s.status();
          result = s.body();
        }
        return new Response(
            Json.stringify(result), status, Headers.of("content-type", "application/json"));
      }
    }
    return new Response("{}", 404);
  }

  /** The authorization header a request carried. */
  public static String authorization(FetchInit init) {
    return init.headers.get("authorization");
  }
}
