if Code.ensure_loaded?(Plug.Conn) do
  defmodule Runlight.Plug do
    @moduledoc """
    The dashboard, its API, and the tracker as a Plug: the SDK's
    `rl.routes()`, the same answers byte for byte, so the dashboard, the MCP
    server, and every port's tools work against an Elixir app as they do
    against a Node one.

    In Phoenix, forward to it outside the `:browser` pipeline (the routes have
    their own cross-site checks, and Phoenix's CSRF plug would refuse the
    tracker's posts):

        # lib/my_app_web/router.ex
        scope "/" do
          forward "/runlight", Runlight.Plug
        end

    and in a `Plug.Router` the same way. The base path is where the router
    mounted it. Options are `Runlight.Routes`'s, plus `:instance`, the
    instance's name (default `Runlight`). Phoenix calls `init/1` when the
    router compiles, so nothing is read there: the token and the instance are
    read on the first request.

    A request on a link domain added in Settings, such as go.example.com, is
    answered with its redirect or a 404 before anything else, as every one of
    these Plugs does; on every other host the request carries on.

    The connection's own address is passed on for the visitor's daily hash
    when no trusted proxy header names the client (see the instance's
    `:trust_proxy`).

    A Phoenix endpoint's `Plug.Parsers` reads form and JSON bodies before the
    router forwards here. Those reach the routes as the client sent them, a
    form as a form and JSON as JSON, rebuilt from what the parsers made of
    them. To hand on the exact bytes instead, give the parsers this module's
    reader:

        plug Plug.Parsers,
          parsers: [:urlencoded, :multipart, :json],
          json_decoder: Phoenix.json_library(),
          body_reader: {Runlight.Plug, :body_reader, []}
    """

    @behaviour Plug

    alias Runlight.Http.Request
    alias Runlight.Http.Response
    alias Runlight.State

    # The tracker's posts are under 8 KB; everything else, such as a link import of 5,000 rows, under 10 MB.
    @max_collect 16 * 1024
    @max_body 10 * 1024 * 1024

    @impl Plug
    def init(opts) when is_list(opts), do: opts

    @impl Plug
    def call(%Plug.Conn{} = conn, opts) do
      rl = Runlight.instance(Keyword.get(opts, :instance, Runlight))
      base = Keyword.get(opts, :base_path) || mount(conn)
      routes_opts = opts |> Keyword.delete(:instance) |> Keyword.put(:base_path, base)
      routes = routes(rl, routes_opts)

      case link_domain(conn, rl) do
        {:answered, conn} ->
          conn

        {:pass, conn} ->
          case request(conn, if(String.ends_with?(conn.request_path, "/e"), do: @max_collect, else: @max_body)) do
            {:ok, request, conn} -> answer(conn, Runlight.Routes.handle(routes, request))
            {:too_large, conn} -> too_large(conn)
            {:broken, reason, conn} -> broken(conn, reason)
          end
      end
    end

    @doc false
    # A request on a link domain answered with its redirect or a 404, or the connection untouched for every other
    # host. The body is never read here, so whatever comes next still can.
    def link_domain(conn, rl) do
      {:ok, request, _} = request(%{conn | body_params: %{}, method: "GET"}, 0)

      case Runlight.link_domain_response(rl, %{request | method: conn.method, body: ""}) do
        nil -> {:pass, conn}
        response -> {:answered, answer(conn, response)}
      end
    end

    # The routes are made once per instance and options, so their state (a development secret, caches) holds.
    defp routes(rl, opts) do
      key = {:plug_routes, :erlang.phash2(opts)}

      case State.get(rl.table, key) do
        nil ->
          State.one_at_a_time(rl.table, key, fn ->
            State.get(rl.table, key) || State.put(rl.table, key, Runlight.routes(rl, opts))
          end)

        routes ->
          routes
      end
    end

    defp mount(%Plug.Conn{script_name: []}), do: "/runlight"
    defp mount(%Plug.Conn{script_name: parts}), do: "/" <> Enum.join(parts, "/")

    @doc false
    # The request as the routes read it: the URL as sent, the headers, the body (up to `limit`), and the
    # connection's address.
    def request(conn, limit) do
      headers =
        if List.keymember?(conn.req_headers, "host", 0),
          do: conn.req_headers,
          else: conn.req_headers ++ [{"host", authority(conn)}]

      proto = if conn.scheme == :https, do: "https", else: "http"
      host = Enum.find_value(headers, "localhost", fn {k, v} -> if k == "host", do: v end)
      query = if conn.query_string == "", do: "", else: "?" <> conn.query_string
      url = "#{proto}://#{host}#{conn.request_path}#{query}"

      case read_body(conn, limit) do
        {:ok, body, conn} ->
          address = conn.remote_ip |> :inet.ntoa() |> to_string()

          {:ok,
           %Request{
             url: url,
             method: conn.method,
             headers: headers,
             body: body,
             remote_address: address,
             ref: make_ref()
           }, conn}

        other ->
          other
      end
    end

    defp authority(%{scheme: :http, port: 80} = conn), do: conn.host
    defp authority(%{scheme: :https, port: 443} = conn), do: conn.host
    defp authority(conn), do: "#{conn.host}:#{conn.port}"

    defp read_body(conn, limit) do
      if conn.method in ["GET", "HEAD"] do
        {:ok, "", conn}
      else
        case {conn.private[:runlight_body], conn.body_params} do
          # The bytes body_reader/2 kept while Plug.Parsers read them.
          {chunks, _} when is_list(chunks) ->
            within(IO.iodata_to_binary(Enum.reverse(chunks)), limit, conn)

          # A body a Phoenix endpoint's Plug.Parsers already read, rebuilt as the client sent it.
          {_, %{} = params} when map_size(params) > 0 and not is_struct(params) ->
            within(parsed_body(conn, params), limit, conn)

          _ ->
            read_all(conn, limit, [])
        end
      end
    end

    defp within(body, limit, conn) when byte_size(body) > limit, do: {:too_large, conn}
    defp within(body, _limit, conn), do: {:ok, body, conn}

    # JSON as JSON (a top-level array or scalar under "_json", where Plug.Parsers puts it), and a form, or anything
    # else the parsers read, as a form.
    defp parsed_body(conn, params) do
      type = conn |> Plug.Conn.get_req_header("content-type") |> List.first("") |> String.downcase()

      cond do
        not Regex.match?(~r/^application\/([^;]+\+)?json\s*(;|$)/, type) -> Plug.Conn.Query.encode(params)
        Map.keys(params) == ["_json"] -> Runlight.JS.stringify(params["_json"])
        true -> Runlight.JS.stringify(params)
      end
    end

    defp read_all(conn, limit, acc) do
      case Plug.Conn.read_body(conn, length: limit) do
        {:ok, chunk, conn} -> {:ok, IO.iodata_to_binary(Enum.reverse([chunk | acc])), conn}
        {:more, _chunk, conn} -> {:too_large, conn}
        {:error, reason} -> {:broken, reason, conn}
      end
    end

    @doc """
    A `body_reader` for `Plug.Parsers` that keeps the bytes it reads, so a
    body the parsers have already read reaches the routes byte for byte.
    """
    @spec body_reader(Plug.Conn.t(), keyword()) ::
            {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
    def body_reader(conn, opts) do
      case Plug.Conn.read_body(conn, opts) do
        {status, chunk, conn} when status in [:ok, :more] ->
          {status, chunk, Plug.Conn.put_private(conn, :runlight_body, [chunk | conn.private[:runlight_body] || []])}

        error ->
          error
      end
    end

    # A body that broke off part way is never taken for the whole request: too slow is a 408, anything else a 400.
    defp broken(conn, reason) do
      {status, message} =
        if reason == :timeout,
          do: {408, "That request took too long to arrive"},
          else: {400, "That request was cut off"}

      conn
      |> Plug.Conn.put_resp_header("connection", "close")
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, ~s({"error":"#{message}"}))
      |> Plug.Conn.halt()
    end

    defp too_large(conn) do
      conn
      |> Plug.Conn.put_resp_header("connection", "close")
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(413, ~s({"error":"That request is too large"}))
      |> Plug.Conn.halt()
    end

    @doc false
    def answer(conn, %Response{} = response) do
      # Plug starts every answer with a cache-control of its own; the SDK's is set in its place, or none.
      conn = Plug.Conn.delete_resp_header(conn, "cache-control")

      conn =
        Enum.reduce(response.headers, conn, fn
          {"set-cookie", value}, conn -> %{conn | resp_headers: conn.resp_headers ++ [{"set-cookie", value}]}
          {name, value}, conn -> Plug.Conn.put_resp_header(conn, name, value)
        end)

      conn
      |> Plug.Conn.send_resp(response.status, response.body)
      |> Plug.Conn.halt()
    end
  end

  defmodule Runlight.Plug.Links do
    @moduledoc """
    Short links on the app's own domain: forward the instance's link path
    (default "/go") here, and `/go/{slug}` redirects to the link's
    destination, with the click recorded. A request on a link domain is
    answered as that domain's links first.

        forward "/go", Runlight.Plug.Links
    """
    @behaviour Plug

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, opts) do
      rl = Runlight.instance(Keyword.get(opts, :instance, Runlight))

      case Runlight.Plug.link_domain(conn, rl) do
        {:answered, conn} ->
          conn

        {:pass, conn} ->
          # A short link reads no body, so none is read.
          {:ok, request, _} = Runlight.Plug.request(%{conn | method: "GET"}, 0)
          Runlight.Plug.answer(conn, Runlight.link_handler(rl, %{request | method: conn.method}))
      end
    end
  end

  defmodule Runlight.Plug.LinkDomains do
    @moduledoc """
    For an endpoint (before the router): a request on a link domain added in
    Settings, such as go.example.com, is answered with its redirect or a 404;
    every other request carries on.

        plug Runlight.Plug.LinkDomains
    """
    @behaviour Plug

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, opts) do
      rl = Runlight.instance(Keyword.get(opts, :instance, Runlight))
      conn |> Runlight.Plug.link_domain(rl) |> elem(1)
    end
  end

  defmodule Runlight.Plug.Observer do
    @moduledoc """
    Records page requests from known AI agents, which run no JavaScript, so
    the tracker cannot see them. Put it in a pipeline. It answers a request on
    a link domain with its redirect or a 404 and never stops any other
    request.

        plug Runlight.Plug.Observer
    """
    @behaviour Plug

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, opts) do
      rl = Runlight.instance(Keyword.get(opts, :instance, Runlight))

      case Runlight.Plug.link_domain(conn, rl) do
        {:answered, conn} -> conn
        {:pass, %Plug.Conn{method: "GET"} = conn} -> observe(conn, rl)
        {:pass, conn} -> conn
      end
    end

    defp observe(conn, rl) do
      host = Enum.find_value(conn.req_headers, conn.host, fn {k, v} -> if k == "host", do: v end)
      query = if conn.query_string == "", do: "", else: "?" <> conn.query_string
      url = "#{if conn.scheme == :https, do: "https", else: "http"}://#{host}#{conn.request_path}#{query}"
      Runlight.observe(rl, %Runlight.Http.Request{url: url, method: "GET", headers: conn.req_headers, ref: make_ref()})
      conn
    end
  end
end
