#!/usr/bin/env node
/**
 * Runs the PHP package's tests (packages/php) when PHP and its Composer packages are here, and says so
 * and passes when they are not, so npm run check covers both implementations wherever it can.
 * RUNLIGHT_TEST_PG and RUNLIGHT_TEST_MYSQL reach PHPUnit as they reach the Node tests.
 */
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const dir = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "packages", "php");
const php = spawnSync("php", ["--version"], { stdio: "ignore" });
if (php.error || php.status !== 0) {
  console.log("PHP tests skipped: php is not installed.");
  process.exit(0);
}
if (!existsSync(path.join(dir, "vendor", "autoload.php"))) {
  console.log("PHP tests skipped: run composer install in packages/php first.");
  process.exit(0);
}
const run = spawnSync("php", [path.join("vendor", "bin", "phpunit")], { cwd: dir, stdio: "inherit" });
process.exit(run.status ?? 1);
