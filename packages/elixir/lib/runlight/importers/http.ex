defmodule Runlight.Importers.Http do
  @moduledoc false
  # Internal. JSON over HTTPS with a timeout and a few retries on rate limits
  # and server errors (the SDK's importers/http.ts), plus the few pieces of
  # JavaScript the importers lean on. An importer takes one, so tests can pass
  # a fake fetcher and a pause that does not wait.

  alias Runlight.Http.Response
  alias Runlight.ImportError
  alias Runlight.JS
  alias Runlight.JS.Object
  alias Runlight.Url

  defstruct [:fetch, :pause]

  @type t :: %__MODULE__{
          fetch: (String.t(), keyword() -> {:ok, Response.t()} | {:error, term()}),
          pause: (number() -> any())
        }

  # The most one answer may weigh; a page of a thousand events is well under a megabyte.
  @max_bytes 32 * 1024 * 1024

  @doc """
  The instance's fetcher, and a pause that waits: `Process.sleep`, or the
  function under `:runlight_pause` in the process dictionary, which tests set
  so nothing waits. The address can come from whoever runs an import (a
  self-hosted Umami), so only public https addresses are asked
  (`Runlight.Safefetch`), with no redirect followed, which would carry the
  key somewhere else.
  """
  @spec new(Runlight.t()) :: t()
  def new(rl) do
    %__MODULE__{
      fetch: fn url, opts -> Runlight.Safefetch.public_fetch(rl, url, opts) end,
      pause: Process.get(:runlight_pause) || (&sleep/1)
    }
  end

  defp sleep(ms) when ms > 0, do: Process.sleep(trunc(ms))
  defp sleep(_), do: :ok

  @doc "Waits this many milliseconds."
  def pause(%__MODULE__{pause: pause}, ms), do: pause.(ms)

  @doc """
  The JSON answer of a request, after up to two retries when the server
  cannot be reached and three on 429 or a 5xx. Raises ImportError, with the
  status for an answer that refused (the SDK's HttpError).
  """
  @spec get_json(t(), String.t(), keyword()) :: term()
  def get_json(http, url, init \\ []), do: attempt(http, url, init, 1)

  defp attempt(http, url, init, attempt) do
    opts =
      [headers: [{"accept", "application/json"} | Keyword.get(init, :headers, [])], timeout: 20_000] ++
        Keyword.take(init, [:method, :body]) ++ [max_bytes: @max_bytes]

    case http.fetch.(url, opts) do
      {:error, reason} ->
        # An address off the public internet, or an answer past the cap, is the same on every try.
        if attempt < 3 and reason not in [:private, :too_long] do
          attempt(http, url, init, attempt + 1)
        else
          host = Url.host(Url.new(url))
          raise ImportError, message: "Could not reach #{host}", code: "unreachable", params: %{"host" => host}
        end

      {:ok, response} ->
        cond do
          Response.ok?(response) ->
            case JS.parse(Response.text(response)) do
              {:ok, value} -> value
              {:error, message} -> raise ArgumentError, message
            end

          response.status == 401 ->
            raise ImportError, message: "The key or sign-in was refused", code: "import_refused", status: 401

          (response.status == 429 or response.status >= 500) and attempt < 4 ->
            wait =
              case JS.number(Response.header(response, "retry-after")) do
                # Retry-After in seconds; none, zero, negative, or not a number waits the default backoff.
                n when is_number(n) and n > 0 -> n * 1000
                _ -> 800 * attempt
              end

            pause(http, JS.normalize(min(wait, 10_000)))
            attempt(http, url, init, attempt + 1)

          true ->
            host = Url.host(Url.new(url))

            raise ImportError,
              message: "#{host} answered #{response.status}",
              code: "import_status",
              params: %{"host" => host, "status" => Integer.to_string(response.status)},
              status: response.status
        end
    end
  end

  @doc "Whether an error is the SDK's HttpError: a server's answer that refused."
  def http_error?(%ImportError{status: status}) when is_integer(status), do: true
  def http_error?(_), do: false

  @doc "`value?.key`: a property of an object, or undefined for anything else."
  def get(%Object{} = o, key), do: JS.prop(o, key)
  def get(list, key) when is_list(list), do: JS.prop(list, key)
  def get(_, _), do: :undefined

  @doc "`value?.a?.b`."
  def dig(value, keys), do: Enum.reduce(keys, value, &get(&2, &1))

  @doc "`Date.parse(value)`, NaN for anything not a date."
  def parse_date(value) when is_binary(value), do: JS.date_parse(value)
  def parse_date(_), do: :nan

  @doc "`Date.parse(value) || fallback`."
  def date_or(value, fallback) do
    case parse_date(value) do
      n when is_number(n) and n != 0 -> n
      _ -> fallback
    end
  end

  @doc "An object without its undefined keys left in, as JSON writes it."
  def obj(pairs), do: JS.obj(pairs)
end
