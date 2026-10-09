# Credo's settings for the Elixir port, run as `mix credo --strict`.
#
# Much of the package is a line-for-line port of the TypeScript SDK (the
# store's SQL, the routes, the accounts), kept close to the TypeScript so a
# change there can be followed here. Credo's complexity and nesting limits
# would push those functions apart from their originals, so those checks are
# off.
%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/", "mix.exs"], excluded: [~r"/_build/", ~r"/deps/"]},
      strict: true,
      checks: %{
        disabled: [
          {Credo.Check.Refactor.CyclomaticComplexity, []},
          {Credo.Check.Refactor.Nesting, []},
          {Credo.Check.Refactor.FunctionArity, []},
          {Credo.Check.Refactor.ABCSize, []},
          {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, []}
        ]
      }
    }
  ]
}
