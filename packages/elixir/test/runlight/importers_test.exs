defmodule Runlight.ImportersTest do
  @moduledoc """
  Replays the importer scenarios in packages/php/tests/fixtures/outbound.json
  (the cases of importers.test.ts and more): each importer, run step by step
  against the same answers, must send the TypeScript SDK's exact requests,
  wait as long between retries, ask about the same known links, and hand back
  the same steps, cursors included.
  """
  use ExUnit.Case, async: true

  alias Runlight.Http.Headers
  alias Runlight.Http.Response
  alias Runlight.ImportError
  alias Runlight.Importers
  alias Runlight.Importers.Http
  alias Runlight.JS
  alias Runlight.JS.Object
  alias Runlight.Test.Fixtures

  setup_all do
    {:ok, fixture: Fixtures.php("outbound.json")}
  end

  defp run(fixture, scenario) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{left: Enum.map(scenario["routes"], &JS.nullish(&1["times"], :infinity)), sent: [], waits: [], known: []}
      end)

    fetch = fn url, opts ->
      headers = opts |> Keyword.get(:headers, []) |> Headers.new() |> Headers.entries() |> Object.new()

      request =
        JS.obj(
          method: Keyword.get(opts, :method, "GET"),
          url: url,
          headers: headers,
          body: Keyword.get(opts, :body) || ""
        )

      Agent.get_and_update(agent, fn state ->
        state = %{state | sent: state.sent ++ [request]}

        index =
          scenario["routes"]
          |> Enum.with_index()
          |> Enum.find_value(fn {route, i} ->
            left = Enum.at(state.left, i)
            if left != 0 and Regex.match?(Regex.compile!(route["pattern"]), url), do: i
          end)

        case index do
          nil ->
            {{:ok, Response.new("{}", 404)}, state}

          i ->
            route = Enum.at(scenario["routes"], i)
            left = Enum.at(state.left, i)
            state = %{state | left: List.replace_at(state.left, i, if(left == :infinity, do: left, else: left - 1))}

            if route["unreachable"] do
              {{:error, :econnrefused}, state}
            else
              extra = if route["headers"], do: Object.to_list(route["headers"]), else: []

              answer =
                Response.new(JS.stringify(route["body"]), JS.nullish(route["status"], 200), [
                  {"content-type", "application/json"} | extra
                ])

              {{:ok, answer}, state}
            end
        end
      end)
    end

    http = %Http{fetch: fetch, pause: fn ms -> Agent.update(agent, &%{&1 | waits: &1.waits ++ [ms]}) end}

    known = fn id, slug, url ->
      Agent.update(agent, &%{&1 | known: &1.known ++ [[id, slug, url]]})
      known = scenario["known"]
      id in known or "#{slug} #{url}" in known
    end

    credentials = Map.new(Object.to_list(scenario["credentials"]))
    steps = scenario["steps"]

    _ =
      Enum.reduce(Enum.with_index(steps), List.first(steps)["cursor"], fn {want, i}, cursor ->
        assert want["cursor"] == cursor, "#{scenario["name"]}: step #{i} starts from the same cursor"

        try do
          result = Importers.step(http, scenario["source"], credentials, cursor, known, fixture["now"])
          refute want["error"], "#{scenario["name"]}: step #{i} should fail"
          assert {scenario["name"], i, JS.stringify(result)} == {scenario["name"], i, JS.stringify(want["result"])}
          result["cursor"]
        rescue
          error in ImportError ->
            assert want["error"], "#{scenario["name"]}: step #{i} should not fail: #{error.message}"

            got =
              JS.obj(
                message: error.message,
                code: error.code,
                params: JS.obj(error.params),
                status: if(Http.http_error?(error), do: error.status, else: :undefined),
                name: if(Http.http_error?(error), do: "HttpError", else: "ImportError")
              )

            assert JS.stringify(got) == JS.stringify(want["error"]), scenario["name"]
            cursor
        end
      end)

    state = Agent.get(agent, & &1)
    Agent.stop(agent)

    {sent, requests} =
      if scenario["ordered"],
        do: {state.sent, scenario["requests"]},
        else:
          {Enum.sort(Enum.map(state.sent, &JS.stringify/1)), Enum.sort(Enum.map(scenario["requests"], &JS.stringify/1))}

    assert {scenario["name"], JS.stringify(sent)} == {scenario["name"], JS.stringify(requests)}
    assert state.waits == scenario["waits"], "#{scenario["name"]}: waits"
    assert JS.stringify(state.known) == JS.stringify(scenario["knownCalls"]), "#{scenario["name"]}: known"
  end

  test "every importer scenario matches TypeScript", %{fixture: fixture} do
    for scenario <- fixture["importers"], do: run(fixture, scenario)
  end
end
