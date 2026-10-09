package sh.runlight;

import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * The SDK's version and the HTTP API's, the dashboard's and tracker's files, and the Runlight icon,
 * read from the assets scripts/java-assets.mts copies from the TypeScript SDK, so the two always
 * serve and report the same.
 */
public final class Version {
  private Version() {}

  private static final Map<String, byte[]> FILES = new ConcurrentHashMap<>();
  private static volatile Map<String, Object> build;

  /** Everything in assets/build.json: the versions, the asset hashes, and the icon. */
  public static Map<String, Object> build() {
    Map<String, Object> current = build;
    if (current == null) {
      current = Js.map(Json.parse(asset("build.json")));
      build = current;
    }
    return current;
  }

  public static String version() {
    return (String) build().get("version");
  }

  /** Bumped when the HTTP API changes shape, so the dashboard and the hub can tell. */
  public static long apiVersion() {
    return Js.asLong(build().get("apiVersion"));
  }

  /** The Runlight mark for the dashboard's tab, as a data URL. */
  public static String runlightIcon() {
    return (String) build().get("icon");
  }

  /** One of the assets as text. */
  public static String asset(String name) {
    return new String(assetBytes(name), StandardCharsets.UTF_8);
  }

  /** One of the assets as bytes, read once. */
  public static byte[] assetBytes(String name) {
    return FILES.computeIfAbsent(
        name,
        key -> {
          try (InputStream in = Version.class.getResourceAsStream("assets/" + key)) {
            if (in == null) {
              throw new IllegalStateException(
                  "Runlight: the asset " + key + " is missing; run scripts/java-assets.mts.");
            }
            return in.readAllBytes();
          } catch (IOException e) {
            throw new UncheckedIOException(e);
          }
        });
  }
}
