defmodule Runlight.Query do
  @moduledoc false
  # Internal. Report queries: which dimensions exist, where each lives, and
  # how filters are read from a URL (the SDK's query.ts). A query is
  # `%{site, from, to, filters}`, with `from` inclusive and `to` exclusive, in
  # epoch milliseconds; a filter is `%{dimension, op, value}`.

  alias Runlight.JS

  @event_dimensions [{"page", "path"}, {"hostname", "hostname"}, {"event", "name"}]

  @session_dimensions [
    {"entry", "entry_path"},
    {"exit", "exit_path"},
    {"referrer", "referrer_host"},
    {"source", "source"},
    {"channel", "channel"},
    {"utm_source", "utm_source"},
    {"utm_medium", "utm_medium"},
    {"utm_campaign", "utm_campaign"},
    {"utm_term", "utm_term"},
    {"utm_content", "utm_content"},
    {"country", "country"},
    {"region", "region"},
    {"city", "city"},
    {"browser", "browser"},
    {"browser_version", "browser_version"},
    {"os", "os"},
    {"os_version", "os_version"},
    {"device", "device"},
    {"screen", "screen"},
    {"language", "language"}
  ]

  @dimensions Enum.map(@event_dimensions, &elem(&1, 0)) ++
                Enum.map(@session_dimensions, &elem(&1, 0)) ++ ["ai_agent", "ai_page"]

  @doc "The most filters a query takes, which keeps every statement within Cloudflare D1's 100 values."
  def max_filters, do: 6

  @doc "Every dimension, in the SDK's order."
  @spec dimensions() :: [String.t()]
  def dimensions, do: @dimensions

  @doc "The dimensions recorded per event, with their columns, in order."
  def event_dimensions, do: @event_dimensions

  @doc "The dimensions recorded once per session, with their columns, in order."
  def session_dimensions, do: @session_dimensions

  @doc "The column of a session dimension."
  def session_column(dimension), do: :proplists.get_value(dimension, @session_dimensions, nil)

  @doc "The column of an event dimension."
  def event_column(dimension), do: :proplists.get_value(dimension, @event_dimensions, nil)

  def dimension?(value), do: value in @dimensions
  def session_dimension?(value), do: List.keymember?(@session_dimensions, value, 0)
  def event_dimension?(value), do: List.keymember?(@event_dimensions, value, 0)

  @doc "`dimension:op:value`, where the value may itself contain colons."
  @spec parse_filter(String.t()) :: map() | nil
  def parse_filter(text) do
    with [dimension, rest] <- :binary.split(text, ":"),
         [op, value] <- :binary.split(rest, ":"),
         true <- session_dimension?(dimension) or event_dimension?(dimension),
         true <- op in ["is", "not", "contains"] do
      %{dimension: dimension, op: op, value: JS.slice(value, 0, 500)}
    else
      _ -> nil
    end
  end
end
