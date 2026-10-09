package sh.runlight.conformance;

import static org.junit.jupiter.api.Assertions.assertEquals;

import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.stream.Stream;
import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.TestFactory;
import sh.runlight.Fixtures;
import sh.runlight.Hash;
import sh.runlight.Js;
import sh.runlight.db.Connect;
import sh.runlight.db.Db;
import sh.runlight.store.Databases;
import sh.runlight.store.SqlStore;
import sh.runlight.store.Stores;

/**
 * Replays conformance/http.json against the Java core on every store, as http-conformance.test.ts
 * does against the TypeScript one: each step's answer must equal the one the file holds.
 */
final class ConformanceTest {
  @TestFactory
  Stream<DynamicTest> scenarios() {
    List<DynamicTest> tests = new ArrayList<>();
    for (String kind : Databases.kinds()) {
      for (Object item : Js.list(Fixtures.conformance("http").get("scenarios"))) {
        Map<String, Object> scenario = Js.map(item);
        tests.add(
            DynamicTest.dynamicTest(
                kind + ": " + scenario.get("name"), () -> play(kind, scenario)));
      }
    }
    return tests.stream();
  }

  private static void play(String kind, Map<String, Object> scenario) {
    List<Runnable> cleanups = new ArrayList<>();
    try {
      SqlStore store = Stores.fromDb(db(kind, cleanups));
      List<Object> answers = new Player().play(scenario, store);
      assertAnswers(scenario, answers, kind);
    } finally {
      for (int i = cleanups.size() - 1; i >= 0; i--) {
        try {
          cleanups.get(i).run();
        } catch (RuntimeException e) {
          System.err.println("Runlight conformance: could not drop a test database: " + e);
        }
      }
    }
  }

  /** A fresh, empty database of a kind, dropped by the cleanups. */
  private static Db db(String kind, List<Runnable> cleanups) {
    String name = "rl_conf_" + HexFormat.of().formatHex(Hash.randomBytes(5));
    if (kind.equals("sqlite")) {
      return Connect.sqlite(":memory:");
    }
    if (kind.equals("postgres")) {
      Db admin = Connect.postgres(Databases.pgUrl(), 0, null);
      admin.run("CREATE SCHEMA \"" + name + "\"");
      Db db = Connect.postgres(Databases.pgUrl(), 120_000, name);
      cleanups.add(
          () -> {
            db.close();
            admin.run("DROP SCHEMA IF EXISTS \"" + name + "\" CASCADE");
            admin.close();
          });
      return db;
    }
    String url = Databases.mysqlUrls().get(kind);
    Db admin = Connect.mysql(url, 0);
    admin.run("CREATE DATABASE `" + name + "`");
    Db db = Connect.mysql(url.replaceFirst("^([a-z]+://[^/?#]*)(/[^?#]*)?", "$1/" + name), 0);
    cleanups.add(
        () -> {
          db.close();
          admin.run("DROP DATABASE IF EXISTS `" + name + "`");
          admin.close();
        });
    return db;
  }

  /**
   * Compares answer by answer and fails on the first that differs, with the scenario, step, method,
   * and path it belongs to.
   */
  static void assertAnswers(Map<String, Object> scenario, List<Object> answers, String kind) {
    List<Object> steps = Js.list(scenario.get("steps"));
    assertEquals(
        steps.size(),
        answers.size(),
        scenario.get("name") + " (" + kind + "): one answer for each step");
    List<Integer> differ = new ArrayList<>();
    for (int i = 0; i < steps.size(); i++) {
      Object expect = Js.map(steps.get(i)).get("expect");
      if (!Normalizer.canonical(expect).equals(Normalizer.canonical(answers.get(i)))) {
        differ.add(i);
      }
    }
    if (differ.isEmpty()) {
      return;
    }
    int i = differ.get(0);
    Map<String, Object> step = Js.map(steps.get(i));
    List<String> others = new ArrayList<>();
    for (int n : differ.subList(1, differ.size())) {
      others.add(String.valueOf(n + 1));
    }
    assertEquals(
        Normalizer.canonical(step.get("expect")),
        Normalizer.canonical(answers.get(i)),
        String.format(
            "%s (%s): step %d, %s %s answered differently.%s",
            scenario.get("name"),
            kind,
            i + 1,
            step.get("method"),
            step.get("path"),
            others.isEmpty() ? "" : " Steps " + String.join(", ", others) + " differ too."));
  }
}
