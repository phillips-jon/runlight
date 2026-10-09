defmodule Runlight.State do
  @moduledoc false
  # Internal. What a TypeScript Runlight keeps in its fields (the sites, their
  # dashboard settings, connected installs, caches, counters, and the work
  # queued per key), kept here in one ETS table per instance, so every process
  # serving the instance shares it. The table is public, so any process can
  # read and write it; it belongs to the process that made the instance.

  @doc "A new table."
  @spec new() :: :ets.tid()
  def new, do: :ets.new(:runlight, [:set, :public, read_concurrency: true, write_concurrency: true])

  @doc "The value at `key`, or `default`."
  def get(table, key, default \\ nil) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end

  @doc "Sets `key`."
  def put(table, key, value) do
    :ets.insert(table, {key, value})
    value
  end

  @doc "Removes `key`."
  def delete(table, key) do
    :ets.delete(table, key)
    :ok
  end

  @doc "Adds `by` to the counter at `key`, from 0, and answers the new count."
  def bump(table, key, by \\ 1), do: :ets.update_counter(table, key, by, {key, 0})

  @doc "Every entry whose key is a tuple starting with `tag`."
  def entries(table, tag), do: :ets.match_object(table, {{tag, :_}, :_})

  @doc "Removes every entry whose key is a tuple starting with `tag`."
  def delete_all(table, tag), do: :ets.match_delete(table, {{tag, :_}, :_})

  @doc """
  Runs `fun` after any other process holding `key` has finished, as the
  SDK's oneAtATime does with a promise per key. The same process may take a
  key it already holds.
  """
  def one_at_a_time(table, key, fun) do
    lock = {:lock, key}
    me = self()

    case :ets.lookup(table, lock) do
      [{^lock, ^me}] ->
        fun.()

      _ ->
        acquire(table, lock, me)

        try do
          fun.()
        after
          :ets.delete_object(table, {lock, me})
        end
    end
  end

  defp acquire(table, lock, me) do
    if :ets.insert_new(table, {lock, me}) do
      :ok
    else
      case :ets.lookup(table, lock) do
        # A holder that died without letting go leaves the key to the next.
        [{^lock, holder}] when is_pid(holder) ->
          if Process.alive?(holder), do: Process.sleep(1), else: :ets.delete_object(table, {lock, holder})

        _ ->
          :ok
      end

      acquire(table, lock, me)
    end
  end

  @doc """
  Work started after an answer (deleting visits past a shorter retention),
  run in a task of its own one after another, so `idle/1` can wait for it.
  """
  def later(table, fun) do
    previous = get(table, :later)

    # Not linked to the caller: an answer already sent must not wait for it, nor fail with it.
    {:ok, pid} =
      Task.start(fn ->
        if previous, do: wait(previous)
        fun.()
      end)

    put(table, :later, pid)
    :ok
  end

  @doc "Waits for the work `later/2` started."
  def idle(table) do
    case get(table, :later) do
      nil -> :ok
      pid -> wait(pid)
    end
  end

  defp wait(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    end
  end
end
