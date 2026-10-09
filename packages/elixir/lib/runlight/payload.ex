defmodule Runlight.Payload do
  @moduledoc false
  # Internal. What the tracker sends, after validation (the SDK's payload.ts).
  # Anything malformed is dropped.

  alias Runlight.JS
  alias Runlight.JS.Object
  alias Runlight.Url

  @max_body 8 * 1024
  # One engagement ping covers at most the 30 minutes a session can idle.
  @max_engaged_ms 30 * 60 * 1000
  @max_props 30

  @doc "The longest body a tracker hit can be."
  def max_body, do: @max_body

  defp str(value, max) when is_binary(value), do: JS.slice(value, 0, max)
  defp str(_value, _max), do: ""

  defp int(value, min, max) when is_integer(value) or is_float(value), do: value |> JS.round() |> max(min) |> min(max)
  defp int(_value, _min, _max), do: nil

  defp props(%Object{} = value) do
    {out, count} =
      Enum.reduce_while(Object.to_list(value), {Object.new(), 0}, fn {key, raw}, {out, count} ->
        if count >= @max_props do
          {:halt, {out, count}}
        else
          k = key |> JS.trim() |> JS.slice(0, 60)

          # Assigning out["__proto__"] in JavaScript sets the prototype, which a string cannot be, so
          # the key is counted and never kept.
          put = fn v -> if k == "__proto__", do: out, else: Object.put(out, k, v) end

          cond do
            k == "" -> {:cont, {out, count}}
            is_binary(raw) -> {:cont, {put.(JS.slice(raw, 0, 500)), count + 1}}
            is_integer(raw) or is_float(raw) -> {:cont, {put.(JS.string(raw)), count + 1}}
            is_boolean(raw) -> {:cont, {put.(JS.string(raw)), count + 1}}
            true -> {:cont, {out, count}}
          end
        end
      end)

    if count > 0, do: out
  end

  defp props(_), do: nil

  @doc "The tracker's hit, or nil when it is not one."
  @spec parse(String.t()) :: map() | nil
  def parse(text) do
    with true <- JS.len16(text) <= @max_body,
         {:ok, %Object{} = body} <- JS.parse(text),
         kind when kind in ["pageview", "event", "engagement"] <- body["k"],
         %Url{} = url <- Url.parse(str(body["u"], 2048)),
         true <- url.protocol in ["http:", "https:"],
         name = body["n"] |> str(120) |> JS.trim(),
         false <- kind == "event" and name == "",
         pageview_id = str(body["i"], 32),
         true <- pageview_id == "" or Regex.match?(~r/\A[a-z0-9]+\z/i, pageview_id),
         false <- kind == "engagement" and pageview_id == "" do
      %{
        kind: kind,
        site: str(body["s"], 64),
        url: url,
        referrer: str(body["r"], 2048),
        title: str(body["t"], 500),
        screen_width: int(body["w"], 0, 20_000),
        screen_height: int(body["h"], 0, 20_000),
        language: str(body["l"], 35),
        name: name,
        props: if(kind == "event", do: props(body["p"])),
        pageview_id: pageview_id,
        engaged_ms: if(kind == "engagement", do: int(body["e"], 0, @max_engaged_ms) || 0, else: 0),
        scroll: int(body["d"], 0, 100)
      }
    else
      _ -> nil
    end
  end
end
