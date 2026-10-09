package sh.runlight.store;

/**
 * Creates Runlight's tables, as one of several processes starting at once: MigrateProcess kind (url
 * or path) [schema]. Prints "ok" when done.
 */
final class MigrateProcess {
  private MigrateProcess() {}

  public static void main(String[] args) {
    String kind = args[0];
    String where = args[1];
    SqlStore store =
        switch (kind) {
          case "sqlite" -> Stores.sqlite(where);
          case "postgres" -> Stores.postgres(where, 120_000, args[2]);
          default -> Stores.mysql(where);
        };
    store.migrate();
    store.close();
    System.out.println("ok");
  }
}
