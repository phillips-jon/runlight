package sh.runlight.store;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import sh.runlight.Fixtures;

/** Runs scripts/php-fixtures-store.mts with the TypeScript SDK, when node is at hand. */
final class Node {
  private Node() {}

  /** What the script did: its exit status, what it wrote, and what it said on stderr. */
  record Result(int status, String out, String err) {}

  /**
   * node 22 or later on the PATH (or RUNLIGHT_NODE), with tsx installed at the repository root;
   * null when there is none.
   */
  static String binary() {
    if (!Files.isDirectory(Fixtures.repo().resolve("node_modules/tsx"))) {
      return null;
    }
    List<String> candidates = new ArrayList<>();
    String env = System.getenv("RUNLIGHT_NODE");
    if (env != null && !env.isEmpty()) {
      candidates.add(env);
    }
    candidates.add("node");
    for (String node : candidates) {
      try {
        Result r = run(List.of(node, "--version"));
        Matcher m = Pattern.compile("^v(\\d+)\\.").matcher(r.out().trim());
        if (r.status() == 0 && m.find() && Integer.parseInt(m.group(1)) >= 22) {
          return node;
        }
      } catch (IOException e) {
        // Not this one.
      }
    }
    return null;
  }

  /** The store script with these arguments. */
  static Result store(String node, String... args) throws IOException {
    List<String> command =
        new ArrayList<>(List.of(node, "--import", "tsx", "scripts/php-fixtures-store.mts"));
    command.addAll(List.of(args));
    return run(command);
  }

  private static Result run(List<String> command) throws IOException {
    Process process = new ProcessBuilder(command).directory(Fixtures.repo().toFile()).start();
    process.getOutputStream().close();
    byte[] err;
    byte[] out;
    try (var stderr = process.getErrorStream();
        var stdout = process.getInputStream()) {
      var errBytes = new java.io.ByteArrayOutputStream();
      Thread drain =
          new Thread(
              () -> {
                try {
                  stderr.transferTo(errBytes);
                } catch (IOException e) {
                  // The process ended.
                }
              });
      drain.start();
      out = stdout.readAllBytes();
      try {
        drain.join();
        process.waitFor(5, TimeUnit.MINUTES);
      } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
        throw new IOException(e);
      }
      err = errBytes.toByteArray();
    }
    return new Result(
        process.exitValue(),
        new String(out, StandardCharsets.UTF_8),
        new String(err, StandardCharsets.UTF_8));
  }
}
