# Credo's settings for the Elixir port, run as `mix credo --strict`.
#
# Much of the package is a line-for-line port of the TypeScript SDK (the
# store's SQL, the routes, the accounts), kept close to the TypeScript so a
# change there can be followed here. Credo's complexity and nesting limits
# would push those functions apart from their originals, so those checks are
# off, as are the style checks that would reshape the ported control flow
# (single-clause `with`, `cond` with one test, negated `if` with an `else`,
# nested module names, and strings of JSON that read best as strings).
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
          {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, []},
          {Credo.Check.Readability.WithSingleClause, []},
          {Credo.Check.Refactor.CondStatements, []},
          {Credo.Check.Refactor.NegatedConditionsWithElse, []},
          {Credo.Check.Design.AliasUsage, []},
          {Credo.Check.Readability.StringSigils, []}
        ]
      }
    }
  ]
}
