defmodule Runlight.Assets do
  @moduledoc false
  # Internal. The dashboard bundle, its CSS, the world map, the locales, the
  # tracker, and the picker: the TypeScript SDK's generated files, copied into
  # priv/assets by scripts/elixir-assets.mts (never edited by hand), read into
  # the compiled module so a release needs no priv lookup.

  @dir Path.expand("../../priv/assets", __DIR__)

  for name <- ~w(dashboard.js dashboard.css world.json tracker.js picker.js locales.json build.json) do
    @external_resource Path.join(@dir, name)
  end

  @dashboard_js File.read!(Path.join(@dir, "dashboard.js"))
  @dashboard_css File.read!(Path.join(@dir, "dashboard.css"))
  @world_json File.read!(Path.join(@dir, "world.json"))
  @tracker File.read!(Path.join(@dir, "tracker.js"))
  @picker File.read!(Path.join(@dir, "picker.js"))
  @locales_text File.read!(Path.join(@dir, "locales.json"))
  @build_text File.read!(Path.join(@dir, "build.json"))

  @build Runlight.JS.parse!(@build_text)
  @locales (for {code, text} <- Runlight.JS.Object.to_list(Runlight.JS.parse!(@locales_text)), into: %{} do
              {code, text}
            end)
  @locale_codes for {code, _} <- Runlight.JS.Object.to_list(Runlight.JS.parse!(@locales_text)), code != "en", do: code

  def dashboard_js, do: @dashboard_js
  def dashboard_css, do: @dashboard_css
  def world_json, do: @world_json
  def tracker, do: @tracker
  def picker, do: @picker

  @doc "Each language's messages as JSON text, English included, by code."
  def locales, do: @locales

  @doc "The languages other than English, in the dashboard's order."
  def locale_codes, do: @locale_codes

  def version, do: @build["version"]
  def api_version, do: @build["apiVersion"]
  def dashboard_hash, do: @build["dashboardHash"]
  def world_hash, do: @build["worldHash"]
  def locales_hash, do: @build["localesHash"]
  def tracker_hash, do: @build["trackerHash"]

  @doc "The Runlight mark for the dashboard's tab: an R in a rounded lamp housing, one corner lit."
  def icon, do: @build["icon"]
end
