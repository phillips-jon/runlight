package sh.runlight.db;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Statement;
import java.sql.Types;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.locks.ReentrantLock;
import java.util.function.Function;
import java.util.logging.Level;
import java.util.logging.Logger;
import java.util.regex.Pattern;
import javax.sql.DataSource;
import sh.runlight.Js;
import sh.runlight.Json;

/**
 * A Db over JDBC, for SQLite, Postgres, and MySQL or MariaDB, doing per connection what the
 * TypeScript drivers do (stores/sqlite.ts, stores/postgres.ts, and stores/mysql.ts).
 *
 * <p>Connections come from the app's {@link DataSource} (its pool), or from a small pool of its own
 * when the store was made from a URL. A transaction or a lock holds one connection on its thread
 * until it ends. SQLite keeps one connection, which every thread takes in turn, since its file lock
 * serialises writers anyway and an in-memory database lives only as long as its connection.
 *
 * <p>SQL is written for SQLite and Postgres. On MySQL each statement goes through {@link
 * #mysqlText} first, as the TypeScript driver sends it: a "quoted" name in backticks, and a
 * backslash inside 'text' doubled, since MySQL reads it as an escape where standard SQL takes it
 * literally.
 */
public final class JdbcDb implements Db {
  private static final Logger LOG = Logger.getLogger("sh.runlight");

  /** Arbitrary but fixed, so every Runlight process takes the same lock to create tables. */
  public static final long MIGRATION_LOCK = 7_331_906;

  /** One lock per MySQL database, so installs sharing a server do not wait on each other. */
  private static final String MYSQL_LOCK =
      "CONCAT('runlight:', LEFT(SHA2(COALESCE(DATABASE(), ''), 256), 48))";

  /** Where connections come from. */
  public interface Source {
    Connection open() throws SQLException;

    /** Hands a connection back; a broken one is closed rather than used again. */
    void release(Connection connection, boolean broken);

    /** Closes whatever the source holds. */
    default void close() {}
  }

  private final String dialect;
  private final Source source;
  private final long statementTimeout;
  private final ReentrantLock single = new ReentrantLock();
  private Connection only;
  private final ThreadLocal<Held> held = new ThreadLocal<>();

  /** A connection a thread holds for a transaction or a lock. */
  private static final class Held {
    final Connection connection;
    int transactions;
    int locks;

    Held(Connection connection) {
      this.connection = connection;
    }
  }

  /**
   * A Db over a source of connections.
   *
   * @param statementTimeout MySQL only: the session's statement timeout in milliseconds, which
   *     exclusive() lifts while it builds tables and puts back after; 0 when none was set
   */
  public JdbcDb(String dialect, Source source, long statementTimeout) {
    if (!dialect.equals("sqlite") && !dialect.equals("postgres") && !dialect.equals("mysql")) {
      throw new IllegalArgumentException("Runlight: unknown database dialect " + dialect);
    }
    this.dialect = dialect;
    this.source = source;
    this.statementTimeout = statementTimeout;
  }

  /** A Db over the app's DataSource, whose connections it borrows and gives back. */
  public static JdbcDb of(DataSource dataSource, String dialect) {
    return new JdbcDb(
        dialect,
        new Source() {
          @Override
          public Connection open() throws SQLException {
            return dataSource.getConnection();
          }

          @Override
          public void release(Connection connection, boolean broken) {
            try {
              connection.close();
            } catch (SQLException e) {
              // Already gone.
            }
          }
        },
        0);
  }

  /** The dialect a DataSource speaks, from its driver's name. */
  public static String dialectOf(DataSource dataSource) {
    try (Connection connection = dataSource.getConnection()) {
      String name = connection.getMetaData().getDatabaseProductName().toLowerCase(Locale.ROOT);
      if (name.contains("sqlite")) {
        return "sqlite";
      }
      if (name.contains("postgres")) {
        return "postgres";
      }
      if (name.contains("mysql") || name.contains("mariadb")) {
        return "mysql";
      }
      throw new IllegalArgumentException(
          "Runlight: the database " + name + " is not SQLite, Postgres, MySQL, or MariaDB");
    } catch (SQLException e) {
      throw new DbException(e);
    }
  }

