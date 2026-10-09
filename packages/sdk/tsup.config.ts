import { defineConfig } from "tsup";

export default defineConfig({
  entry: {
    index: "src/index.ts",
    sqlite: "src/stores/sqlite.ts",
    postgres: "src/stores/postgres.ts",
    mysql: "src/stores/mysql.ts",
    node: "src/node.ts",
    libsql: "src/stores/libsql.ts",
    d1: "src/stores/d1.ts",
    bun: "src/stores/bun.ts",
  },
  format: ["esm", "cjs"],
  dts: true,
  sourcemap: true,
  clean: true,
  splitting: false,
  treeshake: true,
  target: "node22",
  platform: "node",
  external: ["better-sqlite3", "pg", "mysql2", "@libsql/client", "bun:sqlite"],
});
