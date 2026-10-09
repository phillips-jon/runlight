package sh.runlight;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.concurrent.atomic.AtomicLong;
import org.junit.jupiter.api.Test;

/** The tracker's per-address limit, counted in one-minute windows. */
class RateLimitTest {
  @Test
  void eachAddressHasItsOwnCountForTheMinute() {
    AtomicLong now = new AtomicLong(120_000);
    RateLimit limit = new RateLimit(2, now::get);
    assertTrue(limit.allow("203.0.113.9"));
    assertTrue(limit.allow("203.0.113.9"));
    assertFalse(limit.allow("203.0.113.9"));
    assertTrue(limit.allow("203.0.113.10"), "another address counts on its own");
    now.set(179_999);
    assertFalse(limit.allow("203.0.113.9"), "the same minute");
    now.set(180_000);
    assertTrue(limit.allow("203.0.113.9"), "a new minute starts over");
  }

  @Test
  void noAddressIsNeverLimited() {
    RateLimit limit = new RateLimit(0, () -> 0);
    assertTrue(limit.allow(""));
    assertFalse(limit.allow("192.0.2.1"));
  }
}