  @Override
  public String dialect() {
    return dialect;
  }

  /** A database error, unchecked, with the driver's as its cause. */
  public static final class DbException extends RuntimeException {
    private static final long serialVersionUID = 1L;

    public DbException(SQLException cause) {
      super(cause.getMessage(), cause);
    }

    public DbException(String message) {
      super(message);
    }

    /** The SQL state the driver gave, or "". */
    public String sqlState() {
      return getCause() instanceof SQLException e && e.getSQLState() != null ? e.getSQLState() : "";
    }
  }

  @FunctionalInterface
  private interface Work<T> {
    T apply(Connection connection) throws SQLException;
  }

  /** Runs work on this thread's held connection, or a connection borrowed for it. */
  private <T> T with(Work<T> work) {
    Held h = held.get();
    if (h != null) {
      try {
        return work.apply(h.connection);
      } catch (SQLException e) {
        throw new DbException(e);
      }
    }
    if (dialect.equals("sqlite")) {
      single.lock();
      try {
        return work.apply(sqlite());
      } catch (SQLException e) {
        throw new DbException(e);
      } finally {
        single.unlock();
      }
    }
    for (int attempt = 0; ; attempt++) {
      Connection connection;
      try {
        connection = source.open();
      } catch (SQLException e) {
        throw new DbException(e);
      }
      boolean broken = false;
      try {
        return work.apply(connection);
      } catch (SQLException e) {
        broken = lost(e);
        // A connection the server dropped (a restart, a failover, an idle timeout) is replaced, as
        // a
        // pool replaces it, and the statement sent again: it never reached the server.
        if (broken && attempt == 0) {
          LOG.log(
              Level.WARNING,
              "Runlight: a {0} connection was lost; it reconnects. {1}",
              new Object[] {dialect.equals("mysql") ? "MySQL" : "Postgres", e.getMessage()});
          continue;
        }
        throw new DbException(e);
      } finally {
        source.release(connection, broken);
      }
    }
  }

  private Connection sqlite() throws SQLException {
    if (only == null || only.isClosed()) {
      only = source.open();
    }
    return only;
  }

  private static final Pattern LOST =
      Pattern.compile(
          "server has gone away|lost connection|server closed the connection|no connection to the server|terminating connection|connection is closed|communications link failure",
          Pattern.CASE_INSENSITIVE);

  /** Whether an error says the connection is gone, rather than that the statement failed. */
  private static boolean lost(SQLException error) {
    String state = error.getSQLState() == null ? "" : error.getSQLState();
    int code = error.getErrorCode();
    return state.startsWith("08")
        || state.equals("57P01")
        || state.equals("57P02")
        || state.equals("57P03")
        || code == 2006
        || code == 2013
        || code == 4031
        || (error.getMessage() != null && LOST.matcher(error.getMessage()).find());
  }

  private String text(String sql) {
    return dialect.equals("mysql") ? mysqlText(sql) : sql;
  }

  @Override
  public List<Map<String, Object>> all(String sql, List<?> params) {
    String text = text(sql);
    return with(
        connection -> {
          try (PreparedStatement statement = connection.prepareStatement(text)) {
            bind(statement, params);
            boolean rows = statement.execute();
            // A statement that returns no rows (an INSERT through all()) gives none.
            if (!rows) {
              return new ArrayList<>();
            }
            try (ResultSet result = statement.getResultSet()) {
              return read(result);
            }
          }
        });
  }

  @Override
  public void run(String sql, List<?> params) {
    String text = text(sql);
    with(
        connection -> {
          try (PreparedStatement statement = connection.prepareStatement(text)) {
            bind(statement, params);
            statement.execute();
            return null;
          }
        });
  }

  @Override
  public long affected(String sql, List<?> params) {
    String text = text(sql);
    return with(
        connection -> {
          try (PreparedStatement statement = connection.prepareStatement(text)) {
            bind(statement, params);
            return statement.executeLargeUpdate();
          }
        });
  }

