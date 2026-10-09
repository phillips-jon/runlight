defmodule Runlight.RateLimit do
  @moduledoc false
  # Internal. Counts requests per address in fixed one-minute windows, in
  # memory (the SDK's limit.ts). Addresses are hashed with a key made when the
  # limit is, so the table never holds an IP, and a window's counts are
  # dropped when the next window begins. A limit lives in an instance's state
  # table under a name of its own.

  alias Runlight.State

  defstruct [:table, :name, :per_minute, :key]

  @type t :: %__MODULE__{}

  @doc "A limit of `per_minute` in `table`, under `name`."
  @spec new(:ets.tid(), term(), pos_integer()) :: t()
  def new(table, name, per_minute) do
    key =
      case State.get(table, {:rate_key, name}) do
        nil -> State.put(table, {:rate_key, name}, :crypto.strong_rand_bytes(16))
        key -> key
      end

    %__MODULE__{table: table, name: name, per_minute: per_minute, key: key}
  end

  @doc "True while this address is under its limit for the current minute."
  @spec allow?(t(), String.t(), integer()) :: boolean()
  # No address (a bare adapter with no context) cannot be told apart, so it is not limited.
  def allow?(_limit, "", _now), do: true

  def allow?(%__MODULE__{table: table, name: name} = limit, ip, now) do
    window = Integer.floor_div(now, 60_000)

    if State.get(table, {:rate_window, name}) != window do
      State.put(table, {:rate_window, name}, window)
      :ets.match_delete(table, {{:rate_count, name, :_}, :_})
    end

    <<id::binary-size(8), _::binary>> = :crypto.hash(:sha256, [limit.key, ip])
    State.bump(table, {:rate_count, name, id}) <= limit.per_minute
  end
end
