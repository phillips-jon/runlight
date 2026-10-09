package sh.runlight;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static sh.runlight.Fixtures.assertJson;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Base64;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import sh.runlight.http.Headers;

/** Location from platform headers and MMDB files, replayed from the TypeScript SDK and server. */
class GeoTest {
  private static Headers headers(Object map) {
    Headers headers = new Headers();
    for (Map.Entry<String, Object> e : Js.map(map).entrySet()) {
      headers.append(e.getKey(), (String) e.getValue());
    }
    return headers;
  }

  @Test
  void fromHeaders() {
    for (Map<String, Object> c : Fixtures.cases(Fixtures.load("geo"), "headers")) {
      assertJson(
          c.get("location"),
          Geo.locationFromHeaders(headers(c.get("headers"))),
          Fixtures.label(c.get("headers")));
    }
  }

  @Test
  void locate() {
    for (Map<String, Object> c : Fixtures.cases(Fixtures.load("geo"), "located")) {
      Geo.Lookup lookup =
          Boolean.TRUE.equals(c.get("noLookup"))
              ? null
              : ip -> {
                if (Boolean.TRUE.equals(c.get("throws"))) {
                  throw new IllegalStateException("broken");
                }
                return Js.map(c.get("found"));
              };
      assertJson(
          c.get("location"),
          Geo.locate(headers(c.get("headers")), (String) c.get("ip"), lookup),
          Fixtures.label(c));
    }
  }

  @Test
  void mmdb() throws Exception {
    for (Map<String, Object> db : Fixtures.cases(Fixtures.load("geo"), "databases")) {
      byte[] bytes = Base64.getDecoder().decode((String) db.get("base64"));
      Path file = Files.createTempFile("rl-mmdb", ".mmdb");
      try {
        Files.write(file, bytes);
        for (Mmdb reader : List.of(new Mmdb(bytes), Mmdb.open(file))) {
          assertEquals(
              Js.asLong(db.get("ipVersion")), Js.asLong(reader.metadata().get("ip_version")));
          assertEquals(
              Js.asLong(db.get("recordSize")), Js.asLong(reader.metadata().get("record_size")));
          assertEquals(1759708800L, Js.asLong(reader.metadata().get("build_epoch")));
          assertJson(Map.of("en", "A test database"), reader.metadata().get("description"));
          Geo.Lookup lookup = Geo.lookupFrom(reader::get);
          for (Map<String, Object> c : Fixtures.cases(db, "records")) {
            String label = db.get("ipVersion") + "/" + db.get("recordSize") + " " + c.get("ip");
            assertJson(c.get("record"), reader.get((String) c.get("ip")), label);
            assertJson(c.get("location"), lookup.lookup((String) c.get("ip")), label);
          }
        }
      } finally {
        Files.delete(file);
      }
    }
    assertThrows(RuntimeException.class, () -> Mmdb.open(Path.of("/no/such/runlight.mmdb")));
  }

  @Test
  void dbIpRecordsBecomeACountryCodeAReadableRegionAndAPlainCity() throws Exception {
    Map<String, Object> records = new HashMap<>();
    records.put(
        "24.114.0.1",
        Json.parse(
            "{\"country\":{\"iso_code\":\"CA\"},\"subdivisions\":[{\"names\":{\"en\":\"Ontario\"}}],\"city\":{\"names\":{\"en\":\"Toronto (Old Toronto)\"}}}"));
    records.put(
        "8.8.8.8",
        Json.parse(
            "{\"country\":{\"iso_code\":\"US\"},\"subdivisions\":[{\"iso_code\":\"CA\",\"names\":{\"en\":\"California\"}}],\"city\":{\"names\":{\"en\":\"Mountain View\"}}}"));
    Geo.Lookup lookup = Geo.lookupFrom(records::get);
    assertJson(
        Json.object("country", "CA", "region", "Ontario", "city", "Toronto"),
        lookup.lookup("24.114.0.1"));
    assertJson(
        Json.object("country", "US", "region", "CA", "city", "Mountain View"),
        lookup.lookup("8.8.8.8"));
    assertNull(lookup.lookup("10.0.0.1"));
    Geo.Lookup broken =
        Geo.lookupFrom(
            ip -> {
              throw new IOException("bad address");
            });
    assertNull(broken.lookup("nonsense"));
  }

  @Test
  void aRealDatabaseWhenOneIsGiven() {
    String file = System.getenv("RUNLIGHT_TEST_MMDB");
    if (file == null || file.isEmpty()) {
      return;
    }
    Mmdb reader = Mmdb.open(Path.of(file));
    assertNotNull(reader.get("8.8.8.8"));
    assertNull(reader.get("127.0.0.1"));
  }
}
