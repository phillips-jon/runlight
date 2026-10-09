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

    The connection's own address is passed on for the visitor's daily hash
    when no trusted proxy header names the client (see the instance's
    `:trust_proxy`).
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

      case request(conn, if(String.ends_with?(conn.request_path, "/e"), do: @max_collect, else: @max_body)) do
        {:ok, request, conn} -> answer(conn, Runlight.Routes.handle(routes, request))
        {:too_large, conn} -> too_large(conn)
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

        {:too_large, conn} ->
          {:too_large, conn}
      end
    end

    defp authority(%{scheme: :http, port: 80} = conn), do: conn.host
    defp authority(%{scheme: :https, port: 443} = conn), do: conn.host
    defp authority(conn), do: "#{conn.host}:#{conn.port}"

    defp read_body(conn, limit) do
      if conn.method in ["GET", "HEAD"] do
        {:ok, "", conn}
      else
        case conn.body_params do
          # A body a Phoenix endpoint's Plug.Parsers already read comes back as JSON.
          %{} = params when map_size(params) > 0 and not is_struct(params) ->
            {:ok, Runlight.JS.stringify(params), conn}

          _ ->
            read_all(conn, limit, [])
        end
      end
    end

    defp read_all(conn, limit, acc) do
      case Plug.Conn.read_body(conn, length: limit) do
        {:ok, chunk, conn} -> {:ok, IO.iodata_to_binary(Enum.reverse([chunk | acc])), conn}
        {:more, _chunk, conn} -> {:too_large, conn}
        {:error, _} -> {:ok, IO.iodata_to_binary(Enum.reverse(acc)), conn}
      end
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
    destination, with the click recorded.

        forward "/go", Runlight.Plug.Links
    """
    @behaviour Plug

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, opts) do
      rl = Runlight.instance(Keyword.get(opts, :instance, Runlight))
      {:ok, request, conn} = Runlight.Plug.request(conn, 0)
      Runlight.Plug.answer(conn, Runlight.link_handler(rl, request))
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
      {:ok, request, conn} = Runlight.Plug.request(%{conn | body_params: %{}}, 0)

      case Runlight.link_domain_response(rl, %{request | body: ""}) do
        nil -> conn
        response -> Runlight.Plug.answer(conn, response)
      end
    end
  end

  defmodule Runlight.Plug.Observer do
    @moduledoc """
    Records page requests from known AI agents, which run no JavaScript, so
    the tracker cannot see them. Put it in a pipeline; it never stops a
    request.

        plug Runlight.Plug.Observer
    """
    @behaviour Plug

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(%Plug.Conn{method: "GET"} = conn, opts) do
      rl = Runlight.instance(Keyword.get(opts, :instance, Runlight))
      host = Enum.find_value(conn.req_headers, conn.host, fn {k, v} -> if k == "host", do: v end)
      query = if conn.query_string == "", do: "", else: "?" <> conn.query_string
      url = "#{if conn.scheme == :https, do: "https", else: "http"}://#{host}#{conn.request_path}#{query}"
      Runlight.observe(rl, %Runlight.Http.Request{url: url, method: "GET", headers: conn.req_headers, ref: make_ref()})
      conn
    end

    def call(conn, _opts), do: conn
  end
end
