defmodule Runlight.Store do
  @moduledoc """
  Runlight's tables in a SQL database: SQLite, Postgres, or MySQL and
  MariaDB. The same tables, columns, and statements as the TypeScript SDK's
  SqlStore, so one database can be served by any implementation.

  Make one over an app's Ecto repo with `ecto/1`:

      Runlight.Store.ecto(repo: MyApp.Repo)

  or over any `Runlight.Db` with `new/1`.
  """

  alias Runlight.Db
  alias Runlight.JS
  alias Runlight.JS.Object
  alias Runlight.Query
  alias Runlight.Store.Sql

  import Runlight.Store.Sql,
    only: [num: 1, str: 1, str: 2, bounce: 0, visit_sql: 0, duration: 0, live_views: 0, built_days: 0, event_tail_ms: 0]

  defstruct [:db]

  @type t :: %__MODULE__{db: Db.t()}

  @doc "A store over a `Runlight.Db`."
  @spec new(Db.t()) :: t()
  def new(%Db{} = db), do: %__MODULE__{db: db}

  if Code.ensure_loaded?(Ecto.Adapters.SQL) do
    @doc "A store over an app's Ecto repo; see `Runlight.Db.Ecto` for the options."
    @spec ecto(keyword()) :: t()
    def ecto(opts), do: new(Runlight.Db.Ecto.new(opts))
  end

  defp dialect(%__MODULE__{db: db}), do: Db.dialect(db)
  defp all(%__MODULE__{db: db}, sql, params \\ []), do: Db.all(db, sql, params)
  defp run(%__MODULE__{db: db}, sql, params \\ []), do: Db.run(db, sql, params)
  defp first(store, sql, params), do: store |> all(sql, params) |> List.first()

  @doc false
  def db(%__MODULE__{db: db}), do: db

  @doc false
  def all_rows(store, sql, params \\ []), do: all(store, sql, params)
  @doc false
  def run_sql(store, sql, params \\ []), do: run(store, sql, params)

  @doc "Creates the tables, and brings an older database up to date. Safe to call any number of times."
  @spec migrate(t()) :: :ok
  def migrate(%__MODULE__{db: db}) do
    Db.exclusive(db, fn db ->
      store = new(db)
      # On Postgres an index on a big table takes a while to build, so the build may run past the
      # statement timeout, and goes CONCURRENTLY, so another process still serving keeps writing meanwhile.
      postgres = db.dialect == :postgres
      if postgres, do: run(store, "SET statement_timeout = 0")

      try do
        upgrade(store, postgres)
      after
        if postgres do
          try do
            run(store, "RESET statement_timeout")
          rescue
            _ -> :ok
          end
        end
      end
    end)

    :ok
  end

  defp upgrade(store, postgres) do
    dialect = dialect(store)
    [meta | _] = statements = Sql.schema(dialect)
    run(store, meta)
    found = first(store, ~s(SELECT value FROM rl_meta WHERE "key" = 'schema'), [])
    from = if found, do: num(found["value"]), else: Sql.schema_version()

    if postgres do
      # A concurrent build that was stopped leaves its index unusable; it goes, and is built again below.
      broken =
        all(
          store,
          """
          SELECT c.relname AS name FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
                     WHERE NOT i.indisvalid AND c.relname LIKE 'rl\\_%' AND c.relnamespace = current_schema()::regnamespace\
          """,
          []
        )

      for row <- broken, do: run(store, ~s(DROP INDEX IF EXISTS "#{String.replace(str(row["name"]), "\"", "")}"))
    end

    for statement <- statements do
      case Regex.run(~r/^CREATE (UNIQUE )?INDEX IF NOT EXISTS (\w+) ON (\w+)/, statement) do
        [_, unique, name, table] when dialect == "mysql" ->
          # MySQL has no CREATE INDEX IF NOT EXISTS, so it is looked for first.
          there =
            all(
              store,
              "SELECT 1 AS there FROM information_schema.statistics WHERE table_schema = DATABASE() AND table_name = ? AND index_name = ? LIMIT 1",
              [table, name]
            )

          if there == [],
            do:
              run(store, String.replace(statement, ~r/^CREATE (UNIQUE )?INDEX IF NOT EXISTS/, "CREATE #{unique}INDEX"))

        _ ->
          sql =
            if postgres,
              do:
                String.replace(
                  statement,
                  ~r/^CREATE (UNIQUE )?INDEX IF NOT EXISTS/,
                  "CREATE \\1INDEX CONCURRENTLY IF NOT EXISTS"
                ),
              else: statement

          run(store, sql)
      end
    end

    # A column added by an upgrade that stopped before it recorded the new version is already there.
    add_column = fn sql ->
      try do
        run(store, sql)
      rescue
        error ->
          unless Regex.match?(~r/duplicate column|already exists/i, Exception.message(error)),
            do: reraise(error, __STACKTRACE__)
      end
    end

    # Version 2: settings changed in the dashboard, kept apart from the ones in code.
    if from < 2, do: add_column.("ALTER TABLE rl_sites ADD COLUMN overrides TEXT NOT NULL DEFAULT '{}'")
    if from < 4, do: run(store, "DROP INDEX IF EXISTS rl_links_slug")
    # Version 10: tokens that may change one site's settings, for a hub.
    if from >= 8 and from < 10, do: add_column.("ALTER TABLE rl_tokens ADD COLUMN scope TEXT NOT NULL DEFAULT 'read'")
    # Written only when it changes, so a database opened read-only can still be read.
    version = Integer.to_string(Sql.schema_version())

    if found == nil or str(found["value"]) != version do
      run(store, Sql.upsert(dialect, "rl_meta", [~s("key"), "value"], [~s("key")], ["value"]), ["schema", version])
    end

    :ok
  end

  @doc """
  Keeps SQLite's planner statistics current, which it never gathers by
  itself. A sample of each index is enough. Postgres gathers its own.
  """
  @spec optimize(t(), boolean()) :: :ok
  def optimize(store, only_when_missing \\ false) do
    if dialect(store) == "sqlite" do
      try do
        missing =
          not only_when_missing or all(store, "SELECT name FROM sqlite_master WHERE name = 'sqlite_stat1'") == []

        if missing do
          run(store, "PRAGMA analysis_limit = 1000")
          run(store, "ANALYZE")
        end
      rescue
        # Some hosted SQLite services refuse these, and gather statistics themselves.
        _ -> :ok
      end
    end

    :ok
  end

  # How many rows an UPDATE or DELETE of rows with an id matched.
  defp changed(store, sql, params) do
    if dialect(store) == "mysql",
      do: Db.affected(store.db, sql, params),
      else: length(all(store, "#{sql} RETURNING id", params))
  end

  @doc "Runs `fun` with a store whose every query is in one transaction."
  @spec transaction(t(), (t() -> term())) :: term()
  def transaction(%__MODULE__{db: db}, fun), do: Db.transaction(db, fn db -> fun.(new(db)) end)

  # Sites

  @spec upsert_site(t(), Object.t(), integer()) :: :ok
  def upsert_site(store, site, now) do
    # Unchanged sites are left alone, so starting needs no write and a read-only database still opens.
    row = first(store, "SELECT name, hostnames, timezone FROM rl_sites WHERE id = ?", [site["id"]])
    hostnames = JS.stringify(site["hostnames"])

    unless row && row["name"] == site["name"] && row["hostnames"] == hostnames && row["timezone"] == site["timezone"] do
      run(
        store,
        Sql.upsert(dialect(store), "rl_sites", ["id", "name", "hostnames", "timezone", "created_at"], ["id"], [
          "name",
          "hostnames",
          "timezone"
        ]),
        [site["id"], site["name"], hostnames, site["timezone"], now]
      )
    end

    :ok
  end

  @doc "Settings changed in the dashboard, by site. They win over the ones in code."
  @spec site_overrides(t()) :: %{String.t() => Object.t()}
  def site_overrides(store) do
    for row <- all(store, "SELECT id, overrides FROM rl_sites"), into: %{} do
      overrides =
        case JS.parse(str(row["overrides"])) do
          {:ok, %Object{} = o} -> o
          {:ok, _} -> Object.new()
          {:error, _} -> Object.new()
        end

      {str(row["id"]), overrides}
    end
  end

  @doc """
  Deletes a site and everything recorded for it. Its events and visits go a
  day at a time first, and what is left goes in one transaction.
  """
  @spec delete_site(t(), String.t()) :: :ok
  def delete_site(store, id) do
    piece = if store.db.metered, do: 30 * Sql.piece_ms(), else: Sql.piece_ms()

    for {table, col} <- [{"rl_events", "ts"}, {"rl_sessions", "started_at"}] do
      delete_pieces(store, table, col, id, oldest(store, table, col, id, nil), piece)
    end

    transaction(store, fn store ->
      for table <-
            ~w(rl_events rl_sessions rl_links rl_link_domains rl_shares rl_goals rl_funnels rl_reports rl_tokens rl_rollups rl_rollup_days rl_sites) do
        run(store, "DELETE FROM #{table} WHERE #{if table == "rl_sites", do: "id", else: "site"} = ?", [id])
      end
    end)

    :ok
  end

  defp delete_pieces(_store, _table, _col, _id, nil, _piece), do: :ok

  defp delete_pieces(store, table, col, id, from, piece) do
    run(store, "DELETE FROM #{table} WHERE site = ? AND #{col} < ?", [id, from + piece])
    delete_pieces(store, table, col, id, oldest(store, table, col, id, from + piece), piece)
  end

  # When a site's oldest row at or after `from` is, or nil when there is none (nil `from` for any).
  defp oldest(store, table, col, site, from) do
    row =
      if from == nil,
        do: first(store, "SELECT MIN(#{col}) AS t FROM #{table} WHERE site = ?", [site]),
        else: first(store, "SELECT MIN(#{col}) AS t FROM #{table} WHERE site = ? AND #{col} >= ?", [site, from])

    if row == nil or row["t"] == nil, do: nil, else: num(row["t"])
  end

  @doc "Deletes a site's visits and events from before a time, for its retention setting."
  @spec drop_before(t(), String.t(), integer()) :: :ok
  def drop_before(store, site, ts) do
    piece = if store.db.metered, do: 30 * Sql.piece_ms(), else: Sql.piece_ms()

    next = fn at ->
      found =
        Enum.reject(
          [oldest(store, "rl_sessions", "started_at", site, at), oldest(store, "rl_events", "ts", site, at)],
          &is_nil/1
        )

      if found == [], do: nil, else: if(at == nil, do: Enum.min(found), else: max(at, Enum.min(found)))
    end

    drop_loop(store, site, ts, piece, next, next.(nil))
    # A day that lost any of its visits is built again later, from what is left.
    clear_rollups(store, site, before: ts)
  end

  defp drop_loop(store, site, ts, piece, next, from) when is_number(from) and from < ts do
    to = min(from + piece, ts)

    transaction(store, fn store ->
      # A visit's events go with it, even ones after the cutoff, so nothing is left without its visit.
      run(
        store,
        "DELETE FROM rl_events WHERE site = ? AND ts >= ? AND ts < ? AND session IN (SELECT id FROM rl_sessions WHERE site = ? AND started_at >= ? AND started_at < ?)",
        [site, from, to + event_tail_ms(), site, from, to]
      )

      run(store, "DELETE FROM rl_events WHERE site = ? AND ts < ?", [site, to])
      run(store, "DELETE FROM rl_sessions WHERE site = ? AND started_at < ?", [site, to])
    end)

    drop_loop(store, site, ts, piece, next, next.(min(from + piece, ts)))
  end

  defp drop_loop(_store, _site, _ts, _piece, _next, _from), do: :ok

  @doc "Deletes a site's events from `from` on whose visit no longer exists, a day at a time."
  @spec drop_orphans(t(), String.t(), integer(), integer()) :: :ok
  def drop_orphans(store, site, from, until) do
    piece = if store.db.metered, do: 30 * Sql.piece_ms(), else: Sql.piece_ms()
    orphans_loop(store, site, until, piece, oldest(store, "rl_events", "ts", site, from))
  end

  defp orphans_loop(store, site, until, piece, at) when is_number(at) and at < until do
    run(
      store,
      "DELETE FROM rl_events WHERE site = ? AND ts >= ? AND ts < ? AND session <> '' AND NOT EXISTS (SELECT 1 FROM rl_sessions s WHERE s.id = rl_events.session)",
      [site, at, at + piece]
    )

    orphans_loop(store, site, until, piece, oldest(store, "rl_events", "ts", site, at + piece))
  end

  defp orphans_loop(_store, _site, _until, _piece, _at), do: :ok

  # Daily rollups

  @doc """
  Adds up one local day of a site: totals, each visit dimension, and pages.
  A visit belongs to the day it started.
  """
  @spec build_rollup_day(t(), String.t(), String.t(), integer(), integer()) :: :ok
  def build_rollup_day(store, site, day, start, finish) do
    sums =
      "COUNT(DISTINCT s.visitor), COUNT(*), COALESCE(SUM(s.pageviews), 0), COALESCE(SUM(CASE WHEN #{bounce()} THEN 1 ELSE 0 END), 0), COALESCE(SUM(#{duration()}), 0)"

    cols = "(site, day, dim, value, visitors, visits, pageviews, bounced, duration)"
    dialect = dialect(store)
    head = "#{Sql.as_text(dialect, "?")}, #{Sql.as_text(dialect, "?")}"
    quarter = Sql.div(dialect, "s.started_at", 900_000)

    pieces =
      ["SELECT #{head}, '', '', #{sums} FROM v s"] ++
        Enum.map(Query.session_dimensions(), fn {dim, col} ->
          "SELECT #{head}, '#{dim}', s.#{col}, #{sums} FROM v s WHERE s.#{col} <> '' GROUP BY s.#{col}"
        end) ++
        [
          "SELECT #{head}, 'quarter', #{Sql.as_text(dialect, quarter)}, COUNT(DISTINCT s.visitor), COUNT(*), COALESCE(SUM(s.pageviews), 0), COALESCE(SUM(CASE WHEN #{bounce()} THEN 1 ELSE 0 END), 0), 0 FROM v s GROUP BY #{Sql.as_text(dialect, quarter)}"
        ]

    of_day = fn kind ->
      """
      FROM rl_events e JOIN rl_sessions s ON s.id = e.session
             WHERE e.site = ? AND e.kind = '#{kind}' AND e.ts >= ? AND e.ts < ? AND s.started_at >= ? AND s.started_at < ? AND #{visit_sql()}\
      """
    end

    window = [site, start, finish + event_tail_ms(), start, finish]

    transaction(store, fn store ->
      run(store, "DELETE FROM rl_rollups WHERE site = ? AND day = ?", [site, day])

      run(
        store,
        """
        INSERT INTO rl_rollups #{cols}
               WITH v AS (SELECT * FROM rl_sessions s WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND #{visit_sql()})
               #{Enum.join(pieces, " UNION ALL ")}\
        """,
        [site, start, finish] ++ Enum.flat_map(pieces, fn _ -> [site, day] end)
      )

      run(
        store,
        """
        INSERT INTO rl_rollups (site, day, dim, value, visitors, visits, pageviews, views, engaged, scroll_sum, scroll_n)
               SELECT ?, ?, 'page', p.value, p.visitors, p.visits, p.pageviews, p.views, COALESCE(t.engaged, 0), COALESCE(t.scroll_sum, 0), COALESCE(t.scroll_n, 0)
               FROM (SELECT e.path AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(DISTINCT e.session) AS visits, COUNT(*) AS pageviews, #{live_views()} AS views
                     #{of_day.("pageview")} GROUP BY e.path) p
               LEFT JOIN (SELECT value, SUM(total) AS engaged, SUM(deepest) AS scroll_sum, COUNT(deepest) AS scroll_n FROM (
                     SELECT e.path AS value, SUM(e.engaged_ms) AS total, MAX(e.scroll) AS deepest #{of_day.("engagement")} GROUP BY e.path, e.pageview) x
                     GROUP BY value) t ON t.value = p.value\
        """,
        [site, day] ++ window ++ window
      )

      run(
        store,
        """
        INSERT INTO rl_rollups (site, day, dim, value, visitors, events)
               SELECT ?, ?, 'event', e.name, COUNT(DISTINCT e.visitor), COUNT(*) #{of_day.("event")} GROUP BY e.name\
        """,
        [site, day] ++ window
      )

      run(store, "DELETE FROM rl_rollup_days WHERE site = ? AND day = ?", [site, day])

      run(store, "INSERT INTO rl_rollup_days (site, day, start_at, end_at) VALUES (?, ?, ?, ?)", [
        site,
        day,
        start,
        finish
      ])
    end)

    :ok
  end

  @doc "The days of a site already built."
  @spec rollup_days(t(), String.t()) :: MapSet.t()
  def rollup_days(store, site) do
    store |> all("SELECT day FROM rl_rollup_days WHERE site = ?", [site]) |> MapSet.new(&str(&1["day"]))
  end

  @doc """
  Forgets built days, all of a site's (no options), those starting before
  `before:`, or those touching `from:` to `to:`, so they are built again.
  """
  @spec clear_rollups(t(), String.t(), keyword()) :: :ok
  def clear_rollups(store, site, range \\ []) do
    {where, params} =
      cond do
        Keyword.has_key?(range, :before) ->
          {"site = ? AND start_at < ?", [site, range[:before]]}

        Keyword.has_key?(range, :from) and Keyword.has_key?(range, :to) ->
          {"site = ? AND start_at < ? AND end_at > ?", [site, range[:to], range[:from]]}

        true ->
          {"site = ?", [site]}
      end

    days = store |> all("SELECT day FROM rl_rollup_days WHERE #{where}", params) |> Enum.map(&str(&1["day"]))
    # The days stop counting as built first, so if this stops part way, no day is left marked built without
    # its rows. Another process may build a day between the two deletes, so its mark goes again after its rows.
    run(store, "DELETE FROM rl_rollup_days WHERE #{where}", params)

    for day <- days do
      run(store, "DELETE FROM rl_rollups WHERE site = ? AND day = ?", [site, day])
      run(store, "DELETE FROM rl_rollup_days WHERE site = ? AND day = ?", [site, day])
    end

    :ok
  end

  # How to answer a range from rollups: the built days wholly inside it, and the stretches left over.
  defp rollup_plan(store, query, from, to) do
    if query.filters != [] do
      nil
    else
      rows =
        all(
          store,
          "SELECT day, start_at, end_at FROM rl_rollup_days WHERE site = ? AND start_at >= ? AND end_at <= ? ORDER BY start_at",
          [query.site, from, to]
        )

      if rows == [] do
        nil
      else
        days = Enum.map(rows, &%{day: str(&1["day"]), start: num(&1["start_at"]), end: num(&1["end_at"])})

        {rest, at} =
          Enum.reduce(days, {[], from}, fn d, {rest, at} ->
            rest = if d.start > at, do: rest ++ [{at, d.start}], else: rest
            {rest, max(at, d.end)}
          end)

        rest = if at < to, do: rest ++ [{at, to}], else: rest
        %{days: days, rest: rest}
      end
    end
  end

  # SQL for "a visit that started in one of these stretches".
  defp within([]), do: {"1 = 0", []}

  defp within(rest) do
    {"(" <> Enum.map_join(rest, " OR ", fn _ -> "(s.started_at >= ? AND s.started_at < ?)" end) <> ")",
     Enum.flat_map(rest, fn {a, b} -> [a, b] end)}
  end

  @sum_keys ~w(visitors visits pageviews bounced duration engaged views scroll_sum scroll_n events)

  defp rolled_breakdown(store, query, dimension, limit, offset) do
    page = dimension == "page"
    event = dimension == "event"

    cond do
      not page and not event and not Query.session_dimension?(dimension) ->
        nil

      query.filters != [] ->
        nil

      true ->
        # Pages and events always go this way without filters, so a range gives the same answer whether its days are
        # built or not.
        plan =
          rollup_plan(store, query, query.from, query.to) ||
            if(page or event, do: %{days: [], rest: [{query.from, query.to}]})

        if plan, do: rolled_rows(store, query, dimension, plan, limit, offset)
    end
  end

  defp rolled_rows(store, query, dimension, plan, limit, offset) do
    page = dimension == "page"
    event = dimension == "event"

    bump = fn {order, sums}, row ->
      key = str(row["value"])

      {order, into} =
        if Map.has_key?(sums, key), do: {order, sums[key]}, else: {[key | order], Map.new(@sum_keys, &{&1, 0})}

      into = Map.new(into, fn {k, v} -> {k, v + num(row[k])} end)
      {order, Map.put(sums, key, into)}
    end

    acc = {[], %{}}

    acc =
      if plan.days != [] do
        rolled =
          all(
            store,
            """
            SELECT value, SUM(visitors) AS visitors, SUM(visits) AS visits, SUM(pageviews) AS pageviews, SUM(bounced) AS bounced, SUM(duration) AS duration,
                       SUM(engaged) AS engaged, SUM(views) AS views, SUM(scroll_sum) AS scroll_sum, SUM(scroll_n) AS scroll_n, SUM(events) AS events
                     FROM rl_rollups WHERE site = ? AND dim = ? AND day IN (#{built_days()}) GROUP BY value\
            """,
            [query.site, dimension, query.site, query.from, query.to]
          )

        Enum.reduce(rolled, acc, &bump.(&2, &1))
      else
        acc
      end

    {w_sql, w_params} = within(plan.rest)

    acc =
      cond do
        (page or event) and plan.rest != [] ->
          # A visit's pageviews and events belong to the day it started, as in the rollups.
          lo = plan.rest |> Enum.map(&elem(&1, 0)) |> Enum.min()
          hi = (plan.rest |> Enum.map(&elem(&1, 1)) |> Enum.max()) + event_tail_ms()

          of_rest = fn kind ->
            "FROM rl_events e JOIN rl_sessions s ON s.id = e.session WHERE e.site = ? AND e.kind = '#{kind}' AND e.ts >= ? AND e.ts < ? AND #{visit_sql()} AND #{w_sql}"
          end

          at = [query.site, lo, hi] ++ w_params

          if page do
            acc =
              store
              |> all(
                "SELECT e.path AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(DISTINCT e.session) AS visits, COUNT(*) AS pageviews, #{live_views()} AS views #{of_rest.("pageview")} GROUP BY e.path",
                at
              )
              |> Enum.reduce(acc, &bump.(&2, &1))

            store
            |> all(
              """
              SELECT value, SUM(total) AS engaged, SUM(deepest) AS scroll_sum, COUNT(deepest) AS scroll_n FROM (
                         SELECT e.path AS value, SUM(e.engaged_ms) AS total, MAX(e.scroll) AS deepest #{of_rest.("engagement")} GROUP BY e.path, e.pageview) t GROUP BY value\
              """,
              at
            )
            |> Enum.reduce(acc, &bump.(&2, &1))
          else
            store
            |> all(
              "SELECT e.name AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(*) AS events #{of_rest.("event")} GROUP BY e.name",
              at
            )
            |> Enum.reduce(acc, &bump.(&2, &1))
          end

        page or event ->
          # Every day of the range is built.
          acc

        true ->
          col = "s." <> Query.session_column(dimension)

          store
          |> all(
            """
            SELECT #{col} AS value, COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits, SUM(s.pageviews) AS pageviews,
                       SUM(CASE WHEN #{bounce()} THEN 1 ELSE 0 END) AS bounced, SUM(#{duration()}) AS duration
                     FROM rl_sessions s WHERE s.site = ? AND #{visit_sql()} AND #{w_sql} AND #{col} <> '' GROUP BY #{col}\
            """,
            [query.site] ++ w_params
          )
          |> Enum.reduce(acc, &bump.(&2, &1))
      end

    {order, sums} = acc
    entry_exit = dimension in ["entry", "exit"]

    rows =
      order
      |> Enum.reverse()
      |> Enum.map(&{&1, sums[&1]})
      |> Enum.filter(fn {value, x} ->
        (event or value != "") and
          cond do
            page -> x["pageviews"] > 0
            event -> x["events"] > 0
            true -> x["visits"] > 0
          end
      end)
      |> Enum.sort(fn {a, x}, {b, y} ->
        keys =
          cond do
            entry_exit -> [y["visits"] - x["visits"]]
            event -> [y["visitors"] - x["visitors"], y["events"] - x["events"]]
            page -> [y["visitors"] - x["visitors"], y["pageviews"] - x["pageviews"]]
            true -> [y["visitors"] - x["visitors"], y["visits"] - x["visits"]]
          end

        case Enum.find(keys, &(&1 != 0)) do
          nil -> JS.code_order(a, b) <= 0
          d -> d < 0
        end
      end)

    rows
    |> Enum.drop(offset)
    |> Enum.take(limit)
    |> Enum.map(fn {value, x} ->
      cond do
        event ->
          JS.obj(value: value, visitors: x["visitors"], events: x["events"])

        page ->
          JS.obj(
            value: value,
            visitors: x["visitors"],
            pageviews: x["pageviews"],
            # Over every pageview that could report its time, counting those that sent none (under a second) as none.
            timeOnPage: if(x["views"] > 0, do: JS.round(x["engaged"] / x["views"]), else: 0),
            scrollDepth: if(x["scroll_n"] > 0, do: JS.round(x["scroll_sum"] / x["scroll_n"]), else: 0)
          )

        true ->
          out =
            JS.obj(
              value: value,
              visitors: x["visitors"],
              visits: x["visits"],
              bounceRate: if(x["visits"] > 0, do: x["bounced"] / x["visits"], else: 0)
            )

          if entry_exit,
            do: out,
            else:
              out
              |> Object.put("pageviews", x["pageviews"])
              |> Object.put("visitDuration", if(x["visits"] > 0, do: JS.round(x["duration"] / x["visits"]), else: 0))
      end
    end)
  end

  defp rolled_stats(store, query) do
    case rollup_plan(store, query, query.from, query.to) do
      nil ->
        nil

      plan ->
        rolled =
          first(
            store,
            """
            SELECT SUM(visitors) AS visitors, SUM(visits) AS visits, SUM(pageviews) AS pageviews, SUM(bounced) AS bounced, SUM(duration) AS duration
                   FROM rl_rollups WHERE site = ? AND dim = '' AND day IN (#{built_days()})\
            """,
            [query.site, query.site, query.from, query.to]
          )

        {w_sql, w_params} = within(plan.rest)

        raw =
          first(
            store,
            """
            SELECT COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits, SUM(s.pageviews) AS pageviews,
                     SUM(CASE WHEN #{bounce()} THEN 1 ELSE 0 END) AS bounced, SUM(#{duration()}) AS duration
                   FROM rl_sessions s WHERE s.site = ? AND #{visit_sql()} AND #{w_sql}\
            """,
            [query.site] ++ w_params
          )

        add = fn k -> num(rolled && rolled[k]) + num(raw && raw[k]) end
        stats_obj(add.("visitors"), add.("visits"), add.("pageviews"), add.("bounced"), add.("duration"))
    end
  end

  defp stats_obj(visitors, visits, pageviews, bounced, duration) do
    JS.obj(
      visitors: visitors,
      visits: visits,
      pageviews: pageviews,
      viewsPerVisit: if(visits > 0, do: JS.round(pageviews / visits * 100) / 100, else: 0),
      bounceRate: if(visits > 0, do: bounced / visits, else: 0),
      visitDuration: if(visits > 0, do: JS.round(duration / visits), else: 0)
    )
  end

  @spec set_site_overrides(t(), String.t(), Object.t()) :: :ok
  def set_site_overrides(store, id, overrides) do
    run(store, "UPDATE rl_sites SET overrides = ? WHERE id = ?", [JS.stringify(overrides), id])
  end

  @doc "When the site last recorded a visit, or nil if it never has."
  @spec last_seen(t(), String.t()) :: number() | nil
  def last_seen(store, site) do
    row = first(store, "SELECT MAX(ts) AS t FROM rl_events WHERE site = ? AND kind IN ('pageview', 'event')", [site])
    if row == nil or row["t"] == nil, do: nil, else: num(row["t"])
  end

  @doc "The sites kept in the database, by name."
  @spec sites(t()) :: [Object.t()]
  def sites(store) do
    for row <- all(store, "SELECT id, name, hostnames, timezone FROM rl_sites ORDER BY name, id") do
      Object.put(row, "hostnames", JS.parse!(str(row["hostnames"])))
    end
  end

  # Salts

  @doc "The salt for a day, made on first ask. Two racing callers agree on one."
  @spec salt(t(), String.t(), String.t()) :: String.t()
  def salt(store, day, fresh) do
    run(store, Sql.upsert(dialect(store), "rl_salts", ["day", "salt"], ["day"], []), [day, fresh])

    case first(store, "SELECT salt FROM rl_salts WHERE day = ?", [day]) do
      nil -> fresh
      row -> str(row["salt"])
    end
  end

  @spec salt_if_exists(t(), String.t()) :: String.t() | nil
  def salt_if_exists(store, day) do
    case first(store, "SELECT salt FROM rl_salts WHERE day = ?", [day]) do
      nil -> nil
      row -> str(row["salt"])
    end
  end

  @doc "Deletes every salt older than `day`, so old hashes can never be recomputed."
  @spec drop_salts_before(t(), String.t()) :: :ok
  def drop_salts_before(store, day), do: run(store, "DELETE FROM rl_salts WHERE day < ?", [day])

  # Ingest

  @doc "The visitor's open session: any of their hashes, active since `since`."
  @spec open_session(t(), String.t(), [String.t()], integer()) :: map() | nil
  def open_session(_store, _site, [], _since), do: nil

  def open_session(store, site, visitors, since) do
    case first(
           store,
           """
           SELECT id, visitor FROM rl_sessions WHERE site = ? AND visitor IN (#{Enum.map_join(visitors, ", ", fn _ -> "?" end)}) AND last_at >= ?
                  ORDER BY last_at DESC, id LIMIT 1\
           """,
           [site] ++ visitors ++ [since]
         ) do
      nil -> nil
      row -> %{id: str(row["id"]), visitor: str(row["visitor"])}
    end
  end

  @doc "Records a new session; `row` is a map with the SessionRow's fields as atoms in snake case."
  @spec insert_session(t(), map()) :: :ok
  def insert_session(store, row) do
    run(
      store,
      """
      INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, engaged_ms, hostname, referrer_host, referrer_path,
              source, channel, utm_source, utm_medium, utm_campaign, utm_term, utm_content, country, region, city,
              browser, browser_version, os, os_version, device, screen, language)
             VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)\
      """,
      [
        row.id,
        row.site,
        row.visitor,
        row.started_at,
        row.started_at,
        row.hostname,
        row.referrer_host,
        row.referrer_path,
        row.source,
        row.channel,
        row.utm_source,
        row.utm_medium,
        row.utm_campaign,
        row.utm_term,
        row.utm_content,
        row.country,
        row.region,
        row.city,
        row.browser,
        row.browser_version,
        row.os,
        row.os_version,
        row.device,
        row.screen,
        row.language
      ]
    )
  end

  @doc """
  Counts a row into its session. An event with `reopen` false, one that joins
  a visit already ended, counts without moving the session's last activity.
  """
  @spec touch_session(t(), String.t(), integer(), String.t(), String.t(), boolean()) :: :ok
  def touch_session(store, id, ts, kind, path, reopen \\ true) do
    cond do
      kind == "click" ->
        run(store, "UPDATE rl_sessions SET last_at = ? WHERE id = ?", [ts, id])

      kind == "pageview" ->
        run(
          store,
          """
          UPDATE rl_sessions SET pageviews = pageviews + 1, last_at = ?, exit_path = ?,
                     entry_path = CASE WHEN entry_path = '' THEN ? ELSE entry_path END WHERE id = ?\
          """,
          [ts, path, path, id]
        )

      reopen ->
        run(store, "UPDATE rl_sessions SET events = events + 1, last_at = ? WHERE id = ?", [ts, id])

      true ->
        run(store, "UPDATE rl_sessions SET events = events + 1 WHERE id = ?", [id])
    end
  end

  @spec add_engagement(t(), String.t(), integer()) :: :ok
  def add_engagement(store, id, ms) do
    run(store, "UPDATE rl_sessions SET engaged_ms = COALESCE(engaged_ms, 0) + ? WHERE id = ?", [ms, id])
  end

  @doc "The pageview an engagement ping or event belongs to, with when its visit started and was last active."
  @spec pageview(t(), String.t(), String.t()) :: map() | nil
  def pageview(store, site, pageview) do
    row =
      first(
        store,
        """
        SELECT e.session AS session, e.visitor AS visitor, e.path AS path, e.hostname AS hostname, e.ts AS ts, s.started_at AS started_at, s.last_at AS last_at
               FROM rl_events e JOIN rl_sessions s ON s.id = e.session WHERE e.site = ? AND e.pageview = ? AND e.kind = 'pageview' LIMIT 1\
        """,
        [site, pageview]
      )

    row &&
      %{
        session: str(row["session"]),
        visitor: str(row["visitor"]),
        path: str(row["path"]),
        hostname: str(row["hostname"]),
        ts: num(row["ts"]),
        started_at: num(row["started_at"]),
        last_at: num(row["last_at"])
      }
  end

  @doc """
  After a late event or engagement ping joins an old visit, the day that
  visit started may already be added up. Forget that day so the next check
  builds it again.
  """
  @spec touched_old_visit(t(), String.t(), integer(), integer()) :: :ok
  def touched_old_visit(store, site, started, before) do
    if started < before, do: clear_rollups(store, site, from: started, to: started + 1), else: :ok
  end

  @doc "Records an event; `row` is a map with the EventRow's fields as atoms in snake case."
  @spec insert_event(t(), map()) :: :ok
  def insert_event(store, row) do
    run(
      store,
      """
      INSERT INTO rl_events (site, ts, kind, visitor, session, pageview, path, hostname, title, name, props, engaged_ms, scroll, link)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)\
      """,
      [
        row.site,
        row.ts,
        row.kind,
        row.visitor,
        row.session,
        row.pageview,
        row.path,
        row.hostname,
        row.title,
        row.name,
        if(row.props, do: JS.stringify(row.props)),
        row.engaged_ms,
        row.scroll,
        row.link
      ]
    )
  end

  # Links

  defp link_row(row) do
    JS.obj(
      id: str(row["id"]),
      site: str(row["site"]),
      domain: str(row["domain"], ""),
      slug: str(row["slug"]),
      name: str(row["name"], ""),
      url: str(row["url"]),
      createdAt: num(row["created_at"]),
      updatedAt: num(row["updated_at"])
    )
  end

  @doc "The live link with a slug. Slugs are unique across every domain."
  @spec link_by_slug(t(), String.t()) :: Object.t() | nil
  def link_by_slug(store, slug) do
    row = first(store, "SELECT * FROM rl_links WHERE slug = ? AND deleted_at IS NULL LIMIT 1", [slug])
    row && link_row(row)
  end

  @spec link_by_id(t(), String.t()) :: Object.t() | nil
  def link_by_id(store, id) do
    row = first(store, "SELECT * FROM rl_links WHERE id = ? AND deleted_at IS NULL LIMIT 1", [id])
    row && link_row(row)
  end

  @spec insert_link(t(), Object.t()) :: :ok
  def insert_link(store, l) do
    run(
      store,
      "INSERT INTO rl_links (id, site, domain, slug, name, url, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [
        l["id"],
        l["site"],
        l["domain"],
        l["slug"],
        l["name"],
        l["url"],
        l["createdAt"],
        l["updatedAt"]
      ]
    )
  end

  @spec update_link(t(), Object.t()) :: :ok
  def update_link(store, l) do
    run(store, "UPDATE rl_links SET domain = ?, slug = ?, name = ?, url = ?, updated_at = ? WHERE id = ?", [
      l["domain"],
      l["slug"],
      l["name"],
      l["url"],
      l["updatedAt"],
      l["id"]
    ])
  end

  @doc "Hides a link and frees its slug; its clicks stay in the history."
  @spec delete_link(t(), String.t(), integer()) :: :ok
  def delete_link(store, id, now),
    do: run(store, "UPDATE rl_links SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL", [now, id])

  # Shares

  defp share_row(r),
    do: JS.obj(id: str(r["id"]), site: str(r["site"]), name: str(r["name"], ""), createdAt: num(r["created_at"]))

  @spec shares(t(), String.t()) :: [Object.t()]
  def shares(store, site) do
    store
    |> all("SELECT id, site, name, created_at FROM rl_shares WHERE site = ? ORDER BY created_at DESC, id", [site])
    |> Enum.map(&share_row/1)
  end

  @spec share_by_id(t(), String.t()) :: Object.t() | nil
  def share_by_id(store, id) do
    r = first(store, "SELECT id, site, name, created_at FROM rl_shares WHERE id = ?", [id])
    r && share_row(r)
  end

  @spec insert_share(t(), Object.t()) :: :ok
  def insert_share(store, s) do
    run(store, "INSERT INTO rl_shares (id, site, name, created_at) VALUES (?, ?, ?, ?)", [
      s["id"],
      s["site"],
      s["name"],
      s["createdAt"]
    ])
  end

  @spec rename_share(t(), String.t(), String.t()) :: :ok
  def rename_share(store, id, name), do: run(store, "UPDATE rl_shares SET name = ? WHERE id = ?", [name, id])

  @doc "Deleting a share is how it is revoked: the link stops working at once."
  @spec delete_share(t(), String.t()) :: :ok
  def delete_share(store, id), do: run(store, "DELETE FROM rl_shares WHERE id = ?", [id])

  # Funnels

  @spec funnels(t(), String.t()) :: [Object.t()]
  def funnels(store, site) do
    for r <- all(store, "SELECT * FROM rl_funnels WHERE site = ? ORDER BY created_at, id", [site]) do
      JS.obj(
        id: str(r["id"]),
        site: str(r["site"]),
        name: str(r["name"]),
        steps: JS.parse!(str(r["steps"])),
        createdAt: num(r["created_at"])
      )
    end
  end

  @spec save_funnel(t(), Object.t()) :: :ok
  def save_funnel(store, f) do
    run(
      store,
      Sql.upsert(dialect(store), "rl_funnels", ["id", "site", "name", "steps", "created_at"], ["id"], ["name", "steps"]),
      [f["id"], f["site"], f["name"], JS.stringify(f["steps"]), f["createdAt"]]
    )
  end

  @spec delete_funnel(t(), String.t()) :: :ok
  def delete_funnel(store, id), do: run(store, "DELETE FROM rl_funnels WHERE id = ?", [id])

  @doc """
  How many visits reached each step, in order, within the same visit. Step
  one is the first matching row in the range; each later step must come
  after the step before it. Filters choose which visits enter the funnel.
  """
  @spec funnel_counts(t(), map(), Object.t()) :: [non_neg_integer()]
  def funnel_counts(store, query, funnel) do
    {v_from, v_sql, v_params} = Sql.visit_rows(query.filters, query.site, query.from, query.to, dialect(store))
    steps = funnel["steps"]
    scopes = Enum.map(steps, &goal_scope(store, JS.obj(kind: &1["kind"], match: &1["match"], name: &1["match"])))

    rows =
      all(
        store,
        """
        SELECT e.session AS session, #{scopes |> Enum.with_index() |> Enum.map_join(", ", fn {{sql, _}, i} -> "CASE WHEN #{sql} THEN 1 ELSE 0 END AS m#{i}" end)}
               FROM #{v_from} WHERE #{v_sql} AND (#{Enum.map_join(scopes, " OR ", fn {sql, _} -> "(#{sql})" end)})
               ORDER BY e.session, e.ts, e.id\
        """,
        Enum.flat_map(scopes, &elem(&1, 1)) ++ v_params ++ Enum.flat_map(scopes, &elem(&1, 1))
      )

    n = length(steps)
    counts = List.duplicate(0, n)

    close = fn counts, reached -> Enum.with_index(counts, fn c, i -> if i < reached, do: c + 1, else: c end) end

    {counts, _, reached} =
      Enum.reduce(rows, {counts, :none, 0}, fn row, {counts, session, reached} ->
        {counts, session, reached} =
          if row["session"] != session,
            do: {close.(counts, reached), row["session"], 0},
            else: {counts, session, reached}

        # Each step is the first matching row after the step before, so two steps in the same millisecond both
        # count, and one row never counts as two steps.
        reached = if reached < n and num(row["m#{reached}"]) == 1, do: reached + 1, else: reached
        {counts, session, reached}
      end)

    close.(counts, reached)
  end

  @doc """
  Each visit's pageviews in order, at most `per_visit` of them, for
  journeys. Visits belong to the range they started in.
  """
  @spec journey_pages(t(), map(), pos_integer()) :: %{rows: [map()], sampled: boolean()}
  def journey_pages(store, query, per_visit) do
    dialect = dialect(store)
    {scope_sql, scope_params} = Sql.visit_scope(query.filters, query.site, query.from, query.to, dialect)

    newest = fn columns, limit ->
      """
      SELECT #{columns} FROM rl_sessions s WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND #{visit_sql()}#{scope_sql}
               ORDER BY s.started_at DESC, s.id LIMIT #{limit}\
      """
    end

    visit_params = [query.site, query.from, query.to] ++ scope_params

    first_row =
      first(
        store,
        "SELECT COUNT(*) AS n, MIN(started_at) AS t FROM (#{newest.("s.started_at AS started_at", Sql.journey_visits() + 1)}) x",
        visit_params
      )

    if num(first_row && first_row["n"]) == 0 do
      %{rows: [], sampled: false}
    else
      from = max(query.from, num(first_row["t"]))

      # MySQL takes no LIMIT in an IN list, but does in a table inside one.
      visits =
        if dialect == "mysql",
          do: "SELECT id FROM (#{newest.("s.id AS id", Sql.journey_visits())}) x",
          else: newest.("s.id", Sql.journey_visits())

      rows =
        all(
          store,
          """
          WITH raw AS (
                   SELECT e.session AS session, e.path AS path, e.ts AS ts, e.id AS id,
                     LAG(e.path) OVER (PARTITION BY e.session ORDER BY e.ts, e.id) AS prev
                   FROM rl_events e
                   WHERE e.site = ? AND e.kind = 'pageview' AND e.ts >= ? AND e.ts < ? AND e.session IN (#{visits})),
                 v AS (
                   SELECT session, path, ROW_NUMBER() OVER (PARTITION BY session ORDER BY ts, id) AS n
                   FROM raw WHERE prev IS NULL OR prev <> path)
                 SELECT session, path FROM v WHERE n <= ? ORDER BY session, n\
          """,
          [query.site, from, query.to + event_tail_ms()] ++ visit_params ++ [per_visit]
        )

      %{
        rows: Enum.map(rows, &%{session: str(&1["session"]), path: str(&1["path"])}),
        sampled: num(first_row["n"]) > Sql.journey_visits()
      }
    end
  end

  # API tokens

  defp token_row(r) do
    JS.obj(
      id: str(r["id"]),
      name: str(r["name"]),
      site: str(r["site"], ""),
      scope:
        case r["scope"] do
          "manage" -> "manage"
          "embed" -> "embed"
          _ -> "read"
        end,
      hash: str(r["hash"]),
      hint: str(r["hint"], ""),
      createdAt: num(r["created_at"]),
      lastUsedAt: if(r["last_used_at"] == nil, do: nil, else: num(r["last_used_at"]))
    )
  end

  @spec tokens(t()) :: [Object.t()]
  def tokens(store), do: store |> all("SELECT * FROM rl_tokens ORDER BY created_at DESC, id") |> Enum.map(&token_row/1)

  @spec token_by_hash(t(), String.t()) :: Object.t() | nil
  def token_by_hash(store, hash) do
    row = first(store, "SELECT * FROM rl_tokens WHERE hash = ?", [hash])
    row && token_row(row)
  end

  @spec insert_token(t(), Object.t()) :: :ok
  def insert_token(store, t) do
    run(
      store,
      "INSERT INTO rl_tokens (id, name, site, scope, hash, hint, created_at, last_used_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [
        t["id"],
        t["name"],
        t["site"],
        t["scope"],
        t["hash"],
        t["hint"],
        t["createdAt"],
        t["lastUsedAt"]
      ]
    )
  end

  @spec touch_token(t(), String.t(), integer()) :: :ok
  def touch_token(store, id, now), do: run(store, "UPDATE rl_tokens SET last_used_at = ? WHERE id = ?", [now, id])

  @doc "Deleting a token is how it is revoked: it stops working at once."
  @spec delete_token(t(), String.t()) :: boolean()
  def delete_token(store, id), do: changed(store, "DELETE FROM rl_tokens WHERE id = ?", [id]) == 1

  # Settings

  @spec setting(t(), String.t()) :: String.t() | nil
  def setting(store, key) do
    row = first(store, ~s(SELECT value FROM rl_settings WHERE "key" = ?), [key])
    row && str(row["value"])
  end

  @doc "Every setting whose key starts with a prefix, such as each connected install's."
  @spec settings_starting_with(t(), String.t()) :: [%{key: String.t(), value: String.t()}]
  def settings_starting_with(store, prefix) do
    for r <-
          all(store, ~s(SELECT "key", value FROM rl_settings WHERE "key" LIKE ? ESCAPE '\\'), [
            Sql.escape_like(prefix) <> "%"
          ]) do
      %{key: str(r["key"]), value: str(r["value"])}
    end
  end

  @doc "Reads a setting and deletes it. Of two callers at once, only the one whose delete took the row gets its value."
  @spec take_setting(t(), String.t()) :: String.t() | nil
  def take_setting(store, key) do
    case setting(store, key) do
      nil ->
        nil

      value ->
        sql = ~s(DELETE FROM rl_settings WHERE "key" = ?)

        gone =
          if dialect(store) == "mysql",
            do: Db.affected(store.db, sql, [key]),
            else: length(all(store, ~s(#{sql} RETURNING "key"), [key]))

        if gone == 1, do: value, else: nil
    end
  end

  @spec set_setting(t(), String.t(), String.t() | nil) :: :ok
  def set_setting(store, key, nil), do: run(store, ~s(DELETE FROM rl_settings WHERE "key" = ?), [key])

  def set_setting(store, key, value) do
    run(store, Sql.upsert(dialect(store), "rl_settings", [~s("key"), "value"], [~s("key")], ["value"]), [key, value])
  end

  # Email reports

  defp report_row(r) do
    JS.obj(
      id: str(r["id"]),
      site: str(r["site"]),
      email: str(r["email"]),
      frequency: str(r["frequency"]),
      lang: str(r["lang"], "en"),
      token: str(r["token"]),
      origin: str(r["origin"], ""),
      lastPeriod: str(r["last_period"], ""),
      lastSentAt: if(r["last_sent_at"] == nil, do: nil, else: num(r["last_sent_at"])),
      createdAt: num(r["created_at"])
    )
  end

  @spec reports(t(), String.t() | nil) :: [Object.t()]
  def reports(store, site \\ nil) do
    rows =
      if site,
        do: all(store, "SELECT * FROM rl_reports WHERE site = ? ORDER BY created_at, id", [site]),
        else: all(store, "SELECT * FROM rl_reports ORDER BY created_at, id")

    Enum.map(rows, &report_row/1)
  end

  @spec report_by(t(), :id | :token, String.t()) :: Object.t() | nil
  def report_by(store, field, value) do
    row = first(store, "SELECT * FROM rl_reports WHERE #{if field == :id, do: "id", else: "token"} = ?", [value])
    row && report_row(row)
  end

  @spec insert_report(t(), Object.t()) :: :ok
  def insert_report(store, r) do
    run(
      store,
      "INSERT INTO rl_reports (id, site, email, frequency, lang, token, origin, last_period, last_sent_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [
        r["id"],
        r["site"],
        r["email"],
        r["frequency"],
        r["lang"],
        r["token"],
        r["origin"],
        r["lastPeriod"],
        r["lastSentAt"],
        r["createdAt"]
      ]
    )
  end

  @doc "Records a period as sent. Only one caller wins, so two cron runs at once cannot both send it."
  @spec claim_report(t(), String.t(), String.t(), integer()) :: boolean()
  def claim_report(store, id, period, now) do
    changed(store, "UPDATE rl_reports SET last_period = ?, last_sent_at = ? WHERE id = ? AND last_period <> ?", [
      period,
      now,
      id,
      period
    ]) == 1
  end

  @doc "Puts a period back when its email failed, so the next run tries again."
  @spec release_report(t(), String.t(), String.t(), String.t()) :: :ok
  def release_report(store, id, period, previous) do
    run(store, "UPDATE rl_reports SET last_period = ? WHERE id = ? AND last_period = ?", [previous, id, period])
  end

  @spec delete_report(t(), String.t()) :: :ok
  def delete_report(store, id), do: run(store, "DELETE FROM rl_reports WHERE id = ?", [id])

  # Goals

  defp goal_row(store, r) do
    # Postgres keeps the value as a 4-byte REAL, which node-postgres reads from its shortest text.
    value = num(JS.nullish(r["value"], 0)) |> then(&if(dialect(store) == "postgres", do: JS.float32(&1), else: &1))

    JS.obj(
      id: str(r["id"]),
      site: str(r["site"]),
      name: str(r["name"]),
      kind: str(r["kind"]),
      match: str(r["match"]),
      clickBy: str(r["click_by"], ""),
      valueMode: str(r["value_mode"]),
      value: JS.normalize(value),
      valueProp: str(r["value_prop"], ""),
      currency: str(r["currency"], "USD"),
      createdAt: num(r["created_at"])
    )
  end

  @spec goals(t(), String.t() | nil) :: [Object.t()]
  def goals(store, site \\ nil) do
    rows =
      if site,
        do: all(store, "SELECT * FROM rl_goals WHERE site = ? ORDER BY created_at, id", [site]),
        else: all(store, "SELECT * FROM rl_goals ORDER BY created_at, id")

    Enum.map(rows, &goal_row(store, &1))
  end

  @spec goal_by_id(t(), String.t()) :: Object.t() | nil
  def goal_by_id(store, id) do
    row = first(store, "SELECT * FROM rl_goals WHERE id = ?", [id])
    row && goal_row(store, row)
  end

  @spec save_goal(t(), Object.t(), Object.t() | nil) :: :ok
  def save_goal(store, g, before \\ nil) do
    # A click goal is counted by its name, which the tracker sends as the event name. Renaming one renames
    # its past clicks too, so its history stays.
    if before && before["kind"] == "click" && g["kind"] == "click" && before["name"] != g["name"] do
      run(store, "UPDATE rl_events SET name = ? WHERE site = ? AND kind = 'event' AND name = ?", [
        g["name"],
        g["site"],
        before["name"]
      ])
    end

    run(
      store,
      Sql.upsert(
        dialect(store),
        "rl_goals",
        [
          "id",
          "site",
          "name",
          "kind",
          ~s("match"),
          "click_by",
          "value_mode",
          "value",
          "value_prop",
          "currency",
          "created_at"
        ],
        ["id"],
        ["name", "kind", ~s("match"), "click_by", "value_mode", "value", "value_prop", "currency"]
      ),
      [
        g["id"],
        g["site"],
        g["name"],
        g["kind"],
        g["match"],
        g["clickBy"],
        g["valueMode"],
        g["value"],
        g["valueProp"],
        g["currency"],
        g["createdAt"]
      ]
    )
  end

  @spec delete_goal(t(), String.t()) :: :ok
  def delete_goal(store, id), do: run(store, "DELETE FROM rl_goals WHERE id = ?", [id])

  # The events a goal counts, as a WHERE fragment over rl_events e.
  defp goal_scope(store, goal) do
    if goal["kind"] == "page" do
      cond do
        not String.contains?(goal["match"], "*") ->
          {"e.kind = 'pageview' AND e.path = ?", [goal["match"]]}

        dialect(store) != "sqlite" ->
          # Postgres's LIKE heeds case, and so does MySQL's under Runlight's binary collation.
          {"e.kind = 'pageview' AND e.path LIKE ? ESCAPE '\\'", [Sql.like_pattern(goal["match"])]}

        true ->
          # SQLite's LIKE ignores case; GLOB does not, so every database agrees with the others and with exact matches.
          {"e.kind = 'pageview' AND e.path GLOB ?", [Sql.glob_pattern(goal["match"])]}
      end
    else
      # Event goals count the named event; click goals count the event the tracker sends for them.
      {"e.kind = 'event' AND e.name = ?", [if(goal["kind"] == "click", do: goal["name"], else: goal["match"])]}
    end
  end

  # A numeric event property for one row, as SQL (0 when it is not a number). Property names are checked first.
  defp prop_value(store, prop) do
    case dialect(store) do
      "postgres" ->
        {"(CASE WHEN (e.props::jsonb ->> ?) ~ '^-?[0-9]+(\\.[0-9]+)?$' THEN (e.props::jsonb ->> ?)::numeric ELSE 0 END)",
         [prop, prop]}

      "mysql" ->
        path = ~s($."#{prop}")
        value = "JSON_EXTRACT(e.props, ?)"

        {"""
         (CASE
                   WHEN JSON_TYPE(#{value}) IN ('INTEGER', 'UNSIGNED INTEGER', 'DOUBLE', 'DECIMAL') THEN CAST(#{value} AS DOUBLE)
                   WHEN JSON_TYPE(#{value}) = 'STRING' AND JSON_UNQUOTE(#{value}) REGEXP '^-?[0-9]+([.][0-9]+)?$' THEN CAST(JSON_UNQUOTE(#{value}) AS DOUBLE)
                   ELSE 0 END)\
         """, List.duplicate(path, 5)}

      _ ->
        path = ~s($."#{prop}")
        text = "CAST(json_extract(e.props, ?) AS TEXT)"

        {"""
         (CASE
                 WHEN json_type(e.props, ?) IN ('integer', 'real') THEN json_extract(e.props, ?)
                 WHEN json_type(e.props, ?) = 'text' AND #{text} GLOB '[0-9]*' AND #{text} NOT GLOB '*[^0-9.]*' AND #{text} NOT GLOB '*.*.*' AND #{text} NOT GLOB '*.' THEN CAST(#{text} AS REAL)
                 WHEN json_type(e.props, ?) = 'text' AND #{text} GLOB '-[0-9]*' AND substr(#{text}, 2) NOT GLOB '*[^0-9.]*' AND #{text} NOT GLOB '*.*.*' AND #{text} NOT GLOB '*.' THEN CAST(#{text} AS REAL)
                 ELSE 0 END)\
         """, List.duplicate(path, 14)}
    end
  end

  # Ties are broken by the value in code point order, the order the rolled-up path sorts in.
  defp text_order(store) do
    case dialect(store) do
      "postgres" -> ~s( COLLATE "C")
      "mysql" -> " COLLATE #{Sql.mysql_collation()}"
      _ -> ""
    end
  end

  defp double(store), do: if(dialect(store) == "mysql", do: "DOUBLE", else: "DOUBLE PRECISION")

  @doc "The property names sent with an event in a query's range, most used first."
  @spec event_prop_keys(t(), map(), String.t()) :: [Object.t()]
  def event_prop_keys(store, query, event) do
    {v_from, v_sql, v_params} = Sql.visit_rows(query.filters, query.site, query.from, query.to, dialect(store))
    where = "#{v_sql} AND e.kind = 'event' AND e.name = ? AND e.props IS NOT NULL"
    params = v_params ++ [event]

    rows =
      case dialect(store) do
        "mysql" ->
          all(
            store,
            """
            SELECT j.k AS "key", COUNT(*) AS events FROM #{v_from}
                         CROSS JOIN JSON_TABLE(JSON_KEYS(CASE WHEN JSON_TYPE(e.props) = 'OBJECT' THEN e.props ELSE '{}' END), '$[*]' COLUMNS (k VARCHAR(255) COLLATE #{Sql.mysql_collation()} PATH '$')) j
                         WHERE #{where} GROUP BY j.k ORDER BY events DESC, j.k LIMIT 30\
            """,
            params
          )

        "postgres" ->
          all(
            store,
            """
            SELECT k AS "key", COUNT(*) AS events FROM #{v_from} CROSS JOIN LATERAL jsonb_object_keys(CASE WHEN jsonb_typeof(e.props::jsonb) = 'object' THEN e.props::jsonb ELSE '{}'::jsonb END) AS k
                         WHERE #{where} GROUP BY k ORDER BY events DESC, k#{text_order(store)} LIMIT 30\
            """,
            params
          )

        _ ->
          all(
            store,
            """
            SELECT j.key AS "key", COUNT(*) AS events FROM #{v_from}, json_each(e.props) j
                         WHERE #{where} AND json_type(e.props) = 'object' GROUP BY j.key ORDER BY events DESC, key#{text_order(store)} LIMIT 30\
            """,
            params
          )
      end

    Enum.map(rows, &JS.obj(key: str(&1["key"]), events: num(&1["events"])))
  end

  @doc "The values one property of an event took, with how often and by how many visitors."
  @spec event_prop_values(t(), map(), String.t(), String.t(), pos_integer()) :: [Object.t()]
  def event_prop_values(store, query, event, key, limit) do
    dialect = dialect(store)
    {v_from, v_sql, v_params} = Sql.visit_rows(query.filters, query.site, query.from, query.to, dialect)

    value =
      case dialect do
        "postgres" -> "(e.props::jsonb ->> ?)"
        "mysql" -> "(JSON_UNQUOTE(JSON_EXTRACT(e.props, ?)) COLLATE #{Sql.mysql_collation()})"
        _ -> "CAST(json_extract(e.props, ?) AS TEXT)"
      end

    path = if dialect == "postgres", do: key, else: ~s($."#{key}")

    rows =
      all(
        store,
        """
        SELECT * FROM (SELECT #{value} AS value, COUNT(*) AS events, COUNT(DISTINCT e.visitor) AS visitors FROM #{v_from}
                 WHERE #{v_sql} AND e.kind = 'event' AND e.name = ? AND #{value} IS NOT NULL GROUP BY 1) t
               ORDER BY events DESC, value#{text_order(store)} LIMIT ?\
        """,
        [path] ++ v_params ++ [event, path, limit]
      )

    Enum.map(rows, &JS.obj(value: str(&1["value"]), events: num(&1["events"]), visitors: num(&1["visitors"])))
  end

  # A goal's worth for one converting row, as SQL.
  defp revenue_value(store, goal) do
    cond do
      goal["valueMode"] == "prop" and goal["valueProp"] != "" -> prop_value(store, goal["valueProp"])
      goal["valueMode"] == "fixed" -> {"CAST(? AS #{double(store)})", [goal["value"]]}
      true -> {"0", []}
    end
  end

  defp revenue_sql(store, goal) do
    cond do
      goal["valueMode"] == "prop" and goal["valueProp"] != "" ->
        {sql, params} = prop_value(store, goal["valueProp"])
        {"SUM(#{sql})", params}

      # Cast, so Postgres does not read the bound value as a bigint and refuse 9.99.
      goal["valueMode"] == "fixed" ->
        {"COUNT(*) * CAST(? AS #{double(store)})", [goal["value"]]}

      true ->
        {"0", []}
    end
  end

  defp money(n), do: JS.normalize(JS.round(num(n) * 100) / 100)

  @doc "Every goal's totals in one pass over the range's events, by goal id."
  @spec goal_totals_all(t(), map(), [Object.t()]) :: %{String.t() => Object.t()}
  def goal_totals_all(store, query, goals) do
    {v_from, v_sql, v_params} = Sql.visit_rows(query.filters, query.site, query.from, query.to, dialect(store))

    # As many goals per query as keep it under D1's parameter limit.
    {chunks, _} =
      Enum.reduce(goals, {[[]], length(v_params)}, fn goal, {chunks, count} ->
        {_, scope_params} = goal_scope(store, goal)
        {_, value_params} = revenue_value(store, goal)
        cost = length(scope_params) * 4 + length(value_params)
        [current | done] = chunks

        if current != [] and count + cost > Sql.max_params(),
          do: {[[goal] | [Enum.reverse(current) | done]], length(v_params) + cost},
          else: {[[goal | current] | done], count + cost}
      end)

    chunks = chunks |> then(fn [current | done] -> [Enum.reverse(current) | done] end) |> Enum.reverse()

    Enum.reduce(chunks, %{}, fn chunk, out ->
      if chunk == [] do
        out
      else
        {columns, params, any, any_params} =
          chunk
          |> Enum.with_index()
          |> Enum.reduce({[], [], [], []}, fn {goal, i}, {columns, params, any, any_params} ->
            {scope_sql, scope_params} = goal_scope(store, goal)
            {value_sql, value_params} = revenue_value(store, goal)

            {columns ++
               [
                 "SUM(CASE WHEN #{scope_sql} THEN 1 ELSE 0 END) AS c#{i}",
                 "COUNT(DISTINCT CASE WHEN #{scope_sql} THEN e.visitor END) AS v#{i}",
                 "SUM(CASE WHEN #{scope_sql} THEN #{value_sql} ELSE 0 END) AS r#{i}"
               ], params ++ scope_params ++ scope_params ++ scope_params ++ value_params, any ++ ["(#{scope_sql})"],
             any_params ++ scope_params}
          end)

        row =
          first(
            store,
            """
            SELECT #{Enum.join(columns, ", ")} FROM #{v_from}
                     WHERE #{v_sql} AND e.kind IN ('pageview', 'event') AND (#{Enum.join(any, " OR ")})\
            """,
            params ++ v_params ++ any_params
          )

        chunk
        |> Enum.with_index()
        |> Enum.reduce(out, fn {goal, i}, out ->
          Map.put(
            out,
            goal["id"],
            JS.obj(
              conversions: num(row && row["c#{i}"]),
              visitors: num(row && row["v#{i}"]),
              revenue: money(row && row["r#{i}"])
            )
          )
        end)
      end
    end)
  end

  @doc "One goal's conversions, converting visitors, and revenue for a query's range and filters."
  @spec goal_totals(t(), map(), Object.t()) :: Object.t()
  def goal_totals(store, query, goal) do
    {v_from, v_sql, v_params} = Sql.visit_rows(query.filters, query.site, query.from, query.to, dialect(store))
    {scope_sql, scope_params} = goal_scope(store, goal)
    {revenue, revenue_params} = revenue_sql(store, goal)

    row =
      first(
        store,
        """
        SELECT COUNT(*) AS conversions, COUNT(DISTINCT e.visitor) AS visitors, #{revenue} AS revenue
               FROM #{v_from} WHERE #{v_sql} AND #{scope_sql}\
        """,
        revenue_params ++ v_params ++ scope_params
      )

    JS.obj(
      conversions: num(row && row["conversions"]),
      visitors: num(row && row["visitors"]),
      revenue: money(row && row["revenue"])
    )
  end

  @doc "A goal's conversions split by where the visit came from, or by the page it happened on."
  @spec goal_breakdown(t(), map(), Object.t(), String.t(), pos_integer()) :: [Object.t()]
  def goal_breakdown(store, query, goal, by, limit \\ 10) do
    {v_from, v_sql, v_params} = Sql.visit_rows(query.filters, query.site, query.from, query.to, dialect(store))
    col = if by == "path", do: "e.path", else: "s.#{by}"
    {scope_sql, scope_params} = goal_scope(store, goal)
    {revenue, revenue_params} = revenue_sql(store, goal)

    rows =
      all(
        store,
        """
        SELECT #{col} AS value, COUNT(*) AS conversions, COUNT(DISTINCT e.visitor) AS visitors, #{revenue} AS revenue
               FROM #{v_from} WHERE #{v_sql} AND #{scope_sql}
               GROUP BY #{col} ORDER BY conversions DESC, #{col}#{text_order(store)} LIMIT ?\
        """,
        revenue_params ++ v_params ++ scope_params ++ [limit]
      )

    Enum.map(rows, fn r ->
      JS.obj(
        value: str(r["value"], ""),
        conversions: num(r["conversions"]),
        visitors: num(r["visitors"]),
        revenue: money(r["revenue"])
      )
    end)
  end

  defp in_pieces(items, size, fun), do: items |> Enum.chunk_every(size) |> Enum.flat_map(fun)

  @doc "A goal's conversions and revenue in each bucket, by when each visit started."
  @spec goal_series(t(), map(), Object.t(), [map()]) :: [Object.t()]
  def goal_series(_store, _query, _goal, []), do: []

  def goal_series(store, query, goal, buckets) do
    dialect = dialect(store)
    {scope_sql, scope_params} = goal_scope(store, goal)
    {revenue, revenue_params} = revenue_sql(store, goal)
    {_, _, zero_params} = Sql.visit_rows(query.filters, query.site, 0, 0, dialect)
    # Each bucket binds three values; the rest are fixed. As many buckets a statement as keep it under D1's 100.
    fixed = length(revenue_params) + length(scope_params) + length(zero_params)
    size = max(1, min(Sql.buckets_per_query(), div(Sql.max_params() - fixed, 3)))

    if length(buckets) > size do
      in_pieces(buckets, size, &goal_series(store, query, goal, &1))
    else
      {v_from, v_sql, v_params} =
        Sql.visit_rows(query.filters, query.site, hd(buckets).start, List.last(buckets).end, dialect)

      rows =
        all(
          store,
          """
          WITH b (i, bs, be) AS (#{Sql.bucket_table(dialect, buckets)})
                 SELECT b.i AS i, COUNT(*) AS conversions, #{revenue} AS revenue
                 FROM #{v_from} CROSS JOIN b
                 WHERE #{v_sql} AND s.started_at >= b.bs AND s.started_at < b.be AND #{scope_sql}
                 GROUP BY b.i\
          """,
          bucket_params(buckets) ++ revenue_params ++ v_params ++ scope_params
        )

      found = Map.new(rows, &{num(&1["i"]), &1})

      buckets
      |> Enum.with_index()
      |> Enum.map(fn {b, i} ->
        r = found[i]
        JS.obj(start: b.start, conversions: num(r && r["conversions"]), revenue: money(r && r["revenue"]))
      end)
    end
  end

  defp bucket_params(buckets), do: buckets |> Enum.with_index() |> Enum.flat_map(fn {b, i} -> [i, b.start, b.end] end)

  @spec link_domains(t()) :: [Object.t()]
  def link_domains(store), do: all(store, "SELECT domain, site FROM rl_link_domains ORDER BY domain")

  @spec add_link_domain(t(), String.t(), String.t(), integer()) :: :ok
  def add_link_domain(store, domain, site, now) do
    run(store, Sql.upsert(dialect(store), "rl_link_domains", ["domain", "site", "created_at"], ["domain"], []), [
      domain,
      site,
      now
    ])
  end

  @doc "Removes a domain. Its links keep it as their home and fall back to the app's own link path until it is added again."
  @spec remove_link_domain(t(), String.t()) :: :ok
  def remove_link_domain(store, domain), do: run(store, "DELETE FROM rl_link_domains WHERE domain = ?", [domain])

  @doc "A site's links, newest first, with their clicks in a range."
  @spec links(t(), String.t(), integer(), integer()) :: [Object.t()]
  def links(store, site, from, to) do
    rows =
      all(
        store,
        """
        SELECT l.*, COALESCE(c.clicks, 0) AS clicks, COALESCE(c.visitors, 0) AS visitors
               FROM rl_links l LEFT JOIN (
                 SELECT link, COUNT(*) AS clicks, COUNT(DISTINCT NULLIF(visitor, '')) AS visitors FROM rl_events
                 WHERE site = ? AND kind = 'click' AND ts >= ? AND ts < ? GROUP BY link
               ) c ON c.link = l.id
               WHERE l.site = ? AND l.deleted_at IS NULL
               ORDER BY l.created_at DESC, l.id\
        """,
        [site, from, to, site]
      )

    Enum.map(rows, fn row ->
      row |> link_row() |> Object.put("clicks", num(row["clicks"])) |> Object.put("visitors", num(row["visitors"]))
    end)
  end

  @doc "One link's clicks per bucket."
  @spec link_series(t(), String.t(), String.t(), [map()]) :: [Object.t()]
  def link_series(_store, _site, _link, []), do: []

  def link_series(store, site, link, buckets) do
    if length(buckets) > Sql.buckets_per_query() do
      in_pieces(buckets, Sql.buckets_per_query(), &link_series(store, site, link, &1))
    else
      rows =
        all(
          store,
          """
          WITH b (i, bs, be) AS (#{Sql.bucket_table(dialect(store), buckets)})
                 SELECT b.i AS i, COUNT(*) AS clicks, COUNT(DISTINCT NULLIF(e.visitor, '')) AS visitors
                 FROM b JOIN rl_events e ON e.link = ? AND e.ts >= b.bs AND e.ts < b.be
                 WHERE e.site = ? AND e.kind = 'click' GROUP BY b.i\
          """,
          bucket_params(buckets) ++ [link, site]
        )

      found = Map.new(rows, &{num(&1["i"]), &1})

      buckets
      |> Enum.with_index()
      |> Enum.map(fn {b, i} ->
        r = found[i]
        JS.obj(start: b.start, clicks: num(r && r["clicks"]), visitors: num(r && r["visitors"]))
      end)
    end
  end

  @doc "One link's clicks by a visit dimension."
  @spec link_breakdown(t(), String.t(), String.t(), integer(), integer(), String.t(), pos_integer()) :: [Object.t()]
  def link_breakdown(store, site, link, from, to, dimension, limit) do
    col = "s." <> Query.session_column(dimension)

    rows =
      all(
        store,
        """
        SELECT #{col} AS value, COUNT(*) AS clicks, COUNT(DISTINCT e.visitor) AS visitors
               FROM rl_events e JOIN rl_sessions s ON s.id = e.session
               WHERE e.site = ? AND e.link = ? AND e.kind = 'click' AND e.ts >= ? AND e.ts < ? AND #{col} <> ''
               GROUP BY #{col} ORDER BY clicks DESC, #{col}#{text_order(store)} LIMIT ?\
        """,
        [site, link, from, to, limit]
      )

    Enum.map(rows, &JS.obj(value: str(&1["value"]), visitors: num(&1["visitors"]), events: num(&1["clicks"])))
  end

  # Reports

  @doc "When Runlight itself first counted a visit, leaving out imported history."
  @spec first_own_visit(t(), String.t()) :: number() | nil
  def first_own_visit(store, site) do
    row =
      first(
        store,
        "SELECT MIN(started_at) AS t FROM rl_sessions s WHERE s.site = ? AND s.imported = 0 AND #{visit_sql()}",
        [site]
      )

    if row == nil or row["t"] == nil, do: nil, else: num(row["t"])
  end

  @doc "When the site's first visit was recorded, or nil with no data yet."
  @spec first_seen(t(), String.t()) :: number() | nil
  def first_seen(store, site) do
    row = first(store, "SELECT MIN(started_at) AS t FROM rl_sessions WHERE site = ?", [site])
    if row == nil or row["t"] == nil, do: nil, else: num(row["t"])
  end

  @doc "Just the visitor count from stats, in one query, for conversion rates."
  @spec visitors(t(), map()) :: number()
  def visitors(store, query) do
    {scope_sql, scope_params} = Sql.visit_scope(query.filters, query.site, query.from, query.to, dialect(store))

    row =
      first(
        store,
        "SELECT COUNT(DISTINCT s.visitor) AS visitors FROM rl_sessions s WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND #{visit_sql()}#{scope_sql}",
        [query.site, query.from, query.to] ++ scope_params
      )

    num(row && row["visitors"])
  end

  @doc "The headline numbers for a query."
  @spec stats(t(), map()) :: Object.t()
  def stats(store, query) do
    rolled_stats(store, query) || raw_stats(store, query)
  end

  defp raw_stats(store, query) do
    dialect = dialect(store)
    # Filtered or not, the numbers describe visits that started in the range (see visit_scope).
    {scope_sql, scope_params} = Sql.visit_scope(query.filters, query.site, query.from, query.to, dialect)
    pv = Sql.pageviews_of(query.filters, query.site, query.from, query.to, dialect)

    row =
      first(
        store,
        """
        SELECT COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits, SUM(#{if pv, do: "COALESCE(pv.n, 0)", else: "s.pageviews"}) AS pageviews,
                 SUM(CASE WHEN #{bounce()} THEN 1 ELSE 0 END) AS bounced, SUM(#{duration()}) AS duration
               FROM rl_sessions s #{if pv, do: "LEFT JOIN #{elem(pv, 0)} pv ON pv.session = s.id", else: ""}
               WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND #{visit_sql()}#{scope_sql}\
        """,
        pv_params(pv) ++ [query.site, query.from, query.to] ++ scope_params
      )

    stats_obj(
      num(row && row["visitors"]),
      num(row && row["visits"]),
      num(row && row["pageviews"]),
      num(row && row["bounced"]),
      num(row && row["duration"])
    )
  end

  defp pv_params(nil), do: []
  defp pv_params({_, params}), do: params

  @doc "The headline numbers for each bucket."
  @spec series(t(), map(), [map()]) :: [Object.t()]
  def series(_store, _query, []), do: []

  def series(store, query, buckets) do
    if length(buckets) > Sql.buckets_per_query() do
      in_pieces(buckets, Sql.buckets_per_query(), &series(store, query, &1))
    else
      series_piece(store, query, buckets)
    end
  end

  defp series_piece(store, query, buckets) do
    dialect = dialect(store)
    params = bucket_params(buckets)
    first_start = hd(buckets).start
    last_end = List.last(buckets).end
    # Filtered or not, each bucket counts the visits that started in it (see visit_scope).
    {scope_sql, scope_params} = Sql.visit_scope(query.filters, query.site, first_start, last_end, dialect)
    pv = Sql.pageviews_of(query.filters, query.site, first_start, last_end, dialect)
    # Built days that fit inside one bucket come from rollups; the rest from the visits.
    plan = rollup_plan(store, query, first_start, last_end)
    in_bucket = fn d -> Enum.find_index(buckets, &(&1.start <= d.start and d.end <= &1.end)) end
    used = if plan, do: Enum.filter(plan.days, &(in_bucket.(&1) != nil)), else: []

    rest =
      if used != [] do
        {rest, from} =
          Enum.reduce(used, {[], first_start}, fn d, {rest, from} ->
            rest = if d.start > from, do: rest ++ [{from, d.start}], else: rest
            {rest, max(from, d.end)}
          end)

        if from < last_end, do: rest ++ [{from, last_end}], else: rest
      end

    # MySQL joins the buckets to every visit of the site unless told the whole range as well.
    {w_sql, w_params} =
      cond do
        rest != nil -> within(rest)
        dialect == "mysql" -> within([{first_start, last_end}])
        true -> {"1 = 1", []}
      end

    # Filters and scattered unbuilt days add values of their own; past D1's 100, the buckets go in halves.
    if length(params) + 1 + length(w_params) + length(scope_params) + length(pv_params(pv)) > Sql.max_params() and
         length(buckets) > 1 do
      half = div(length(buckets) + 1, 2)
      series(store, query, Enum.take(buckets, half)) ++ series(store, query, Enum.drop(buckets, half))
    else
      bump = fn sums, i, row ->
        into = Map.get(sums, i, %{"visitors" => 0, "n" => 0, "views" => 0, "bounced" => 0, "duration" => 0})
        Map.put(sums, i, Map.new(into, fn {k, v} -> {k, v + num(row[k])} end))
      end

      sums =
        if used != [] do
          rolled =
            all(
              store,
              "SELECT day, visitors, visits AS n, pageviews AS views, bounced, duration FROM rl_rollups WHERE site = ? AND dim = '' AND day IN (#{built_days()})",
              [query.site, query.site, first_start, last_end]
            )

          at = Map.new(used, &{&1.day, in_bucket.(&1)})

          Enum.reduce(rolled, %{}, fn row, sums ->
            case Map.fetch(at, str(row["day"])) do
              {:ok, i} -> bump.(sums, i, row)
              :error -> sums
            end
          end)
        else
          %{}
        end

      rows =
        all(
          store,
          """
          WITH b (i, bs, be) AS (#{Sql.bucket_table(dialect, buckets)})
                 SELECT b.i AS i, COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS n, SUM(#{if pv, do: "COALESCE(pv.n, 0)", else: "s.pageviews"}) AS views,
                   SUM(CASE WHEN #{bounce()} THEN 1 ELSE 0 END) AS bounced, SUM(#{duration()}) AS duration
                 FROM b JOIN rl_sessions s ON s.site = ? AND s.started_at >= b.bs AND s.started_at < b.be
                 #{if pv, do: "LEFT JOIN #{elem(pv, 0)} pv ON pv.session = s.id", else: ""}
                 WHERE #{visit_sql()}#{scope_sql} AND #{w_sql}
                 GROUP BY b.i\
          """,
          params ++ [query.site] ++ pv_params(pv) ++ scope_params ++ w_params
        )

      sums = Enum.reduce(rows, sums, fn row, sums -> bump.(sums, num(row["i"]), row) end)

      buckets
      |> Enum.with_index()
      |> Enum.map(fn {bucket, i} ->
        row = sums[i]
        n = num(row && row["n"])
        views = num(row && row["views"])

        JS.obj(
          start: bucket.start,
          visitors: num(row && row["visitors"]),
          visits: n,
          pageviews: views,
          viewsPerVisit: if(n > 0, do: JS.round(views / n * 100) / 100, else: 0),
          bounceRate: if(n > 0, do: num(row["bounced"]) / n, else: 0),
          visitDuration: if(n > 0, do: JS.round(num(row["duration"]) / n), else: 0)
        )
      end)
    end
  end

  @doc "The top values of a dimension, `limit` from `offset`."
  @spec breakdown(t(), map(), String.t(), pos_integer(), non_neg_integer()) :: [Object.t()]
  def breakdown(store, query, dimension, limit, offset) do
    page = [limit, offset]

    if dimension in ["ai_agent", "ai_page"] do
      col = if dimension == "ai_agent", do: "e.name", else: "e.path"

      rows =
        all(
          store,
          """
          SELECT #{col} AS value, COUNT(*) AS fetches FROM rl_events e
                 WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'fetch'
                 GROUP BY #{col} ORDER BY fetches DESC, #{col}#{text_order(store)} LIMIT ? OFFSET ?\
          """,
          [query.site, query.from, query.to] ++ page
        )

      Enum.map(rows, &JS.obj(value: str(&1["value"]), visitors: 0, fetches: num(&1["fetches"])))
    else
      rolled_breakdown(store, query, dimension, limit, offset) || raw_breakdown(store, query, dimension, page)
    end
  end

  defp raw_breakdown(store, query, dimension, page) do
    dialect = dialect(store)
    # Filtered or not, the visits are those that started in the range (see visit_scope).
    {scope_sql, scope_params} = Sql.visit_scope(query.filters, query.site, query.from, query.to, dialect)

    cond do
      Query.session_dimension?(dimension) ->
        pv = Sql.pageviews_of(query.filters, query.site, query.from, query.to, dialect)
        col = "s." <> Query.session_column(dimension)
        entry_exit = dimension in ["entry", "exit"]

        rows =
          all(
            store,
            """
            SELECT #{col} AS value, COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits, SUM(#{if pv, do: "COALESCE(pv.n, 0)", else: "s.pageviews"}) AS pageviews,
                       SUM(CASE WHEN #{bounce()} THEN 1 ELSE 0 END) AS bounced, SUM(#{duration()}) AS duration
                     FROM rl_sessions s #{if pv, do: "LEFT JOIN #{elem(pv, 0)} pv ON pv.session = s.id", else: ""}
                     WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND #{visit_sql()}#{scope_sql} AND #{col} <> ''
                     GROUP BY #{col} ORDER BY #{if entry_exit, do: "visits DESC", else: "visitors DESC, visits DESC"}, #{col}#{text_order(store)} LIMIT ? OFFSET ?\
            """,
            pv_params(pv) ++ [query.site, query.from, query.to] ++ scope_params ++ page
          )

        Enum.map(rows, fn row ->
          visits = num(row["visits"])

          out =
            JS.obj(
              value: str(row["value"]),
              visitors: num(row["visitors"]),
              visits: visits,
              bounceRate: if(visits > 0, do: num(row["bounced"]) / visits, else: 0)
            )

          if entry_exit,
            do: out,
            else:
              out
              |> Object.put("pageviews", num(row["pageviews"]))
              |> Object.put("visitDuration", if(visits > 0, do: JS.round(num(row["duration"]) / visits), else: 0))
        end)

      dimension in ["page", "hostname"] ->
        col = "e." <> Query.event_column(dimension)
        {w_sql, w_params, w_to} = within_rows(store, query, scope_sql, scope_params, ["page", "hostname"])

        rows =
          all(
            store,
            """
            SELECT #{col} AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(*) AS pageviews, #{live_views()} AS views
                     FROM rl_events e
                     WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'pageview'#{w_sql}
                     GROUP BY #{col} ORDER BY visitors DESC, pageviews DESC, #{col}#{text_order(store)} LIMIT ? OFFSET ?\
            """,
            [query.site, query.from, w_to] ++ w_params ++ page
          )

        out =
          Enum.map(
            rows,
            &JS.obj(value: str(&1["value"]), visitors: num(&1["visitors"]), pageviews: num(&1["pageviews"]))
          )

        live = Map.new(rows, &{str(&1["value"]), num(&1["views"])})

        if dimension == "page" and out != [] do
          # Each pageview's engaged time added up and its deepest scroll, then the mean over pageviews.
          size = max(1, min(Sql.values_per_query(), Sql.max_params() - 3 - length(w_params)))

          times =
            in_pieces(out, size, fn piece ->
              all(
                store,
                """
                SELECT value, SUM(total) AS total, COUNT(*) AS views, AVG(deepest) AS scroll FROM (
                               SELECT e.path AS value, SUM(e.engaged_ms) AS total, MAX(e.scroll) AS deepest
                               FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'engagement'#{w_sql}
                               AND e.path IN (#{Enum.map_join(piece, ", ", fn _ -> "?" end)}) GROUP BY e.path, e.pageview) t GROUP BY value\
                """,
                [query.site, query.from, w_to] ++ w_params ++ Enum.map(piece, & &1["value"])
              )
            end)

          by_path = Map.new(times, &{str(&1["value"]), &1})

          Enum.map(out, fn row ->
            time = by_path[row["value"]]
            views = Map.get(live, row["value"], 0)

            row
            |> Object.put("timeOnPage", if(time && views != 0, do: JS.round(num(time["total"]) / views), else: 0))
            |> Object.put(
              "scrollDepth",
              if(time == nil or time["scroll"] == nil, do: 0, else: JS.round(num(time["scroll"])))
            )
          end)
        else
          out
        end

      dimension == "event" ->
        {w_sql, w_params, w_to} = within_rows(store, query, scope_sql, scope_params, ["event"])

        rows =
          all(
            store,
            """
            SELECT e.name AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(*) AS events
                     FROM rl_events e
                     WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'event'#{w_sql}
                     GROUP BY e.name ORDER BY visitors DESC, events DESC, e.name#{text_order(store)} LIMIT ? OFFSET ?\
            """,
            [query.site, query.from, w_to] ++ w_params ++ page
          )

        Enum.map(rows, &JS.obj(value: str(&1["value"]), visitors: num(&1["visitors"]), events: num(&1["events"])))

      true ->
        []
    end
  end

  # Rows from the visits that started in the range and that the filters pick, narrowed by any filter on the same
  # kind of row, as the rollups count them.
  defp within_rows(store, query, scope_sql, scope_params, dimensions) do
    {rows_sql, rows_params} = Sql.row_scope(query.filters, dimensions, dialect(store))

    {" AND e.session IN (SELECT s.id FROM rl_sessions s WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND #{visit_sql()}#{scope_sql})#{rows_sql}",
     [query.site, query.from, query.to] ++ scope_params ++ rows_params, query.to + event_tail_ms()}
  end

  @doc """
  Visits by quarter hour since the epoch, which the caller folds into local
  weekdays and hours, keeping time zones out of SQL.
  """
  @spec hourly(t(), map()) :: [map()]
  def hourly(store, query) do
    dialect = dialect(store)

    case rollup_plan(store, query, query.from, query.to) do
      nil ->
        matching = Sql.visit_scope(query.filters, query.site, query.from, query.to, dialect)
        {matching_sql, matching_params} = matching
        # A page filter counts that page's views as pageviews here too, as the cards do.
        pv = Sql.pageviews_of(query.filters, query.site, query.from, query.to, dialect)

        rows =
          all(
            store,
            """
            SELECT #{Sql.div(dialect, "s.started_at", 900_000)} AS quarter, COUNT(*) AS visits, COUNT(DISTINCT s.visitor) AS visitors,
                     SUM(#{if pv, do: "COALESCE(pv.n, 0)", else: "s.pageviews"}) AS pageviews, SUM(CASE WHEN #{bounce()} THEN 1 ELSE 0 END) AS bounced
                   FROM rl_sessions s #{if pv, do: "LEFT JOIN #{elem(pv, 0)} pv ON pv.session = s.id", else: ""}
                   WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND #{visit_sql()}#{matching_sql}
                   GROUP BY 1\
            """,
            pv_params(pv) ++ [query.site, query.from, query.to] ++ matching_params
          )

        Enum.map(rows, fn row ->
          %{
            quarter: JS.floor(num(row["quarter"])),
            visits: num(row["visits"]),
            visitors: num(row["visitors"]),
            pageviews: num(row["pageviews"]),
            bounced: num(row["bounced"])
          }
        end)

      plan ->
        bump = fn {order, sums}, quarter, row ->
          {order, into} =
            case Map.fetch(sums, quarter) do
              {:ok, into} -> {order, into}
              :error -> {[quarter | order], %{quarter: quarter, visits: 0, visitors: 0, pageviews: 0, bounced: 0}}
            end

          into = %{
            into
            | visits: into.visits + num(row["visits"]),
              visitors: into.visitors + num(row["visitors"]),
              pageviews: into.pageviews + num(row["pageviews"]),
              bounced: into.bounced + num(row["bounced"])
          }

          {order, Map.put(sums, quarter, into)}
        end

        rolled =
          all(
            store,
            "SELECT value, visits, visitors, pageviews, bounced FROM rl_rollups WHERE site = ? AND dim = 'quarter' AND day IN (#{built_days()})",
            [query.site, query.site, query.from, query.to]
          )

        acc = Enum.reduce(rolled, {[], %{}}, fn row, acc -> bump.(acc, JS.number(row["value"]), row) end)
        {w_sql, w_params} = within(plan.rest)

        raw =
          all(
            store,
            """
            SELECT #{Sql.div(dialect, "s.started_at", 900_000)} AS quarter, COUNT(*) AS visits, COUNT(DISTINCT s.visitor) AS visitors,
                       SUM(s.pageviews) AS pageviews, SUM(CASE WHEN #{bounce()} THEN 1 ELSE 0 END) AS bounced
                     FROM rl_sessions s WHERE s.site = ? AND #{w_sql} AND #{visit_sql()} GROUP BY 1\
            """,
            [query.site] ++ w_params
          )

        {order, sums} = Enum.reduce(raw, acc, fn row, acc -> bump.(acc, JS.floor(num(row["quarter"])), row) end)
        order |> Enum.reverse() |> Enum.map(&sums[&1])
    end
  end

  @doc "Who is on the site now, what they read, and the latest activity."
  @spec realtime(t(), String.t(), integer()) :: Object.t()
  def realtime(store, site, now) do
    since = now - 5 * 60_000
    order = text_order(store)

    active =
      first(
        store,
        "SELECT COUNT(DISTINCT visitor) AS n FROM rl_events WHERE site = ? AND ts >= ? AND kind IN ('pageview', 'event', 'engagement')",
        [
          site,
          since
        ]
      )

    pages =
      all(
        store,
        """
        SELECT path AS value, COUNT(DISTINCT visitor) AS visitors FROM rl_events
               WHERE site = ? AND ts >= ? AND kind = 'pageview' GROUP BY path ORDER BY visitors DESC, path#{order} LIMIT 10\
        """,
        [site, since]
      )

    sources =
      all(
        store,
        """
        SELECT s.source AS value, COUNT(DISTINCT e.visitor) AS visitors FROM rl_events e JOIN rl_sessions s ON s.id = e.session
               WHERE e.site = ? AND e.ts >= ? AND e.kind IN ('pageview', 'event') AND s.source <> ''
               GROUP BY s.source ORDER BY visitors DESC, s.source#{order} LIMIT 10\
        """,
        [site, since]
      )

    start = Integer.floor_div(now, 60_000) * 60_000 - 29 * 60_000

    per_minute =
      all(
        store,
        """
        SELECT #{Sql.div(dialect(store), "(ts - ?)", 60_000)} AS m, COUNT(*) AS n FROM rl_events
               WHERE site = ? AND ts >= ? AND kind = 'pageview' GROUP BY 1\
        """,
        [start, site, start]
      )

    minutes =
      Enum.reduce(per_minute, List.duplicate(0, 30), fn row, minutes ->
        index = JS.floor(num(row["m"]))
        if index >= 0 and index < 30, do: List.update_at(minutes, index, &(&1 + num(row["n"]))), else: minutes
      end)

    countries =
      all(
        store,
        """
        SELECT s.country AS value, COUNT(DISTINCT e.visitor) AS visitors FROM rl_events e JOIN rl_sessions s ON s.id = e.session
               WHERE e.site = ? AND e.ts >= ? AND e.kind IN ('pageview', 'event') AND s.country <> ''
               GROUP BY s.country ORDER BY visitors DESC, s.country#{order} LIMIT 10\
        """,
        [site, since]
      )

    recent =
      all(
        store,
        """
        SELECT e.ts, e.kind, e.path, e.name, s.country, s.city, s.source, s.device FROM rl_events e JOIN rl_sessions s ON s.id = e.session
               WHERE e.site = ? AND e.ts >= ? AND e.kind IN ('pageview', 'event') ORDER BY e.ts DESC, e.id DESC LIMIT 20\
        """,
        [site, start]
      )

    pairs = fn rows -> Enum.map(rows, &JS.obj(value: str(&1["value"]), visitors: num(&1["visitors"]))) end

    JS.obj(
      visitors: num(active && active["n"]),
      pages: pairs.(pages),
      sources: pairs.(sources),
      countries: pairs.(countries),
      minutes: minutes,
      recent:
        Enum.map(recent, fn r ->
          JS.obj(
            ts: num(r["ts"]),
            kind: str(r["kind"]),
            path: str(r["path"], ""),
            name: str(r["name"], ""),
            country: str(r["country"], ""),
            city: str(r["city"], ""),
            source: str(r["source"], ""),
            device: str(r["device"], "")
          )
        end)
    )
  end
end
