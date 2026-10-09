defmodule Runlight.Test.FakeFetcher do
  @moduledoc false
  # A fetcher that records every request and answers from a function, so a
  # test can require the exact method, URL, headers, and body a service is
  # sent. Headers are recorded as the TS fixtures record them: lowercase names
  # in order, as iterating Fetch Headers gives them.

  alias Runlight.Http.Headers
  alias Runlight.JS

  @doc "A fetcher answering with `answer.(url, opts)`, and the agent that holds what it was sent."
  def new(answer) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    fetcher = fn url, opts ->
      headers = opts |> Keyword.get(:headers, []) |> Headers.new() |> Headers.entries() |> JS.obj()

      request =
        JS.obj(
          method: Keyword.get(opts, :method, "GET"),
          url: url,
          headers: headers,
          body: Keyword.get(opts, :body) || ""
        )

      Agent.update(agent, &(&1 ++ [{request, opts}]))
      answer.(url, opts)
    end

    {fetcher, agent}
  end

  @doc "The requests sent, in order, each as `{method, url, headers, body}`."
  def requests(agent), do: agent |> Agent.get(& &1) |> Enum.map(&elem(&1, 0))

  @doc "The options each request came with."
  def inits(agent), do: agent |> Agent.get(& &1) |> Enum.map(&elem(&1, 1))
end
