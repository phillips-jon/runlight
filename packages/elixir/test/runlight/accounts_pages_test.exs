defmodule Runlight.AccountsPagesTest do
  @moduledoc "The account pages against packages/php/tests/fixtures/pages.json, the TypeScript's HTML for the same inputs."
  use ExUnit.Case, async: true

  alias Runlight.Accounts.Pages
  alias Runlight.JS.Object
  alias Runlight.Test.Fixtures

  @keys %{
    "error" => :error,
    "email" => :email,
    "next" => :next,
    "forgot" => :forgot,
    "pending" => :pending,
    "code" => :code,
    "role" => :role,
    "host" => :host,
    "askCode" => :ask_code
  }

  test "styles, script, pages, and roles match" do
    f = Fixtures.php("pages.json")
    assert Pages.auth_css() == f["css"]
    assert Pages.auth_js() == f["js"]

    for c <- f["pages"] do
      fun = c["fn"] |> Macro.underscore() |> String.to_atom()

      html =
        case c["opts"] do
          nil ->
            apply(Pages, fun, [c["base"]])

          opts ->
            apply(Pages, fun, [c["base"], Map.new(Object.to_list(opts), fn {k, v} -> {Map.fetch!(@keys, k), v} end)])
        end

      assert html == c["html"], "#{c["fn"]} at #{inspect(c["base"])}"
    end

    for c <- f["roles"], do: assert(Pages.role_text(c["role"]) == c["text"])
  end
end
