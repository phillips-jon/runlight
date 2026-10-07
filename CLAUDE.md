# Runlight

Privacy friendly web analytics, library first, with a standalone server for
many sites. Planning docs and specs live outside the repo; never commit them.

- Use Node 24 (`.nvmrc`). Run `npm run check` before committing. Postgres tests run when
  `RUNLIGHT_TEST_PG` is a connection string (each test makes and drops its own schema);
  CI provides one.
- No em or en dashes anywhere in the repo, including docs and commit messages.
  `scripts/check-dashes.mjs` gates build and test.
- Commits: short one-line messages that read like a person wrote them, no
  attribution lines. Review the full diff before committing. Never push unless
  asked.
- Never store an IP address, a full user agent, or any identifier that lasts
  longer than a day.
- Behaviour lands in TypeScript first, then `conformance/` is regenerated and
  the other implementations follow.
