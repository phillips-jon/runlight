defmodule Runlight.Http.Headers do
  @moduledoc false
  # Internal. Header lists as the Fetch API's Headers reads them: names
  # matched without regard to case, repeated values joined with ", " by get/2,
  # and Set-Cookie kept apart, since its values may hold commas.

  @type t :: [{String.t(), String.t()}]

  @doc "Headers from a keyword list, a map, or pairs, with lowercase names and no line breaks in values."
  @spec new(Enumerable.t()) :: t()
  def new(pairs) do
    Enum.flat_map(pairs, fn
      {_name, nil} -> []
      {_name, :undefined} -> []
      {name, values} when is_list(values) -> Enum.map(values, &{lower(name), clean(&1)})
      {name, value} -> [{lower(name), clean(value)}]
    end)
  end

  defp lower(name), do: name |> to_string() |> String.downcase()

  # A value never carries a line break, so nothing a caller passes can add a header of its own.
  defp clean(value), do: value |> to_string() |> String.replace(["\r", "\n", <<0>>], "") |> String.trim()

  @doc "`headers.get(name)`: every value joined with \", \", or nil."
  @spec get(t(), String.t()) :: String.t() | nil
  def get(headers, name) do
    name = String.downcase(name)

    case for({^name, v} <- headers, do: v) do
      [] -> nil
      values -> Enum.join(values, ", ")
    end
  end

  @doc "Whether the header is there."
  @spec has?(t(), String.t()) :: boolean()
  def has?(headers, name), do: List.keymember?(headers, String.downcase(name), 0)

  @doc "`headers.set(name, value)`."
  @spec set(t(), String.t(), String.t()) :: t()
  def set(headers, name, value) do
    name = String.downcase(name)
    delete(headers, name) ++ [{name, clean(value)}]
  end

  @doc "`headers.append(name, value)`."
  @spec append(t(), String.t(), String.t()) :: t()
  def append(headers, name, value), do: headers ++ [{String.downcase(name), clean(value)}]

  @doc "`headers.delete(name)`."
  @spec delete(t(), String.t()) :: t()
  def delete(headers, name) do
    name = String.downcase(name)
    Enum.reject(headers, fn {k, _} -> k == name end)
  end

  @doc "`headers.getSetCookie()`."
  @spec set_cookies(t()) :: [String.t()]
  def set_cookies(headers), do: for({"set-cookie", v} <- headers, do: v)

  @doc "Every header as a name and its joined value, sorted by name, as iterating Fetch Headers gives them."
  @spec entries(t()) :: [{String.t(), String.t()}]
  def entries(headers) do
    headers
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn
      "set-cookie" -> for {"set-cookie", v} <- headers, do: {"set-cookie", v}
      name -> [{name, get(headers, name)}]
    end)
  end
end

defmodule Runlight.Http.Request do
  @moduledoc """
  A request, shaped like the Fetch API's Request so the routes read as the
  TypeScript SDK's do: an absolute URL, a method, headers, and the body as
  text. `Runlight.Plug` makes one from a `Plug.Conn`; a test or another
  server can make one with `new/2`.

  `remote_address` is the address the connection came from, used for the
  visitor's daily hash and the rate limit when no trusted proxy header names
  the client.
  """

  alias Runlight.Http.Headers

  defstruct url: "", method: "GET", headers: [], body: "", remote_address: "", ref: nil

  @type t :: %__MODULE__{
          url: String.t(),
          method: String.t(),
          headers: Headers.t(),
          body: binary(),
          remote_address: String.t(),
          ref: reference() | nil
        }

  @doc """
  A request for `url` (absolute). Options: `:method` (default "GET"),
  `:headers` (a map or list of pairs), `:body` (text), and
  `:remote_address`.
  """
  @spec new(String.t(), keyword()) :: t()
  def new(url, opts \\ []) do
    %__MODULE__{
      url: url,
      method: opts |> Keyword.get(:method, "GET") |> to_string() |> String.upcase(),
      headers: Headers.new(Keyword.get(opts, :headers, [])),
      body: Keyword.get(opts, :body, "") || "",
      remote_address: Keyword.get(opts, :remote_address, "") || "",
      ref: make_ref()
    }
  end

  @doc "A header's value, every one joined with \", \", or nil."
  @spec header(t(), String.t()) :: String.t() | nil
  def header(%__MODULE__{headers: h}, name), do: Headers.get(h, name)

  @doc "The body as text."
  @spec text(t()) :: String.t()
  def text(%__MODULE__{body: body}), do: Runlight.JS.decode_utf8(body)

  @doc "The body as JSON: `{:ok, value}` or `:error`, as `request.json()` resolves or rejects."
  @spec json(t()) :: {:ok, term()} | :error
  def json(%__MODULE__{} = r) do
    case Runlight.JS.parse(text(r)) do
      {:ok, v} -> {:ok, v}
      {:error, _} -> :error
    end
  end

  @doc "The parsed URL."
  @spec url(t()) :: Runlight.Url.t()
  def url(%__MODULE__{url: url}), do: Runlight.Url.new(url)

  @doc "The same request with other parts, as `new Request(request, init)` makes one."
  @spec with(t(), keyword()) :: t()
  def with(%__MODULE__{} = r, changes) do
    r = struct(r, changes)
    %{r | ref: make_ref()}
  end
end

defmodule Runlight.Http.Response do
  @moduledoc """
  An answer, shaped like the Fetch API's Response: a status, headers (a list
  of lowercase names and values, with one entry per Set-Cookie), and the
  body as a binary.
  """

  alias Runlight.Http.Headers

  defstruct status: 200, headers: [], body: ""

  @type t :: %__MODULE__{status: non_neg_integer(), headers: Headers.t(), body: binary()}

  @doc "An answer of `body` with a status and headers."
  @spec new(binary() | nil, non_neg_integer(), Enumerable.t()) :: t()
  def new(body, status \\ 200, headers \\ []) do
    %__MODULE__{status: status, headers: Headers.new(headers), body: body || ""}
  end

  @doc "A header's value, or nil."
  @spec header(t(), String.t()) :: String.t() | nil
  def header(%__MODULE__{headers: h}, name), do: Headers.get(h, name)

  @doc "Whether the status is 2xx, as `response.ok`."
  @spec ok?(t()) :: boolean()
  def ok?(%__MODULE__{status: s}), do: s >= 200 and s < 300

  @doc "The body as text."
  @spec text(t()) :: String.t()
  def text(%__MODULE__{body: body}), do: Runlight.JS.decode_utf8(IO.iodata_to_binary(body))

  @doc "The body as JSON: `{:ok, value}` or `:error`."
  @spec json(t()) :: {:ok, term()} | :error
  def json(%__MODULE__{} = r) do
    case Runlight.JS.parse(text(r)) do
      {:ok, v} -> {:ok, v}
      {:error, _} -> :error
    end
  end

  @doc "The answer with a header set, replacing any of that name."
  @spec put_header(t(), String.t(), String.t()) :: t()
  def put_header(%__MODULE__{headers: h} = r, name, value), do: %{r | headers: Headers.set(h, name, value)}

  @doc "The Set-Cookie headers."
  @spec set_cookies(t()) :: [String.t()]
  def set_cookies(%__MODULE__{headers: h}), do: Headers.set_cookies(h)
end