  private static void bind(PreparedStatement statement, List<?> params) throws SQLException {
    int i = 1;
    for (Object value : params) {
      if (value == null || value == Json.UNDEFINED) {
        statement.setNull(i, Types.NULL);
      } else if (value instanceof Long || value instanceof Integer || value instanceof Short) {
        statement.setLong(i, ((Number) value).longValue());
      } else if (value instanceof Double || value instanceof Float) {
        double d = ((Number) value).doubleValue();
        if (d == Math.rint(d) && Math.abs(d) < 9.007199254740992e15) {
          statement.setLong(i, (long) d);
        } else {
          statement.setDouble(i, d);
        }
      } else if (value instanceof Boolean b) {
        statement.setBoolean(i, b);
      } else if (value instanceof byte[] bytes) {
        statement.setBytes(i, bytes);
      } else {
        // Text goes out as UTF-8 with U+FFFD for a lone surrogate, as the TypeScript drivers write
        // it.
        statement.setString(i, Js.wellFormed(value.toString()));
      }
      i++;
    }
  }

  private static List<Map<String, Object>> read(ResultSet result) throws SQLException {
    ResultSetMetaData meta = result.getMetaData();
    int columns = meta.getColumnCount();
    String[] names = new String[columns];
    boolean[] bools = new boolean[columns];
    for (int c = 0; c < columns; c++) {
      names[c] = meta.getColumnLabel(c + 1);
      // A Postgres boolean stays a boolean, as pg gives it; a MySQL TINYINT(1), which the driver
      // reads as a boolean, is a number, as mysql2 gives it.
      bools[c] = "bool".equalsIgnoreCase(meta.getColumnTypeName(c + 1));
    }
    List<Map<String, Object>> rows = new ArrayList<>();
    while (result.next()) {
      Map<String, Object> row = new LinkedHashMap<>();
      for (int c = 0; c < columns; c++) {
        Object raw = result.getObject(c + 1);
        row.put(names[c], bools[c] && raw instanceof Boolean ? raw : value(raw));
      }
      rows.add(row);
    }
    return rows;
  }

  /** A column's value in the port's own types: numbers as Long or Double, text as String. */
  private static Object value(Object raw) {
    if (raw == null) {
      return null;
    }
    if (raw instanceof Long || raw instanceof String || raw instanceof Double) {
      return raw;
    }
    if (raw instanceof Integer || raw instanceof Short || raw instanceof Byte) {
      return ((Number) raw).longValue();
    }
    if (raw instanceof Float f) {
      // A REAL column in Postgres is a float; its shortest digits are the number that was written.
      return Js.num(Double.parseDouble(Float.toString(f)));
    }
    if (raw instanceof BigDecimal d) {
      return Js.num(d.doubleValue());
    }
    if (raw instanceof BigInteger b) {
      return Js.num(b.doubleValue());
    }
    if (raw instanceof Boolean b) {
      return b ? 1L : 0L;
    }
    if (raw instanceof byte[] bytes) {
      return Js.decodeUtf8(bytes);
    }
    if (raw instanceof java.sql.Clob clob) {
      try {
        return clob.getSubString(1, (int) clob.length());
      } catch (SQLException e) {
        throw new DbException(e);
      }
    }
    return raw.toString();
  }

  @Override
  public <T> T transaction(Function<Db, T> fn) {
    Held h = held.get();
    if (h != null && h.transactions > 0) {
      return fn.apply(this);
    }
    return holding(
        state -> {
          Connection connection = state.connection;
          int isolation = connection.getTransactionIsolation();
          if (dialect.equals("mysql")) {
            // As Postgres does by default: each statement sees what was committed before it began,
            // and InnoDB takes no gap locks, so two writers to neighbouring rows do not deadlock.
            connection.setTransactionIsolation(Connection.TRANSACTION_READ_COMMITTED);
          }
          connection.setAutoCommit(false);
          state.transactions++;
          try {
            T result = fn.apply(this);
            connection.commit();
            return result;
          } catch (RuntimeException | Error e) {
            try {
              connection.rollback();
            } catch (SQLException rollback) {
              // The connection goes; holding() hands it back broken.
              throw new Broken(e);
            }
            throw e;
          } finally {
            state.transactions--;
            try {
              connection.setAutoCommit(true);
              if (dialect.equals("mysql")) {
                connection.setTransactionIsolation(isolation);
              }
            } catch (SQLException e) {
              // Handed back broken below if the connection is gone.
            }
          }
        });
  }

