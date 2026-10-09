package sh.runlight.routes;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import sh.runlight.Env;
import sh.runlight.Json;
import sh.runlight.Routes;
import sh.runlight.Runlight;
import sh.runlight.http.Response;

/**
 * The route-level part of hardening.test.ts: a link domain's check. The rest belongs to the core,
 * safefetch, and the stores.
 */
class HardeningTest {
  @BeforeEach
  void setUp() {
    Make.clearEnv();
  }

  @AfterEach
  void tearDown() {
    Env.reset();
  }

  @Test
  void aLinkDomainsCheckSaysWhereTheDomainShouldPointForItsSetupSteps() {
    Runlight rl =
        Make.runlight(
            new Runlight.Options()
                .site(Json.object("hostnames", List.of("example.com")))
                .fetcher((url, init) -> new Response("no", 404)));
    rl.init();
    rl.store.addLinkDomain("go.example.net", "default", 0);
    Map<String, Object> check =
        Make.body(
            rl.routes(new Routes.Options().token("secret"))
                .handle(Make.owner("/runlight/api/link-domains/go.example.net/check")));
    assertEquals(
        "example.com", Make.dig(check, "target.host"), "this dashboard's own name, for a CNAME");
    assertTrue(Make.dig(check, "target.addresses") instanceof List<?>);
    assertEquals(false, check.get("working"));
  }
}
