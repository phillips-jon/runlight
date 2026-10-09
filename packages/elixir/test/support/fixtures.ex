defmodule Runlight.Test.Fixtures do
  @moduledoc false
  # The language-neutral fixtures every port reads: conformance/ at the
  # repository's root, and the JSON the PHP port's tests read, made from the
  # TypeScript SDK by the scripts/php-fixtures-*.mts scripts. Read in place,
  # never copied.

  alias Runlight.JS

  @root Path.expand("../../../..", __DIR__)

  @doc "The repository's root."
  def root, do: @root

  @doc "A file under conformance/, parsed."
  def conformance(name), do: read(Path.join([@root, "conformance", name]))

  @doc "One of the PHP port's JSON fixtures, parsed."
  def php(name), do: read(Path.join([@root, "packages", "php", "tests", "fixtures", name]))

  defp read(path), do: path |> File.read!() |> JS.parse!()
end
