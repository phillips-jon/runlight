package sh.runlight.db;

import java.util.List;
import java.util.Map;
import java.util.function.Function;

/**
 * The little a store needs from a database. SQL uses {@code ?} placeholders on every dialect. Rows
 * come back as maps keyed by column name, numbers as {@link Long} or {@link Double} and text as
 * {@link String}, so the store reads them as the TypeScript does.
 */
public interface Db extends AutoCloseable {
  /** "sqlite", "postgres", or "mysql". */
  String dialect();

  List<Map<String, Object>> all(String sql, List<?> params);

  default List<Map<String, Object>> all(String sql) {
    return all(sql, List.of());
  }

  void run(String sql, List<?> params);

  default void run(String sql) {
    run(sql, List.of());
  }

  /**
   * Runs an UPDATE or DELETE and says how many rows it matched. The store asks this of MySQL, which
   * has no RETURNING.
   */
  long affected(String sql, List<?> params);

  /**
   * Runs {@code fn} in one transaction, committed when it returns and rolled back when it throws. A
   * transaction already open on this thread is joined, not nested.
   */
  <T> T transaction(Function<Db, T> fn);

  /**
   * Runs {@code fn} while holding a database-wide lock, so two processes starting at once do not
   * race to create the same tables.
   */
  <T> T exclusive(Function<Db, T> fn);

  /** True for a database reached one statement at a time with a cap per request. */
  default boolean metered() {
    return false;
  }

  @Override
  void close();
}