  /** A failure after which the connection must not be used again. */
  private static final class Broken extends RuntimeException {
    private static final long serialVersionUID = 1L;

    Broken(Throwable cause) {
      super(cause);
    }
  }

  @FunctionalInterface
  private interface HeldWork<T> {
    T apply(Held state) throws SQLException;
  }

  /** Runs work with a connection held on this thread, joining one already held. */
  private <T> T holding(HeldWork<T> work) {
    Held h = held.get();
    if (h != null) {
      try {
        return work.apply(h);
      } catch (SQLException e) {
        throw new DbException(e);
      } catch (Broken e) {
        throw unwrap(e);
      }
    }
    boolean sqlite = dialect.equals("sqlite");
    Connection connection;
    if (sqlite) {
      single.lock();
      try {
        connection = sqlite();
      } catch (SQLException e) {
        single.unlock();
        throw new DbException(e);
      }
    } else {
      try {
        connection = source.open();
      } catch (SQLException e) {
        throw new DbException(e);
      }
    }
    Held state = new Held(connection);
    held.set(state);
    boolean broken = false;
    try {
      return work.apply(state);
    } catch (SQLException e) {
      broken = lost(e);
      throw new DbException(e);
    } catch (Broken e) {
      broken = true;
      throw unwrap(e);
    } finally {
      held.remove();
      if (sqlite) {
        single.unlock();
      } else {
        source.release(connection, broken);
      }
    }
  }

  private static RuntimeException unwrap(Broken e) {
    Throwable cause = e.getCause();
    if (cause instanceof Error error) {
      throw error;
    }
    return (RuntimeException) cause;
  }

  @Override
  public <T> T exclusive(Function<Db, T> fn) {
    return holding(
        state -> {
          state.locks++;
          try {
            return locked(state.connection, fn);
          } finally {
            state.locks--;
          }
        });
  }

  private <T> T locked(Connection connection, Function<Db, T> fn) throws SQLException {
    if (dialect.equals("sqlite")) {
      // SQLite's file lock already serialises its writers.
      return fn.apply(this);
    }
    if (dialect.equals("postgres")) {
      // Asked for again and again rather than waited on: a waiting statement would hold up an index
      // being built CONCURRENTLY by whoever has the lock, and the two would wait on each other.
      while (true) {
        try (PreparedStatement statement =
            connection.prepareStatement("SELECT pg_try_advisory_lock(?) AS ok")) {
          statement.setLong(1, MIGRATION_LOCK);
          try (ResultSet result = statement.executeQuery()) {
            if (result.next() && result.getBoolean(1)) {
              break;
            }
          }
        }
        sleep(100);
      }
      try {
        return fn.apply(this);
      } finally {
        try (PreparedStatement statement =
            connection.prepareStatement("SELECT pg_advisory_unlock(?)")) {
          statement.setLong(1, MIGRATION_LOCK);
          statement.execute();
        } catch (SQLException e) {
          // A lost connection ends its session, and the lock with it.
        }
      }
    }
    while (true) {
      try (Statement statement = connection.createStatement();
          ResultSet result =
              statement.executeQuery("SELECT GET_LOCK(" + MYSQL_LOCK + ", 5) AS ok")) {
        Object ok = result.next() ? result.getObject(1) : null;
        if (ok == null) {
          throw new DbException("Runlight: MySQL refused the lock for creating tables");
        }
        if (((Number) ok).intValue() == 1) {
          break;
        }
      }
      // Not got within 5 seconds: another process is creating the tables. Ask again.
    }
    try {
      // An index on a big table takes a while to build, so the build may run past the statement
      // timeout.
      if (statementTimeout > 0) {
        limitStatements(connection, 0);
      }
      T result = fn.apply(this);
      if (statementTimeout > 0) {
        limitStatements(connection, statementTimeout);
      }
      return result;
    } catch (RuntimeException | Error e) {
      // The session may be left without its statement timeout, so the connection goes.
      throw new Broken(e);
    } finally {
      try (Statement statement = connection.createStatement()) {
        // A lost connection ends its session, and the lock with it.
        statement.execute("DO RELEASE_LOCK(" + MYSQL_LOCK + ")");
      } catch (SQLException e) {
        // Gone already.
      }
    }
  }

