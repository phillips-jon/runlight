defmodule Runlight.Db do
  @moduledoc """
  The little the store needs from a database: its dialect, and statements
  with `?` placeholders that answer rows. `Runlight.Db.Ecto` runs them through
  an app's own Ecto repo; anything else that implements the callbacks below
  can stand in.

  SQL is written with `?` placeholders and "double quotes" around a name that
  is a keyword somewhere. Each implementation turns that into what its
  database reads, as the SDK's drivers do: Postgres gets the values written
  into the statement as text, as node-postgres sends them, and MySQL gets them
  escaped in place with backticks for quoted names, as mysql2 does.
  """

  @enforce_keys [:module, :dialect, :state]
  defstruct [:module, :dialect, :state, metered: false]

  @type dialect :: :sqlite | :postgres | :mysql
  @type t :: %__MODULE__{module: module(), dialect: dialect(), state: term(), metered: boolean()}

  @doc "Rows as JavaScript objects, their keys in column order."
  @callback all(t(), String.t(), [term()]) :: [Runlight.JS.Object.t()]
  @callback run(t(), String.t(), [term()]) :: :ok
  @doc "How many rows an UPDATE or DELETE matched."
  @callback affected(t(), String.t(), [term()]) :: non_neg_integer()
  @doc "Runs `fun` in one transaction on one connection, committing what it did, or rolling back when it raises."
  @callback transaction(t(), (t() -> term())) :: term()
  @doc "Runs `fun` while holding a database-wide lock, so two processes starting at once do not race to create tables."
  @callback exclusive(t(), (t() -> term())) :: term()

  @doc "The dialect's name, as the SDK writes it."
  @spec dialect(t()) :: String.t()
  def dialect(%__MODULE__{dialect: d}), do: Atom.to_string(d)

  @spec all(t(), String.t(), [term()]) :: [Runlight.JS.Object.t()]
  def all(%__MODULE__{module: m} = db, sql, params \\ []), do: m.all(db, sql, params)

  @spec run(t(), String.t(), [term()]) :: :ok
  def run(%__MODULE__{module: m} = db, sql, params \\ []), do: m.run(db, sql, params)

  @spec affected(t(), String.t(), [term()]) :: non_neg_integer()
  def affected(%__MODULE__{module: m} = db, sql, params \\ []), do: m.affected(db, sql, params)

  @spec transaction(t(), (t() -> term())) :: term()
  def transaction(%__MODULE__{module: m} = db, fun), do: m.transaction(db, fun)

  @spec exclusive(t(), (t() -> term())) :: term()
  def exclusive(%__MODULE__{module: m} = db, fun), do: m.exclusive(db, fun)

  @doc "`?` placeholders to `$1, $2, ...`, leaving quoted text alone (the Postgres driver's numberPlaceholders)."
  @spec number_placeholders(String.t()) :: String.t()
  def number_placeholders(sql) do
    {out, _, _} =
      for <<ch::utf8 <- sql>>, reduce: {[], 0, nil} do
        {out, n, quote} ->
          cond do
            quote != nil -> {[<<ch::utf8>> | out], n, if(ch == quote, do: nil, else: quote)}
            ch in [?', ?"] -> {[<<ch::utf8>> | out], n, ch}
            ch == ?? -> {["$#{n + 1}" | out], n + 1, nil}
            true -> {[<<ch::utf8>> | out], n, nil}
          end
      end

    out |> Enum.reverse() |> IO.iodata_to_binary()
  end

  @doc """
  The statement with each `?` replaced by its value written as Postgres text:
  a quoted literal of unknown type, as node-postgres sends every value, so the
  database reads it in the type the statement needs.
  """
  @spec postgres_text(String.t(), [term()]) :: String.t()
  def postgres_text(sql, params) do
    fill(sql, params, &postgres_value/1, false)
  end

  defp postgres_value(nil), do: "NULL"
  defp postgres_value(v), do: "E'" <> escape_e(Runlight.JS.string(v)) <> "'"

  defp escape_e(text) do
    if String.contains?(text, <<0>>), do: raise(ArgumentError, "Runlight: Postgres text cannot hold a zero byte")
    text |> String.replace("\\", "\\\\") |> String.replace("'", "''")
  end

  @doc """
  SQL written for SQLite and Postgres, as MySQL and MariaDB read it (the SDK's
  mysqlText): `?` becomes the value, escaped; a "quoted" identifier is quoted
  with backticks; and a backslash inside 'text' is doubled, since MySQL reads
  it as an escape where standard SQL takes it literally.
  """
  @spec mysql_text(String.t(), [term()]) :: String.t()
  def mysql_text(sql, params), do: fill(sql, params, &mysql_value/1, true)

  defp mysql_value(nil), do: "NULL"
  defp mysql_value(true), do: "true"
  defp mysql_value(false), do: "false"
  defp mysql_value(n) when is_integer(n) or is_float(n), do: Runlight.JS.format_number(n)

  defp mysql_value(s) when is_binary(s) do
    escaped =
      for <<c <- s>>, into: "" do
        case c do
          0 -> "\\0"
          8 -> "\\b"
          9 -> "\\t"
          10 -> "\\n"
          13 -> "\\r"
          26 -> "\\Z"
          ?" -> "\\\""
          ?' -> "\\'"
          ?\\ -> "\\\\"
          c -> <<c>>
        end
      end

    "'" <> escaped <> "'"
  end

  defp mysql_value(other), do: mysql_value(Runlight.JS.string(other))

  defp fill(sql, params, value, mysql) do
    {out, rest, _quote} =
      for <<ch::utf8 <- sql>>, reduce: {[], params, nil} do
        {out, rest, quote} ->
          cond do
            quote != nil ->
              cond do
                ch == quote -> {[if(mysql and ch == ?", do: "`", else: <<ch::utf8>>) | out], rest, nil}
                mysql and quote == ?' and ch == ?\\ -> {["\\\\" | out], rest, quote}
                mysql and quote == ?" and ch == ?` -> {["``" | out], rest, quote}
                true -> {[<<ch::utf8>> | out], rest, quote}
              end

            ch in [?', ?"] or (mysql and ch == ?`) ->
              {[if(mysql and ch == ?", do: "`", else: <<ch::utf8>>) | out], rest, ch}

            ch == ?? ->
              case rest do
                [v | more] -> {[value.(v) | out], more, nil}
                [] -> raise ArgumentError, "Runlight: a statement has more placeholders than values"
              end

            true ->
              {[<<ch::utf8>> | out], rest, nil}
          end
      end

    if rest != [], do: raise(ArgumentError, "Runlight: a statement has more values than placeholders")
    out |> Enum.reverse() |> IO.iodata_to_binary()
  end
end
