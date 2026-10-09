package sh.runlight.store;

import java.util.List;
import java.util.Map;
import java.util.function.BiConsumer;
import java.util.function.Function;
import sh.runlight.db.Db;

/**
 * A Db that lets a test see, and step into, every statement: as the TypeScript tests replace db.run
 * and db.all on a store. Statements inside a transaction or lock go through it too.
 */
final class WatchedDb implements Db {
  /** Called before each statement. */
  volatile BiConsumer<String, List<?>> before;

  /** Called after each run(). */
  volatile BiConsumer<String, List<?>> afterRun;

  final Db inner;

  WatchedDb(Db inner) {
    this.inner = inner;
  }

  @Override
  public String dialect() {
    return inner.dialect();
  }

  private void before(String sql, List<?> params) {
    BiConsumer<String, List<?>> fn = before;
    if (fn != null) {
      fn.accept(sql, params);
    }
  }

  @Override
  public List<Map<String, Object>> all(String sql, List<?> params) {
    before(sql, params);
    return inner.all(sql, params);
  }

  @Override
  public void run(String sql, List<?> params) {
    before(sql, params);
    inner.run(sql, params);
    BiConsumer<String, List<?>> fn = afterRun;
    if (fn != null) {
      fn.accept(sql, params);
    }
  }

  @Override
  public long affected(String sql, List<?> params) {
    before(sql, params);
    return inner.affected(sql, params);
  }

  @Override
  public <T> T transaction(Function<Db, T> fn) {
    return inner.transaction(d -> fn.apply(this));
  }

  @Override
  public <T> T exclusive(Function<Db, T> fn) {
    return inner.exclusive(d -> fn.apply(this));
  }

  @Override
  public boolean metered() {
    return inner.metered();
  }

  @Override
  public void close() {
    inner.close();
  }
}
