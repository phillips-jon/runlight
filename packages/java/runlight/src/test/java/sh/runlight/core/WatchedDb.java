package sh.runlight.core;

import java.util.List;
import java.util.Map;
import java.util.function.Consumer;
import java.util.function.Function;
import sh.runlight.db.Db;

/** A Db that lets a test step into every statement, as the TS tests replace db.run. */
public final class WatchedDb implements Db {
  private final Db inner;

  /** Called with each statement before it runs; it may throw to refuse it. */
  public volatile Consumer<String> before;

  public WatchedDb(Db inner) {
    this.inner = inner;
  }

  private void watch(String sql) {
    Consumer<String> fn = before;
    if (fn != null) {
      fn.accept(sql);
    }
  }

  @Override
  public String dialect() {
    return inner.dialect();
  }

  @Override
  public List<Map<String, Object>> all(String sql, List<?> params) {
    watch(sql);
    return inner.all(sql, params);
  }

  @Override
  public void run(String sql, List<?> params) {
    watch(sql);
    inner.run(sql, params);
  }

  @Override
  public long affected(String sql, List<?> params) {
    watch(sql);
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
