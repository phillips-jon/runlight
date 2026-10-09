"""Creates Runlight's tables, as one of several processes starting at once: python migrate.py <kind> <url or path>."""

from __future__ import annotations

import sys

from runlight.store import Stores

kind, where = sys.argv[1], sys.argv[2]
store = Stores.sqlite(where) if kind == "sqlite" else Stores.postgres(where) if kind == "postgres" else Stores.mysql(where)
store.migrate()
store.close()
print("ok")
