package sh.runlight;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import sh.runlight.http.Headers;
import sh.runlight.http.Response;

/** A site's icon: the links picked as TypeScript picks them, and the fetches with their caps. */
class IconTest {
  @BeforeEach
  void forget() {
    Icon.clearCache();
  }

  @Test
  void iconLinksMatchTypeScript() {
    for (Map<String, Object> c : Fixtures.cases(Fixtures.load("outbound"), "icons")) {
      assertEquals(
          c.get("links"),
          Icon.iconLinks((String) c.get("html"), (String) c.get("base")),
          (String) c.get("html"));
    }
  }

  @Test
  void theBestLinkedIconIsFetchedWithItsCaps() {
    // An address as the origin, so no name is looked up.
    String origin = "https://93.184.215.14";
    RecordingFetcher fetcher =
        new RecordingFetcher(
            (url, init) ->
                switch (url) {
                  case "https://93.184.215.14/" ->
                      new Response(
                          "<link rel=\"apple-touch-icon\" href=\"/touch.png\"><link rel=\"icon\""
                              + " href=\"/i.svg\">",
                          200,
                          Headers.of("content-type", "text/html; charset=utf-8"));
                  case "https://93.184.215.14/touch.png" ->
                      new Response("<html>", 200, Headers.of("content-type", "text/html"));
                  case "https://93.184.215.14/i.svg" ->
                      new Response(
                          "<svg/>",
                          200,
                          Headers.of("content-type", "Image/SVG+xml; charset=utf-8"));
                  default -> new Response("", 404);
                });
    long now = 1_791_471_600_000L;
    Map<String, Object> icon = Icon.fetchIcon(origin, now, fetcher);
    assertArrayEquals("<svg/>".getBytes(StandardCharsets.UTF_8), (byte[]) icon.get("body"));
    assertEquals("image/svg+xml", icon.get("type"));
    assertEquals(
        List.of(
            "https://93.184.215.14/",
            "https://93.184.215.14/touch.png",
            "https://93.184.215.14/i.svg"),
        fetcher.urls());
    assertEquals(200_000L, fetcher.inits.get(0).maxBytes);
    assertTrue(fetcher.inits.get(0).truncate);
    assertEquals(262_144L, fetcher.inits.get(1).maxBytes);
    assertFalse(fetcher.inits.get(1).truncate, "an image must arrive whole");
    assertEquals("Runlight (+https://runlight.sh)", fetcher.inits.get(0).headers.get("user-agent"));
    assertTrue(fetcher.inits.get(0).timeoutMs <= 4000);

    // Cached for a day.
    assertSame(icon, Icon.fetchIcon(origin, now + 86_399_000L, fetcher));
    assertEquals(3, fetcher.requests.size());
    Icon.fetchIcon(origin, now + 86_400_000L, fetcher);
    assertEquals(6, fetcher.requests.size(), "and looked up again after it");
  }

  @Test
  void faviconIsTheFallbackAndNoIconIsRememberedForAnHour() {
    String origin = "https://1.1.1.1";
    RecordingFetcher fetcher =
        new RecordingFetcher(
            (url, init) ->
                url.equals("https://1.1.1.1/favicon.ico")
                    ? new Response("", 200, Headers.of("content-type", "image/x-icon"))
                    : new Response("nope", 500));
    long now = 1_791_471_600_000L;
    assertNull(Icon.fetchIcon(origin, now, fetcher), "an empty image is no icon");
    assertEquals(List.of("https://1.1.1.1/", "https://1.1.1.1/favicon.ico"), fetcher.urls());
    assertNull(Icon.fetchIcon(origin, now + 3_599_000L, fetcher));
    assertEquals(2, fetcher.requests.size());
    Icon.fetchIcon(origin, now + 3_600_000L, fetcher);
    assertEquals(4, fetcher.requests.size());
  }

  @Test
  void aPrivateOriginIsNeverFetched() {
    RecordingFetcher fetcher =
        new RecordingFetcher(
            (url, init) -> new Response("x", 200, Headers.of("content-type", "image/png")));
    assertNull(Icon.fetchIcon("https://192.168.1.1", 0, fetcher));
    assertEquals(List.of(), fetcher.requests);
  }
}
