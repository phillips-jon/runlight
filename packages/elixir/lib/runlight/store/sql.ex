defmodule Runlight.Store.Sql do
  @moduledoc false
  # Internal. The store's SQL helpers (the free functions of the SDK's
  # store.ts): the schema, upserts, the filters as conditions, and how rows
  # are read back as numbers.

  alias Runlight.JS
  alias Runlight.Query
  alias Runlight.Sources

  @schema_version 11
  def schema_version, do: @schema_version

  @doc "MySQL's text collation: UTF-8 compared and sorted by code point, case and trailing spaces included."
  def mysql_collation, do: "utf8mb4_0900_bin"

  @bounce_ms 10_000
  def bounce_ms, do: @bounce_ms

  @doc "A session's bounce: one page, nothing clicked that was tracked, under ten seconds engaged."
  def bounce, do: "(s.pageviews = 1 AND s.events = 0 AND (s.engaged_ms IS NULL OR s.engaged_ms < #{@bounce_ms}))"

  def visit_kinds, do: "e.kind IN ('pageview', 'event')"

  @doc "Pageviews that can report engaged time: the tracker's, which carry a pageview id."
  def live_views, do: "SUM(CASE WHEN e.pageview <> '' THEN 1 ELSE 0 END)"

  @doc "A session that is a visit: a short link click alone opens one that is not."
  def is_visit, do: "(s.pageviews > 0 OR s.events > 0)"

  @doc "Engaged time, or for imported visits with none, first to last request."
  def duration, do: "COALESCE(s.engaged_ms, s.last_at - s.started_at)"

  @doc "The built days inside a range, as a subquery taking (site, from, to)."
  def built_days, do: "SELECT day FROM rl_rollup_days WHERE site = ? AND start_at >= ? AND end_at <= ?"

  @doc "How long after a visit starts its events are looked for: far past any real visit."
  def event_tail_ms, do: 2 * 86_400_000

  @doc "The most visits journeys reads, newest first."
  def journey_visits, do: 20_000

  def buckets_per_query, do: 30
  def values_per_query, do: 50
  def max_params, do: 96
  def piece_ms, do: 86_400_000

  @doc "The schema's statements for a dialect, in order."
  @spec schema(String.t()) :: [String.t()]
  def schema(dialect) do
    my = dialect == "mysql"

    id =
      cond do
        dialect == "postgres" -> "BIGSERIAL PRIMARY KEY"
        my -> "BIGINT AUTO_INCREMENT PRIMARY KEY"
        true -> "INTEGER PRIMARY KEY AUTOINCREMENT"
      end

    # MySQL keys and indexes TEXT only by a prefix, so there a column that is keyed, indexed, grouped, or
    # sorted is VARCHAR, sized past anything Runlight writes to it. Elsewhere text is text.
    str = fn n -> if my, do: "VARCHAR(#{n})", else: "TEXT" end
    text = fn n -> "#{str.(n)} NOT NULL DEFAULT ''" end
    # Free text that is never keyed. MySQL takes a default for it only as an expression.
    long = fn fallback ->
      if my, do: "MEDIUMTEXT NOT NULL DEFAULT ('#{fallback}')", else: "TEXT NOT NULL DEFAULT '#{fallback}'"
    end

    table = if my, do: " DEFAULT CHARSET=utf8mb4 COLLATE=#{mysql_collation()}", else: ""
    site = str.(100)
    key = str.(100)
    path = 1000
    medium = if my, do: "MEDIUMTEXT", else: "TEXT"

    [
      "CREATE TABLE IF NOT EXISTS rl_meta (\"key\" #{str.(100)} PRIMARY KEY, value #{medium} NOT NULL)#{table}",
      """
      CREATE TABLE IF NOT EXISTS rl_sites (
            id #{site} PRIMARY KEY, name #{text.(200)}, hostnames #{long.("[]")},
            timezone #{str.(64)} NOT NULL DEFAULT 'UTC', created_at BIGINT NOT NULL,
            overrides #{long.("{}")})#{table}\
      """,
      "CREATE TABLE IF NOT EXISTS rl_salts (day #{str.(32)} PRIMARY KEY, salt #{str.(255)} NOT NULL)#{table}",
      """
      CREATE TABLE IF NOT EXISTS rl_sessions (
            id #{key} PRIMARY KEY, site #{site} NOT NULL, visitor #{key} NOT NULL,
            started_at BIGINT NOT NULL, last_at BIGINT NOT NULL,
            entry_path #{text.(path)}, exit_path #{text.(path)},
            pageviews INTEGER NOT NULL DEFAULT 0, events INTEGER NOT NULL DEFAULT 0,
            engaged_ms BIGINT, imported INTEGER NOT NULL DEFAULT 0,
            hostname #{text.(255)}, referrer_host #{text.(255)}, referrer_path #{text.(500)},
            source #{text.(200)}, channel #{text.(100)},
            utm_source #{text.(200)}, utm_medium #{text.(200)}, utm_campaign #{text.(200)}, utm_term #{text.(200)}, utm_content #{text.(200)},
            country #{text.(16)}, region #{text.(100)}, city #{text.(100)},
            browser #{text.(100)}, browser_version #{text.(100)}, os #{text.(100)}, os_version #{text.(100)},
            device #{text.(50)}, screen #{text.(50)}, language #{text.(50)})#{table}\
      """,
      "CREATE INDEX IF NOT EXISTS rl_sessions_site_started ON rl_sessions (site, started_at)",
      # MySQL takes an index that leads with the site as a way to read all of a site's rows, so there an index
      # for looking a value up leads with that value.
      "CREATE INDEX IF NOT EXISTS rl_sessions_visitor ON rl_sessions (#{if my, do: "visitor, site", else: "site, visitor"}, last_at)",
      """
      CREATE TABLE IF NOT EXISTS rl_events (
            id #{id}, site #{site} NOT NULL, ts BIGINT NOT NULL, kind #{str.(20)} NOT NULL,
            visitor #{text.(100)}, session #{text.(100)}, pageview #{text.(100)},
            path #{text.(path)}, hostname #{text.(255)}, title #{text.(500)}, name #{text.(255)}, props #{medium},
            engaged_ms BIGINT NOT NULL DEFAULT 0, scroll INTEGER, link #{text.(100)})#{table}\
      """,
      "CREATE INDEX IF NOT EXISTS rl_events_site_ts ON rl_events (site, ts)",
      "CREATE INDEX IF NOT EXISTS rl_events_site_kind_ts ON rl_events (site, kind, ts)",
      "CREATE INDEX IF NOT EXISTS rl_events_pageview ON rl_events (#{if my, do: "pageview, site", else: "site, pageview"})",
      "CREATE INDEX IF NOT EXISTS rl_events_site_path ON rl_events (#{if my, do: "path(255), site", else: "site, path"}, ts)",
      if(my,
        do: "CREATE INDEX IF NOT EXISTS rl_events_site_name ON rl_events (name, site, kind, ts)",
        else: "CREATE INDEX IF NOT EXISTS rl_events_site_name ON rl_events (site, name, ts) WHERE kind = 'event'"
      ),
      """
      CREATE TABLE IF NOT EXISTS rl_links (
            id #{key} PRIMARY KEY, site #{site} NOT NULL, domain #{text.(255)}, slug #{str.(255)} NOT NULL,
            name #{text.(255)}, url #{str.(4000)} NOT NULL, created_at BIGINT NOT NULL, updated_at BIGINT NOT NULL,
            deleted_at BIGINT#{if my, do: ", live_slug VARCHAR(255) AS (CASE WHEN deleted_at IS NULL THEN slug END) VIRTUAL", else: ""})#{table}\
      """,
      if(my,
        do: "CREATE UNIQUE INDEX IF NOT EXISTS rl_links_slug_unique ON rl_links (live_slug)",
        else: "CREATE UNIQUE INDEX IF NOT EXISTS rl_links_slug_unique ON rl_links (slug) WHERE deleted_at IS NULL"
      ),
      "CREATE INDEX IF NOT EXISTS rl_events_link ON rl_events (link, ts)",
      "CREATE TABLE IF NOT EXISTS rl_link_domains (domain #{str.(255)} PRIMARY KEY, site #{site} NOT NULL, created_at BIGINT NOT NULL)#{table}",
      "CREATE TABLE IF NOT EXISTS rl_shares (id #{key} PRIMARY KEY, site #{site} NOT NULL, name #{text.(255)}, created_at BIGINT NOT NULL)#{table}",
      """
      CREATE TABLE IF NOT EXISTS rl_goals (
            id #{key} PRIMARY KEY, site #{site} NOT NULL, name #{str.(255)} NOT NULL, kind #{str.(20)} NOT NULL, "match" #{str.(1000)} NOT NULL,
            click_by #{text.(20)}, value_mode #{str.(20)} NOT NULL DEFAULT 'none', value #{if my, do: "DOUBLE", else: "REAL"} NOT NULL DEFAULT 0,
            value_prop #{text.(255)}, currency #{str.(10)} NOT NULL DEFAULT 'USD', created_at BIGINT NOT NULL)#{table}\
      """,
      "CREATE TABLE IF NOT EXISTS rl_settings (\"key\" #{str.(255)} PRIMARY KEY, value #{medium} NOT NULL)#{table}",
      """
      CREATE TABLE IF NOT EXISTS rl_reports (
            id #{key} PRIMARY KEY, site #{site} NOT NULL, email #{str.(320)} NOT NULL, frequency #{str.(20)} NOT NULL,
            lang #{str.(20)} NOT NULL DEFAULT 'en', token #{str.(128)} NOT NULL, origin #{text.(500)},
            last_period #{text.(40)}, last_sent_at BIGINT, created_at BIGINT NOT NULL)#{table}\
      """,
      "CREATE UNIQUE INDEX IF NOT EXISTS rl_reports_token ON rl_reports (token)",
      """
      CREATE TABLE IF NOT EXISTS rl_tokens (
            id #{key} PRIMARY KEY, name #{str.(255)} NOT NULL, site #{text.(100)}, hash #{str.(128)} NOT NULL, hint #{text.(20)},
            created_at BIGINT NOT NULL, last_used_at BIGINT, scope #{str.(20)} NOT NULL DEFAULT 'read')#{table}\
      """,
      "CREATE UNIQUE INDEX IF NOT EXISTS rl_tokens_hash ON rl_tokens (hash)",
      "CREATE TABLE IF NOT EXISTS rl_funnels (id #{key} PRIMARY KEY, site #{site} NOT NULL, name #{str.(255)} NOT NULL, steps #{medium} NOT NULL, created_at BIGINT NOT NULL)#{table}",
      "CREATE TABLE IF NOT EXISTS rl_rollup_days (site #{site} NOT NULL, day #{str.(32)} NOT NULL, start_at BIGINT NOT NULL, end_at BIGINT NOT NULL, PRIMARY KEY (site, day))#{table}",
      "CREATE INDEX IF NOT EXISTS rl_rollup_days_range ON rl_rollup_days (site, start_at)",
      """
      CREATE TABLE IF NOT EXISTS rl_rollups (
            site #{site} NOT NULL, day #{str.(32)} NOT NULL, dim #{str.(32)} NOT NULL, value #{text.(path)},
            visitors BIGINT NOT NULL DEFAULT 0, visits BIGINT NOT NULL DEFAULT 0, pageviews BIGINT NOT NULL DEFAULT 0,
            bounced BIGINT NOT NULL DEFAULT 0, duration BIGINT NOT NULL DEFAULT 0,
            engaged BIGINT NOT NULL DEFAULT 0, views BIGINT NOT NULL DEFAULT 0, scroll_sum BIGINT NOT NULL DEFAULT 0, scroll_n BIGINT NOT NULL DEFAULT 0,
            events BIGINT NOT NULL DEFAULT 0,
            #{if my, do: "KEY rl_rollups_day (site, dim, day)", else: "PRIMARY KEY (site, dim, day, value)"})#{table}\
      """
    ]
  end

  @doc """
  An INSERT that updates the row already there with the same key, or with
  `update` empty leaves it be. MySQL says it its own way.
  """
  @spec upsert(String.t(), String.t(), [String.t()], [String.t()], [String.t()]) :: String.t()
  def upsert(dialect, table, columns, key, update) do
    insert =
      "INSERT INTO #{table} (#{Enum.join(columns, ", ")}) VALUES (#{Enum.map_join(columns, ", ", fn _ -> "?" end)})"

    if dialect == "mysql" do
      sets =
        if update == [],
          do: "#{hd(key)} = #{hd(key)}",
          else: Enum.map_join(update, ", ", &"#{&1} = VALUES(#{&1})")

      "#{insert} ON DUPLICATE KEY UPDATE #{sets}"
    else
      action =
        if update == [], do: "NOTHING", else: "UPDATE SET " <> Enum.map_join(update, ", ", &"#{&1} = excluded.#{&1}")

      "#{insert} ON CONFLICT (#{Enum.join(key, ", ")}) DO #{action}"
    end
  end

  @doc "Whole-number division, which MySQL's `/` is not."
  def div(dialect, a, b), do: if(dialect == "mysql", do: "(#{a} DIV #{b})", else: "(#{a} / #{b})")

  @doc "A value as text: MySQL casts to CHAR, and has no TEXT type to cast to."
  def as_text(dialect, value), do: "CAST(#{value} AS #{if dialect == "mysql", do: "CHAR", else: "TEXT"})"

  @doc """
  A table of buckets (i, bs, be) for a WITH clause. Postgres is told the
  first row's types; MySQL and MariaDB write a table of values differently
  from each other, so they get a UNION of rows.
  """
  def bucket_table(dialect, buckets) do
    if dialect == "mysql" do
      buckets
      |> Enum.with_index()
      |> Enum.map_join(" UNION ALL ", fn {_, i} ->
        if i == 0, do: "SELECT ? AS i, ? AS bs, ? AS be", else: "SELECT ?, ?, ?"
      end)
    else
      cast = dialect == "postgres"

      "VALUES " <>
        (buckets
         |> Enum.with_index()
         |> Enum.map_join(", ", fn {_, i} ->
           if cast and i == 0, do: "(CAST(? AS INTEGER), CAST(? AS BIGINT), CAST(? AS BIGINT))", else: "(?, ?, ?)"
         end))
    end
  end

  @doc "`Number(value ?? 0)`, with anything not finite as 0."
  @spec num(term()) :: number()
  def num(value) do
    n = JS.number(JS.nullish(value, 0))
    if JS.finite?(n), do: n, else: 0
  end

  @doc "`String(value)`."
  def str(value), do: JS.string(value)

  @doc "`String(value ?? fallback)`."
  def str(value, fallback), do: JS.string(JS.nullish(value, fallback))

  def escape_like(value), do: Regex.replace(~r/[\\%_]/, value, fn c -> "\\" <> c end)

  @doc "A `*` pattern as SQLite GLOB, everything else taken literally ([ and ? are GLOB's own)."
  def glob_pattern(pattern) do
    pattern |> String.split("*") |> Enum.map_join("*", &Regex.replace(~r/[\[?]/, &1, fn c -> "[#{c}]" end))
  end

  @doc "A `*` pattern as SQL LIKE, everything else taken literally."
  def like_pattern(pattern), do: pattern |> String.split("*") |> Enum.map_join("%", &escape_like/1)

  defp column(dimension) do
    if Query.session_dimension?(dimension),
      do: "s." <> Query.session_column(dimension),
      else: "e." <> Query.event_column(dimension)
  end

  @path_dimensions ["page", "entry", "exit"]

  # Text in the form a recorded path holds it, percent-encoded, as part of a path or as a whole one.
  defp as_recorded(value, whole) do
    slash = whole or String.starts_with?(value, "/")

    case Sources.recorded_path(if slash, do: value, else: "/" <> value) do
      nil -> value
      path -> if slash, do: path, else: JS.slice(path, 1)
    end
  end

  # A GLOB pattern for text containing `value` in any mix of upper and lower case, letter by letter.
  defp any_case(value) do
    body =
      value
      |> String.codepoints()
      |> Enum.map_join(fn ch ->
        lower = JS.lower(ch)
        upper = JS.upper(ch)

        cond do
          lower != upper and length(String.to_charlist(lower)) == 1 and length(String.to_charlist(upper)) == 1 ->
            "[#{lower}#{upper}]"

          ch in ["*", "?", "["] ->
            "[#{ch}]"

          true ->
            ch
        end
      end)

    "*#{body}*"
  end

  @doc false
  # One filter as a condition on its own column, with "is not" flipped to "is" when `positive` asks.
  def condition(filter, dialect, positive \\ false) do
    col = column(filter.dimension)
    op = if positive and filter.op == "not", do: "is", else: filter.op
    path = filter.dimension in @path_dimensions

    cond do
      op in ["is", "not"] ->
        {"#{col} #{if op == "is", do: "=", else: "<>"} ?",
         [if(path, do: as_recorded(filter.value, true), else: filter.value)]}

      path ->
        # An encoded letter's case is in its bytes, which no database folds, so a path is also tried in
        # lower, upper, and title case, encoded each way.
        title =
          Regex.replace(~r/(^|[\s\-\/_.])(\p{L})/u, JS.lower(filter.value), fn _, gap, letter ->
            gap <> JS.upper(letter)
          end)

        forms =
          [filter.value, JS.lower(filter.value), JS.upper(filter.value), title]
          |> Enum.map(&as_recorded(&1, false))
          |> Enum.uniq()

        lower = dialect != "sqlite"
        one = if lower, do: "LOWER(#{col}) LIKE ? ESCAPE '\\'", else: "#{col} LIKE ? ESCAPE '\\'"

        {"(" <> Enum.map_join(forms, " OR ", fn _ -> one end) <> ")",
         Enum.map(forms, &"%#{escape_like(if lower, do: JS.lower(&1), else: &1)}%")}

      # Postgres and MySQL lower case any letter, so both sides lowered find any mix.
      dialect != "sqlite" ->
        {"LOWER(#{col}) LIKE ? ESCAPE '\\'", ["%#{escape_like(JS.lower(filter.value))}%"]}

      # SQLite's LIKE and LOWER ignore case for ASCII letters only, so GLOB with both cases of every letter
      # finds any mix, Unicode included.
      true ->
        {"#{col} GLOB ?", [any_case(filter.value)]}
    end
  end

  @doc """
  The visits a query's filters pick, as conditions on `s`. A filter on the
  visit applies to it directly. A filter on a page, hostname, or event picks
  the visits that had a matching row, or for "is not", that never had one.
  """
  def visit_scope(filters, site, from, to, dialect) do
    {parts, params} =
      Enum.reduce(filters, {[], []}, fn filter, {parts, params} ->
        {c_sql, c_params} = condition(filter, dialect, true)

        if Query.session_dimension?(filter.dimension) do
          {own_sql, own_params} = condition(filter, dialect)
          {parts ++ [own_sql], params ++ own_params}
        else
          # An event filter reads events only, which lets it use the index of event names.
          kinds = if filter.dimension == "event", do: "e.kind = 'event'", else: visit_kinds()
          rows = "FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND #{kinds} AND #{c_sql}"

          part =
            if filter.op == "not" and dialect == "postgres",
              do: "NOT EXISTS (SELECT 1 #{rows} AND e.session = s.id)",
              else: "s.id #{if filter.op == "not", do: "NOT IN", else: "IN"} (SELECT e.session #{rows})"

          {parts ++ [part], params ++ [site, from, to + event_tail_ms()] ++ c_params}
        end
      end)

    {Enum.map_join(parts, "", &" AND #{&1}"), params}
  end

  @doc "Conditions on `e` from the filters on the given row dimensions that keep rows (is, contains)."
  def row_scope(filters, dimensions, dialect) do
    Enum.reduce(dimensions, {"", []}, fn dimension, {sql, params} ->
      kept = for f <- filters, f.dimension == dimension and f.op != "not", do: condition(f, dialect)

      if kept == [],
        do: {sql, params},
        else:
          {sql <> " AND (" <> Enum.map_join(kept, " OR ", &elem(&1, 0)) <> ")",
           params ++ Enum.flat_map(kept, &elem(&1, 1))}
    end)
  end

  @doc "Pageviews for each visit a filter picks, as a table to LEFT JOIN on `pv.session = s.id`, or nil."
  def pageviews_of(filters, site, from, to, dialect) do
    {sql, params} = row_scope(filters, ["page", "hostname"], dialect)

    if sql == "" do
      nil
    else
      {"(SELECT e.session AS session, COUNT(*) AS n FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'pageview'#{sql} GROUP BY e.session)",
       [site, from, to + event_tail_ms()] ++ params}
    end
  end

  @doc "The rows of the visits a query picks, as a FROM list and conditions over `e` and `s`."
  def visit_rows(filters, site, from, to, dialect) do
    {scope_sql, scope_params} = visit_scope(filters, site, from, to, dialect)

    {"rl_events e CROSS JOIN rl_sessions s",
     "e.site = ? AND e.ts >= ? AND e.ts < ? AND s.id = e.session AND s.site = ? AND s.started_at >= ? AND s.started_at < ? AND #{is_visit()}#{scope_sql}",
     [site, from, to + event_tail_ms(), site, from, to] ++ scope_params}
  end
end
