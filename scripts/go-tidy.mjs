// Tidies the Go modules nested in packages/go. go mod tidy ignores
// packages/go/go.work, and their go.mod files have no replace directive, so
// on its own it looks for the core at a version the proxy may not have yet.
// This tidies a copy of each go.mod with the core replaced by the source,
// leaving the files alone, and writes back what changed:
//   node scripts/go-tidy.mjs [--check]
// With --check it changes nothing and fails if a module is not tidy.
import { execFileSync } from "node:child_process";
import { copyFileSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../packages/go", import.meta.url));
const check = process.argv.includes("--check");
const go = (cwd, ...args) => execFileSync("go", args, { cwd, stdio: "inherit", env: { ...process.env, GOWORK: "off" } });

let untidy = false;
for (const module of ["chi", "echo", "cmd/runlight", "dbtest"]) {
  const dir = join(root, module);
  const temp = mkdtempSync(join(tmpdir(), "runlight-go-tidy-"));
  try {
    const mod = join(temp, "go.mod");
    const sum = join(temp, "go.sum");
    copyFileSync(join(dir, "go.mod"), mod);
    if (existsSync(join(dir, "go.sum"))) copyFileSync(join(dir, "go.sum"), sum);
    go(dir, "mod", "edit", `-modfile=${mod}`, `-replace=runlight.sh/go=${root}`);
    if (check) {
      try {
        go(dir, "mod", "tidy", "-diff", `-modfile=${mod}`);
      } catch {
        console.error(`packages/go/${module} is not tidy: run node scripts/go-tidy.mjs`);
        untidy = true;
      }
      continue;
    }
    go(dir, "mod", "tidy", `-modfile=${mod}`);
    go(dir, "mod", "edit", `-modfile=${mod}`, "-dropreplace=runlight.sh/go");
    for (const name of ["go.mod", "go.sum"]) {
      const file = join(temp, name);
      if (!existsSync(file)) continue;
      const text = readFileSync(file, "utf8");
      const target = join(dir, name);
      if (!existsSync(target) || readFileSync(target, "utf8") !== text) writeFileSync(target, text);
    }
  } finally {
    rmSync(temp, { recursive: true, force: true });
  }
}
if (untidy) process.exit(1);
