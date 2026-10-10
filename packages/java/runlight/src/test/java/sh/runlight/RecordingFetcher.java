package sh.runlight;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.List;
import java.util.Map;
import java.util.function.BiFunction;
import java.util.function.Function;
import sh.runlight.http.FetchError;
import sh.runlight.http.FetchInit;
import sh.runlight.http.Fetcher;
import sh.runlight.http.Response;

/**
 * A Fetcher that records every request and answers from a queue or a function, so a test can
 * require the exact method, URL, headers, and body a service is sent.
 *
 * <p>Each request is recorded as the TypeScript fixtures record them: {@code method}, {@code url},
 * {@code headers} (lowercase names in name order, as iterating Fetch Headers gives them, repeated
 * values joined with ", "), and {@code body} (the text, or "" when there is none). The init each
 * came with is kept in {@link #inits}, for its timeout, redirect mode, caps, and pins.
 *
 * <p>A queue holds Responses, or the strings "timeout" and "network" to fail as a request that
 * timed out or could not connect does.
 */
public final class RecordingFetcher implements Fetcher {
  public final List<Map<String, Object>> requests = new ArrayList<>();
  public final List<FetchInit> inits = new ArrayList<>();

  private final Deque<Object> queue;
  private final BiFunction<String, FetchInit, Response> answer;

  /** Answers from a queue: Responses, "timeout", or "network". */
  public RecordingFetcher(Object... queue) {
    this.queue = new ArrayDeque<>(List.of(queue));
    this.answer = null;
  }

  /** Answers with a function of the URL and init. */
  public RecordingFetcher(BiFunction<String, FetchInit, Response> answer) {
    this.queue = null;
    this.answer = answer;
  }

  @Override
  public synchronized Response fetch(String url, FetchInit init) {
    Map<String, Object> headers = new java.util.LinkedHashMap<>();
    for (Map.Entry<String, String> entry : init.headers.entries()) {
      headers.put(entry.getKey(), entry.getValue());
    }
    String body = init.bodyText();
    requests.add(
        Json.object(
            "method",
            init.method,
            "url",
            url,
            "headers",
            headers,
            "body",
            body == null ? "" : body));
    inits.add(init);
    if (answer != null) {
      return answer.apply(url, init);
    }
    Object next = queue.poll();
    if (next == null) {
      throw new IllegalStateException("No canned answer left");
    }
    if ("timeout".equals(next)) {
      throw new FetchError("The operation timed out", true, null);
    }
    if ("network".equals(next)) {
      throw new FetchError("Could not connect");
    }
    return (Response) next;
  }

  /** Stands in for DNS: every name is a public address unless a test says otherwise. */
  public Function<String, List<String>> dns = name -> List.of("93.184.215.14");

  @Override
  public List<String> lookup(String name) {
    return dns.apply(name);
  }

  /** The URLs requested, in order. */
  public synchronized List<String> urls() {
    List<String> out = new ArrayList<>();
    for (Map<String, Object> request : requests) {
      out.add((String) request.get("url"));
    }
    return out;
  }
}
