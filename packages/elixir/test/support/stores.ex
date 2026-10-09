defmodule Runlight.Test.SqliteRepo do
  @moduledoc false
  use Ecto.Repo, otp_app: :runlight, adapter: Ecto.Adapters.SQLite3
end

defmodule Runlight.Test.PgRepo do
  @moduledoc false
  use Ecto.Repo, otp_app: :runlight, adapter: Ecto.Adapters.Postgres
end

defmodule Runlight.Test.MyRepo do
  @moduledoc false
  use Ecto.Repo, otp_app: :runlight, adapter: Ecto.Adapters.MyXQL
end

defmodule Runlight.Test.Stores do
  @moduledoc false
  # Fresh, empty stores for the tests: SQLite in memory always, a Postgres
  # schema of its own when RUNLIGHT_TEST_PG is set, and an emptied MySQL or
  # MariaDB database when RUNLIGHT_TEST_MYSQL or RUNLIGHT_TEST_MARIADB is set.
  # Each variable holds a connection URL, such as
  # postgres://joncphillips@127.0.0.1:5432/runlight_test_elixir.
  #
  # A MySQL or MariaDB database is used as it is, its rl_ tables dropped before
  # each test, so the tests that use one run one at a time.

  alias Runlight.Test.MyRepo
  alias Runlight.Test.PgRepo
  alias Runlight.Test.SqliteRepo

  @doc "The kinds of store to test on, each with its URL (nil for SQLite)."
  def kinds do
    [{:sqlite, nil}] ++
      for {kind, var} <- [postgres: "RUNLIGHT_TEST_PG", mysql: "RUNLIGHT_TEST_MYSQL", mariadb: "RUNLIGHT_TEST_MARIADB"],
          url = env(var),
          do: {kind, url}
  end

  defp env(name) do
    case System.get_env(name) do
      nil -> nil
      value -> if String.trim(value) == "", do: nil, else: String.trim(value)
    end
  end

  @doc """
  A fresh store of a kind, and a function that drops what it made. The repo
  is started under the calling process.
  """
  def store(kind, url \\ nil)

  def store(:sqlite, _url) do
    {:ok, pid} = SqliteRepo.start_link(name: nil, database: ":memory:", pool_size: 1, log: false)
    Process.unlink(pid)
    store = Runlight.Store.ecto(repo: SqliteRepo, dynamic_repo: pid)
    {store, fn -> stop(pid) end}
  end

  def store(:postgres, url) do
    name = "rl_test_" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)
    config = parse(url)
    {:ok, admin} = Postgrex.start_link(config)
    Process.unlink(admin)
    Postgrex.query!(admin, ~s(CREATE SCHEMA "#{name}"), [])
    {:ok, pid} = PgRepo.start_link([name: nil, pool_size: 2, log: false, parameters: [search_path: name]] ++ config)
    Process.unlink(pid)
    store = Runlight.Store.ecto(repo: PgRepo, dynamic_repo: pid)

    {store,
     fn ->
       stop(pid)
       Postgrex.query!(admin, ~s(DROP SCHEMA IF EXISTS "#{name}" CASCADE), [])
       GenServer.stop(admin)
       :ok
     end}
  end

  def store(kind, url) when kind in [:mysql, :mariadb] do
    config = parse(url)
    {:ok, pid} = MyRepo.start_link([name: nil, pool_size: 2, log: false] ++ config)
    Process.unlink(pid)
    previous = MyRepo.put_dynamic_repo(pid)
    empty_mysql()
    MyRepo.put_dynamic_repo(previous)
    store = Runlight.Store.ecto(repo: MyRepo, dynamic_repo: pid)

    {store,
     fn ->
       previous = MyRepo.put_dynamic_repo(pid)
       empty_mysql()
       MyRepo.put_dynamic_repo(previous)
       stop(pid)
     end}
  end

  defp empty_mysql do
    %{rows: rows} =
      MyRepo.query!(
        "SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name LIKE 'rl\\\\_%'",
        [],
        log: false
      )

    for [table] <- rows, do: MyRepo.query!("DROP TABLE IF EXISTS `#{table}`", [], log: false)
  end

  # Supervisor.stop works from any process; an exit signal from one that is not the repo's parent is ignored.
  defp stop(pid) do
    if Process.alive?(pid), do: Supervisor.stop(pid, :normal, 10_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp parse(url) do
    uri = URI.parse(url)

    {user, pass} =
      case String.split(uri.userinfo || "", ":", parts: 2) do
        [u, p] -> {URI.decode(u), URI.decode(p)}
        [u] -> {URI.decode(u), nil}
      end

    [hostname: uri.host, port: uri.port, username: user, database: String.trim_leading(uri.path || "", "/")] ++
      if(pass, do: [password: pass], else: [])
  end
end
