import { defineConfig } from "tsup";

export default defineConfig({
  entry: { index: "src/index.ts", cli: "src/cli.ts" },
  format: ["esm"],
  dts: { entry: "src/index.ts" },
  sourcemap: true,
  clean: true,
  splitting: false,
  target: "node22",
  platform: "node",
  external: ["@runlight/sdk", "better-sqlite3", "pg"],
});
