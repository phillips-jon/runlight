defmodule Runlight.ConformanceTest do
  @moduledoc """
  Replays conformance/http.json against the Elixir port on every store, as
  http-conformance.test.ts does against the TypeScript SDK: each step's answer
  must equal the one the file holds.
  """
  use ExUnit.Case, async: false

  alias Runlight.Test.Conformance
  alias Runlight.Test.Stores

  @moduletag timeout: 600_000

  for {kind, _url} <- Stores.kinds(), scenario <- Conformance.scenarios() do
    @kind kind
    @name scenario["name"]
    @tag kind: kind
    test "#{kind}: #{scenario["name"]}" do
      scenario = Enum.find(Conformance.scenarios(), &(&1["name"] == @name))
      {store, cleanup} = Stores.store(@kind, Keyword.get(Stores.kinds(), @kind))
      on_exit(cleanup)
      answers = Conformance.play(scenario, store)
      steps = scenario["steps"]
      assert length(answers) == length(steps)

      differ =
        for {{step, answer}, i} <- Enum.with_index(Enum.zip(steps, answers)),
            Conformance.canonical(step["expect"]) != Conformance.canonical(answer),
            do: i

      if differ != [] do
        i = hd(differ)
        step = Enum.at(steps, i)

        flunk(
          "#{@name} (#{@kind}): step #{i + 1}, #{step["method"]} #{step["path"]} answered differently " <>
            "(#{length(differ)} steps differ: #{Enum.map_join(Enum.take(differ, 12), ", ", &(&1 + 1))})\n" <>
            "expected #{Conformance.canonical(step["expect"])}\n" <>
            "actual   #{Conformance.canonical(Enum.at(answers, i))}"
        )
      end
    end
  end
end
