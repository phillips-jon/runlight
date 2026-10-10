defmodule Runlight.MixProject do
  use Mix.Project

  # The release's version, the one place it lives; the release script bumps it.
  @version "0.0.0"
  @source_url "https://github.com/runlightsh/runlight"

  def project do
    [
      app: :runlight,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      description:
        "Privacy friendly web analytics that lives inside your Elixir app. " <>
          "Mount a Plug, add a script tag, read your stats at /runlight.",
      package: package(),
      source_url: @source_url,
      homepage_url: "https://runlight.sh",
      docs: [
        main: "readme",
        extras: ["README.md"],
        source_ref: "v#{@version}"
      ],
      dialyzer: [
        plt_local_path: "_build/plts",
        plt_core_path: "_build/plts",
        plt_add_apps: [:ex_unit, :mix, :ecto, :ecto_sql, :db_connection, :ssl, :public_key, :inets, :plug]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl, :public_key, :inets]
    ]
  end

  def cli do
    [preferred_envs: [dialyzer: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:tz, "~> 0.28"},
      {:ecto_sql, pinned(:ecto_sql, "~> 3.12"), optional: true},
      {:plug, pinned(:plug, "~> 1.16"), optional: true},
      {:ecto_sqlite3, "~> 0.17", only: :test},
      {:postgrex, "~> 0.19", only: :test},
      {:myxql, "~> 0.7", only: :test},
      {:bandit, "~> 1.5", only: :test},
      {:phoenix, "~> 1.7", only: :test},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false}
    ]
  end

  # An optional dependency at the release RUNLIGHT_PIN_<NAME> names
  # (RUNLIGHT_PIN_PLUG=1.16.0), for the CI entry that tests the oldest release
  # each requirement claims, since Mix has no minimal-versions resolver; the
  # requirement as written otherwise.
  defp pinned(dep, requirement) do
    case System.get_env("RUNLIGHT_PIN_" <> String.upcase(to_string(dep))) do
      version when is_binary(version) and version != "" -> "== " <> version
      _ -> requirement
    end
  end

  # The fixtures are made with TZ=UTC, so the tests always run in UTC
  # (test_helper.exs refuses to start otherwise).
  defp aliases do
    [test: [fn _ -> System.put_env("TZ", "UTC") end, "test"]]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "Website" => "https://runlight.sh",
        "Source" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      files: ~w(lib priv mix.exs .formatter.exs README.md LICENSE)
    ]
  end
end
