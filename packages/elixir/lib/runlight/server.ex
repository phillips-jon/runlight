defmodule Runlight.Server do
  @moduledoc false
  # Internal. The process an instance started under a supervision tree lives
  # in: it owns the instance's state table, makes the tables in the database
  # on start (so a bad store fails the app's boot rather than its first
  # request), and keeps the instance where Runlight.instance/1 finds it.
  # With `check_every:` (milliseconds) it also runs the scheduled check on an
  # interval, as a platform's cron would call POST /api/check.

  use GenServer

  require Logger

  def start_link(opts) do
    name = Keyword.get(opts, :name, Runlight)
    GenServer.start_link(__MODULE__, opts, name: server_name(name))
  end

  defp server_name(name), do: Module.concat(name, Server)

  @impl true
  def init(opts) do
    rl = Runlight.new(opts)
    :persistent_term.put({Runlight, rl.name}, rl)
    Runlight.init(rl)
    every = Keyword.get(opts, :check_every)
    if every, do: schedule(every)
    {:ok, %{rl: rl, every: every}}
  end

  @impl true
  def handle_info(:check, state) do
    try do
      Runlight.check(state.rl)
    rescue
      error -> Logger.error("Runlight: the scheduled check failed: #{Exception.message(error)}")
    end

    schedule(state.every)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :persistent_term.erase({Runlight, state.rl.name})
    :ok
  end

  defp schedule(every), do: Process.send_after(self(), :check, every)
end
