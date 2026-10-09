package sh.runlight;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import org.junit.jupiter.api.Test;
import sh.runlight.http.BodyTooLong;
import sh.runlight.http.Headers;
import sh.runlight.http.Response;

/** Capped reads: Body's checks. The Fetcher's own caps are in http/JdkFetcherTest. */
class BodyTest {
  @Test
  void textIsReadUpToTheCap() {
    assertEquals("hello", Body.readTextCapped(new Response("hello", 200), 5));
    assertEquals(Json.object("a", 1L), Body.readJsonCapped(new Response("{\"a\":1}", 200), 100));
    assertEquals(
        "a�b",
        Body.readTextCapped(new Response(new byte[] {'a', (byte) 0xff, 'b'}, 200, null), 10),
        "as TextDecoder reads bytes that are not UTF-8");
    assertEquals(
        "x",
        Body.readTextCapped(
            new Response(new byte[] {(byte) 0xEF, (byte) 0xBB, (byte) 0xBF, 'x'}, 200, null), 10));
    BodyTooLong error =
        assertThrows(BodyTooLong.class, () -> Body.readTextCapped(new Response("hello", 200), 4));
    assertEquals("Body over 4 bytes", error.getMessage());
  }

  @Test
  void aDeclaredLengthOverTheCapIsRefusedUnread() {
    assertThrows(
        BodyTooLong.class,
        () -> Body.readTextCapped(new Response("", 200, Headers.of("content-length", "1000")), 10));
    // A length that is not a number is no length, as Number() reads it.
    assertEquals(
        "ok",
        Body.readTextCapped(new Response("ok", 200, Headers.of("content-length", "lots")), 10));
  }

  @Test
  void envAndBrandReadAsTheSdkDoes() {
    Env.override("RUNLIGHT_TEST_ENV", "  value \n");
    Env.override("RUNLIGHT_TEST_EMPTY", "   ");
    Env.override("PATH", null);
    try {
      assertEquals("value", Env.get("RUNLIGHT_TEST_ENV"));
      assertEquals(null, Env.get("RUNLIGHT_TEST_EMPTY"));
      assertEquals(null, Env.get("PATH"));
      assertEquals(null, Env.get("RUNLIGHT_TEST_NEVER_SET"));
    } finally {
      Env.reset();
    }
    org.junit.jupiter.api.Assertions.assertTrue(
        Brand.runlightIcon().startsWith("data:image/svg+xml,"));
  }
}
