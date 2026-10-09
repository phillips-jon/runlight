defmodule Runlight.StoreCrossTest do
  @moduledoc """
  One database, every implementation. packages/php/tests/fixtures/store.db was
  built by the TypeScript SDK, and store.json holds what its SqlStore reads
  answered (scripts/php-fixtures-store.mts). The Elixir store must answer the
  same over a copy of that file, and over the same rows copied into Postgres
  and MySQL or MariaDB.
  """
  use ExUnit.Case, async: false

  alias Runlight.JS
  alias Runlight.JS.Object
  alias Runlight.Store
  alias Runlight.Test.Fixtures
  alias Runlight.Test.SqliteRepo
  alias Runlight.Test.Stores

  @moduletag timeout: 300_000

  @tables ~w(rl_meta rl_sites rl_salts rl_sessions rl_events rl_links rl_link_domains rl_shares rl_goals rl_settings rl_reports rl_tokens rl_funnels rl_rollup_days rl_rollups)

  defp tables, do: @tables

  setup_all do
    {:ok, fixture: Fixtures.php("store.json")}
  end

  defp copy_db do
    dir = System.tmp_dir!()
    file = Path.join(dir, "rl-store-#{System.unique_integer([:positive])}.db")
    File.cp!(Path.join([Fixtures.root(), "packages", "php", "tests", "fixtures", "store.db"]), file)
    on_exit(fn -> for f <- [file, file <> "-wal", file <> "-shm"], do: File.rm(f) end)
    file
  end

  defp query(%Object{} = q) do
    %{
      site: q["site"],
      from: q["from"],
      to: q["to"],
      filters: Enum.map(q["filters"] || [], &%{dimension: &1["dimension"], op: &1["op"], value: &1["value"]})
    }
  end

  defp buckets(list), do: Enum.map(list, &%{start: &1["start"], end: &1["end"]})

  defp answer(store, %Object{} = call) do
    args = call["args"]

    case {call["method"], args} do
      {"sites", []} ->
        Store.sites(store)

      {"siteOverrides", []} ->
        store |> Store.site_overrides() |> Enum.sort() |> Object.new()

      {"lastSeen", [s]} ->
        Store.last_seen(store, s)

      {"firstSeen", [s]} ->
        Store.first_seen(store, s)

      {"firstOwnVisit", [s]} ->
        Store.first_own_visit(store, s)

      {"rollupDays", [s]} ->
        store |> Store.rollup_days(s) |> Enum.sort()

      {"stats", [q]} ->
        Store.stats(store, query(q))

      {"visitors", [q]} ->
        Store.visitors(store, query(q))

      {"hourly", [q]} ->
        store
        |> Store.hourly(query(q))
        |> Enum.map(
          &JS.obj(
            quarter: &1.quarter,
            visits: &1.visits,
            visitors: &1.visitors,
            pageviews: &1.pageviews,
            bounced: &1.bounced
          )
        )

      {"breakdown", [q, d, l, o]} ->
        Store.breakdown(store, query(q), d, l, o)

      {"goalTotalsAll", [q, goals]} ->
        store |> Store.goal_totals_all(query(q), goals) |> Enum.sort() |> Object.new()

      {"funnelCounts", [q, f]} ->
        Store.funnel_counts(store, query(q), f)

      {"journeyPages", [q, n]} ->
        journey(Store.journey_pages(store, query(q), n))

      {"eventPropKeys", [q, e]} ->
        Store.event_prop_keys(store, query(q), e)

      {"eventPropValues", [q, e, k, l]} ->
        Store.event_prop_values(store, query(q), e, k, l)

      {"goalTotals", [q, g]} ->
        Store.goal_totals(store, query(q), g)

      {"goalBreakdown", [q, g, by, l]} ->
        Store.goal_breakdown(store, query(q), g, by, l)

      {"links", [s, f, t]} ->
        Store.links(store, s, f, t)

      {"linkBreakdown", [s, l, f, t, d, n]} ->
        Store.link_breakdown(store, s, l, f, t, d, n)

      {"series", [q, b]} ->
        Store.series(store, query(Object.merge(q, JS.obj(from: 0, to: 0))), buckets(b))

      {"goalSeries", [q, g, b]} ->
        Store.goal_series(store, query(Object.merge(q, JS.obj(from: 0, to: 0))), g, buckets(b))

      {"linkSeries", [s, l, b]} ->
        Store.link_series(store, s, l, buckets(b))

      {"realtime", [s, now]} ->
        Store.realtime(store, s, now)

      {"goals", [s]} ->
        Store.goals(store, s)

      {"goals", []} ->
        Store.goals(store)

      {"goalById", [id]} ->
        Store.goal_by_id(store, id)

      {"funnels", [s]} ->
        Store.funnels(store, s)

      {"linkBySlug", [s]} ->
        Store.link_by_slug(store, s)

      {"linkById", [id]} ->
        Store.link_by_id(store, id)

      {"linkDomains", []} ->
        Store.link_domains(store)

      {"shares", [s]} ->
        Store.shares(store, s)

      {"shareById", [id]} ->
        Store.share_by_id(store, id)

      {"tokens", []} ->
        Store.tokens(store)

      {"tokenByHash", [h]} ->
        Store.token_by_hash(store, h)

      {"reports", []} ->
        Store.reports(store)

      {"reports", [s]} ->
        Store.reports(store, s)

      {"reportBy", [field, v]} ->
        Store.report_by(store, String.to_atom(field), v)

      {"setting", [k]} ->
        Store.setting(store, k)

      {"settingsStartingWith", [p]} ->
        store |> Store.settings_starting_with(p) |> Enum.map(&JS.obj(key: &1.key, value: &1.value))

      {"pageview", [s, p]} ->
        pageview(Store.pageview(store, s, p))

      {"openSession", [s, v, since]} ->
        open_session(Store.open_session(store, s, v, since))

      {"saltIfExists", [d]} ->
        Store.salt_if_exists(store, d)
    end
  end

  defp journey(%{rows: rows, sampled: sampled}),
    do: JS.obj(rows: Enum.map(rows, &JS.obj(session: &1.session, path: &1.path)), sampled: sampled)

  defp pageview(nil), do: nil

  defp pageview(p),
    do:
      JS.obj(
        session: p.session,
        visitor: p.visitor,
        path: p.path,
        hostname: p.hostname,
        ts: p.ts,
        startedAt: p.started_at,
        lastAt: p.last_at
      )

  defp open_session(nil), do: nil
  defp open_session(s), do: JS.obj(id: s.id, visitor: s.visitor)

  defp sorted(%Object{} = o),
    do: o |> Object.to_list() |> Enum.sort() |> Enum.map(fn {k, v} -> {k, sorted(v)} end) |> Object.new()

  defp sorted(l) when is_list(l), do: Enum.map(l, &sorted/1)
  defp sorted(v), do: v

  defp assert_answers(store, fixture, label) do
    failures =
      fixture["calls"]
      |> Enum.with_index()
      |> Enum.flat_map(fn {call, i} ->
        canon = call["method"] in ["siteOverrides", "goalTotalsAll"]
        expected = if canon, do: JS.stringify(sorted(call["result"])), else: JS.stringify(call["result"])

        actual =
          try do
            a = answer(store, call)
            if canon, do: JS.stringify(sorted(a)), else: JS.stringify(a)
          rescue
            e -> "#{inspect(e.__struct__)}: #{Exception.message(e)}"
          end

        if actual == expected,
          do: [],
          else: [
            "##{i} #{call["method"]}(#{String.slice(JS.stringify(call["args"]), 0, 300)})\n  expected #{expected}\n  actual   #{actual}"
          ]
      end)

    if failures != [],
      do:
        flunk(
          "#{label}: #{length(failures)} of #{length(fixture["calls"])} reads differ\n" <>
            Enum.join(Enum.take(failures, 10), "\n")
        )
  end

  test "Elixir reads a database the TypeScript SDK wrote and answers the same", %{fixture: fixture} do
    file = copy_db()
    {:ok, pid} = SqliteRepo.start_link(name: nil, database: file, pool_size: 1, log: false)
    store = Store.ecto(repo: SqliteRepo, dynamic_repo: pid)
    Store.migrate(store)
    assert_answers(store, fixture, "sqlite")
    rows = Runlight.Db.all(store.db, ~s(SELECT value FROM rl_meta WHERE "key" = 'schema'), [])
    assert Enum.map(rows, & &1["value"]) == ["11"]
    GenServer.stop(pid)
  end

  for {kind, _} <- Stores.kinds(), kind != :sqlite do
    @kind kind
    test "the same rows in #{kind} answer the same", %{fixture: fixture} do
      kind = @kind
      url = Stores.kinds() |> Keyword.fetch!(kind)
      file = copy_db()
      {:ok, pid} = SqliteRepo.start_link(name: nil, database: file, pool_size: 1, log: false)
      source = Store.ecto(repo: SqliteRepo, dynamic_repo: pid)
      {target, cleanup} = Stores.store(kind, url)
      on_exit(cleanup)
      Store.migrate(target)

      Store.transaction(target, fn into ->
        for table <- tables() do
          Runlight.Db.run(into.db, "DELETE FROM #{table}", [])

          for row <- Runlight.Db.all(source.db, "SELECT * FROM #{table}", []) do
            pairs = Object.to_list(row)
            columns = Enum.map_join(pairs, ", ", fn {c, _} -> ~s("#{c}") end)
            marks = Enum.map_join(pairs, ", ", fn _ -> "?" end)

            Runlight.Db.run(
              into.db,
              "INSERT INTO #{table} (#{columns}) VALUES (#{marks})",
              Enum.map(pairs, &elem(&1, 1))
            )
          end
        end
      end)

      assert_answers(target, fixture, Atom.to_string(kind))
      GenServer.stop(pid)
    end
  end
end