  private static void sleep(long ms) {
    try {
      Thread.sleep(ms);
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      throw new DbException("Runlight: interrupted while waiting for the migration lock");
    }
  }

  /**
   * MySQL's statement timeout as a session setting, which MySQL and MariaDB name differently.
   * MariaDB counts seconds and applies it to every statement; MySQL counts milliseconds and applies
   * it to reads.
   */
  static void limitStatements(Connection connection, long ms) throws SQLException {
    boolean maria;
    try (Statement statement = connection.createStatement();
        ResultSet result = statement.executeQuery("SELECT VERSION() AS v")) {
      maria = result.next() && result.getString(1).toLowerCase(Locale.ROOT).contains("mariadb");
    }
    try (Statement statement = connection.createStatement()) {
      statement.execute(
          maria
              ? "SET SESSION max_statement_time = " + Json.number(ms / 1000.0)
              : "SET SESSION max_execution_time = " + ms);
    }
  }

  @Override
  public void close() {
    single.lock();
    try {
      if (only != null) {
        source.release(only, true);
        only = null;
      }
      source.close();
    } finally {
      single.unlock();
    }
  }

  /**
   * SQL written for SQLite and Postgres, as MySQL and MariaDB read it: a "quoted" identifier is
   * quoted with backticks, and a backslash inside 'text' is doubled.
   */
  public static String mysqlText(String sql) {
    String cached = TEXTS.get(sql);
    if (cached != null) {
      return cached;
    }
    StringBuilder out = new StringBuilder(sql.length() + 8);
    char quote = 0;
    for (int i = 0; i < sql.length(); i++) {
      char ch = sql.charAt(i);
      if (quote != 0) {
        if (ch == quote) {
          quote = 0;
          out.append(ch == '"' ? '`' : ch);
        } else if (quote == '\'' && ch == '\\') {
          out.append("\\\\");
        } else if (quote == '"' && ch == '`') {
          out.append("``");
        } else {
          out.append(ch);
        }
      } else if (ch == '\'' || ch == '"' || ch == '`') {
        quote = ch;
        out.append(ch == '"' ? '`' : ch);
      } else {
        out.append(ch);
      }
    }
    String text = out.toString();
    if (TEXTS.size() > 2000) {
      TEXTS.clear();
    }
    TEXTS.put(sql, text);
    return text;
  }

  private static final Map<String, String> TEXTS = new ConcurrentHashMap<>();

  /**
   * A small pool of connections a store opened itself from a URL: idle ones are kept for the next
   * statement, up to a few, and a broken one is closed.
   */
  static final class Pool implements Source {
    @FunctionalInterface
    interface Opener {
      Connection open() throws SQLException;
    }

    private final Opener opener;
    private final Deque<Connection> idle = new ArrayDeque<>();
    private final ReentrantLock lock = new ReentrantLock();
    private static final int KEEP = 8;

    Pool(Opener opener) {
      this.opener = opener;
    }

    @Override
    public Connection open() throws SQLException {
      lock.lock();
      try {
        while (!idle.isEmpty()) {
          Connection connection = idle.pop();
          if (!connection.isClosed()) {
            return connection;
          }
        }
      } finally {
        lock.unlock();
      }
      return opener.open();
    }

    @Override
    public void release(Connection connection, boolean broken) {
      lock.lock();
      try {
        if (!broken && idle.size() < KEEP) {
          idle.push(connection);
          return;
        }
      } finally {
        lock.unlock();
      }
      try {
        connection.close();
      } catch (SQLException e) {
        // Gone already.
      }
    }

    @Override
    public void close() {
      lock.lock();
      try {
        for (Connection connection : idle) {
          try {
            connection.close();
          } catch (SQLException e) {
            // Gone already.
          }
        }
        idle.clear();
      } finally {
        lock.unlock();
      }
    }
  }
}
