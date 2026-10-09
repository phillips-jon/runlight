package sh.runlight;

import static org.junit.jupiter.api.Assertions.assertEquals;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * The language-neutral fixtures the TypeScript SDK writes, read where they live: conformance/ and
 * the PHP port's tests/fixtures, which every port shares.
 */
public final class Fixtures {
  private Fixtures() {}

  private static final Map<String, Object> LOADED = new ConcurrentHashMap<>();

  /** The repository's root. */
  public static Path repo() {
    String root = System.getProperty("runlight.repo");
    if (root == null) {
      root = "../../..";
    }
    return Path.of(root).toAbsolutePath().normalize();
  }

  /** A fixture from packages/php/tests/fixtures. */
  public static Map<String, Object> load(String name) {
    return Js.map(
        LOADED.computeIfAbsent(
            name,
            key ->
                Json.parse(read(repo().resolve("packages/php/tests/fixtures/" + key + ".json")))));
  }

  /** A file from conformance/. */
  public static Map<String, Object> conformance(String name) {
    return Js.map(
        LOADED.computeIfAbsent(
            "conformance/" + name, key -> Json.parse(read(repo().resolve(key + ".json")))));
  }

  public static String read(Path file) {
    try {
      return Files.readString(file, StandardCharsets.UTF_8);
    } catch (IOException e) {
      throw new UncheckedIOException(e);
    }
  }

  /** A list field of a fixture, its items as objects. */
  @SuppressWarnings("unchecked")
  public static List<Map<String, Object>> cases(Map<String, Object> fixture, String key) {
    return (List<Map<String, Object>>) (List<?>) Js.list(fixture.get(key));
  }

  /** A short label for a case, for messages. */
  public static String label(Object value) {
    String text = Json.stringify(value);
    return text.length() > 160 ? text.substring(0, 160) + "..." : text;
  }

  /** Asserts two values write the same JSON, so key order and number forms count too. */
  public static void assertJson(Object expected, Object actual, String message) {
    assertEquals(Json.stringify(expected), Json.stringify(stored(actual)), message);
  }

  /**
   * A value as the fixtures hold it: each lone surrogate as U+FFFD, as the TypeScript wrote it once
   * the text went out as UTF-8.
   */
  public static Object stored(Object value) {
    if (value instanceof String s) {
      return Js.wellFormed(s);
    }
    if (value instanceof Map<?, ?> map) {
      Map<String, Object> out = new java.util.LinkedHashMap<>();
      for (Map.Entry<?, ?> e : map.entrySet()) {
        out.put(Js.wellFormed(String.valueOf(e.getKey())), stored(e.getValue()));
      }
      return out;
    }
    if (value instanceof List<?> list) {
      List<Object> out = new java.util.ArrayList<>();
      for (Object item : list) {
        out.add(stored(item));
      }
      return out;
    }
    return value;
  }

  public static void assertJson(Object expected, Object actual) {
    assertJson(expected, actual, null);
  }
}
