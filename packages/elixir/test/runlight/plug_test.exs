defmodule Runlight.PlugTest do
  # The Plugs in a Plug.Router, against an instance started as an app starts one.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Runlight.Test.Stores

  defmodule Router do
    use Plug.Router

    plug(:match)
    plug(Runlight.Plug.Observer, instance: Runlight.PlugTest.RL)
    plug(:dispatch)

    forward("/stats", to: Runlight.Plug, init_opts: [instance: Runlight.PlugTest.RL, token: "secret"])
    forward("/go", to: Runlight.Plug.Links, init_opts: [instance: Runlight.PlugTest.RL])
    match(_, do: send_resp(conn, 200, "the app"))
  end

  setup do
    {store, cleanup} = Stores.store(:sqlite)
    on_exit(cleanup)

    start_supervised!(
      {Runlight,
       name: Runlight.PlugTest.RL,
       store: store,
       site: [name: "example.com", hostnames: ["example.com"], timezone: "UTC"],
       trust_proxy: false}
    )

    :ok
  end

  defp call(conn), do: Router.call(%{conn | host: "example.com"}, Router.init([]))

  test "serves the tracker under the path it is mounted at" do
    conn = call(conn(:get, "/stats/s.js"))
    assert conn.status == 200
    assert hd(get_resp_header(conn, "content-type")) =~ "javascript"
    assert conn.resp_body =~ "sendBeacon"

    # The dashboard's own links start at the mount point.
    page = conn(:get, "/stats/?token=secret") |> call()
    assert page.status in [200, 302, 303]
    assert Enum.any?([page.resp_body | get_resp_header(page, "location")], &(&1 =~ "/stats"))
  end

  test "keeps the API behind the token" do
    assert call(conn(:get, "/stats/api/sites")).status == 401

    conn = conn(:get, "/stats/api/sites") |> put_req_header("authorization", "Bearer secret") |> call()
    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert [%{"name" => "example.com"}] = Jason.decode!(conn.resp_body)["sites"]
  end

  test "answers an unknown short link with a 404 and leaves other paths to the app" do
    assert call(conn(:get, "/go/nothing")).status == 404
    assert call(conn(:get, "/about")).resp_body == "the app"
  end

  # A short link on the link domain go.example.org, made through the API as the dashboard makes one.
  defp link_domain! do
    api = fn path, body ->
      conn(:post, "/stats/api/" <> path, Jason.encode!(body))
      |> put_req_header("authorization", "Bearer secret")
      |> put_req_header("content-type", "application/json")
      |> call()
    end

    assert api.("link-domains", %{domain: "go.example.org"}).status == 201
    assert api.("links", %{url: "https://example.org/deal", slug: "deal", domain: "go.example.org"}).status == 201
  end

  defp on(conn, host), do: %{conn | host: host}

  defp redirected?(conn),
    do: conn.status in [301, 302, 307, 308] and get_resp_header(conn, "location") == ["https://example.org/deal"]

  test "the observer answers a link domain before the app and leaves the app's own host to it" do
    link_domain!()
    assert redirected?(Router.call(conn(:get, "/deal") |> on("go.example.org"), Router.init([])))
    assert Router.call(conn(:get, "/nothing") |> on("go.example.org"), Router.init([])).status == 404
    assert call(conn(:get, "/deal")).resp_body == "the app"
  end

  defmodule Domains do
    use Plug.Builder
    plug(Runlight.Plug.LinkDomains, instance: Runlight.PlugTest.RL)
    plug(:app)
    def app(conn, _), do: send_resp(conn, 200, "the app")
  end

  test "the link domain Plug answers a link domain and leaves the app's own host to the app" do
    link_domain!()
    assert redirected?(Domains.call(conn(:get, "/deal") |> on("go.example.org"), Domains.init([])))
    assert Domains.call(conn(:get, "/deal") |> on("example.com"), Domains.init([])).resp_body == "the app"
  end

  defmodule Root do
    use Plug.Router
    plug(:match)
    plug(:dispatch)
    forward("/", to: Runlight.Plug, init_opts: [instance: Runlight.PlugTest.RL, base_path: "", token: "secret"])
  end

  test "the dashboard's Plug answers a link domain and serves the app's own host" do
    link_domain!()
    assert redirected?(Root.call(conn(:get, "/deal") |> on("go.example.org"), Root.init([])))
    tracker = Root.call(conn(:get, "/s.js") |> on("example.com"), Root.init([]))
    assert tracker.status == 200
    assert tracker.resp_body =~ "sendBeacon"
  end

  defmodule Links do
    use Plug.Router
    plug(:match)
    plug(:dispatch)
    forward("/", to: Runlight.Plug.Links, init_opts: [instance: Runlight.PlugTest.RL])
  end

  test "the short link Plug answers a link domain and the app's own link path" do
    link_domain!()
    assert redirected?(Links.call(conn(:get, "/deal") |> on("go.example.org"), Links.init([])))
    # On the app's own host only the link path answers, for every link.
    assert Links.call(conn(:get, "/deal") |> on("example.com"), Links.init([])).status == 404
    assert redirected?(Links.call(conn(:get, "/go/deal") |> on("example.com"), Links.init([])))
  end

  test "records a pageview the tracker sends" do
    body = Jason.encode!(%{"k" => "pageview", "u" => "https://example.com/hello", "r" => ""})

    conn =
      conn(:post, "/stats/e", body)
      |> put_req_header("content-type", "text/plain")
      |> put_req_header("user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Firefox/130.0")
      |> call()

    assert conn.status in [200, 202, 204]
  end

  test "an observe report with a key nobody gave is refused before its body is read" do
    conn =
      conn(:post, "/stats/api/observe", "not json")
      |> put_req_header("authorization", "Bearer wrong")
      |> put_req_header("content-type", "application/json")
      |> call()

    assert conn.status == 401
  end
end

defmodule Runlight.PlugParsedTest do
  # The dashboard's Plug behind Plug.Parsers, as a Phoenix endpoint reads bodies before its router forwards.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Runlight.Test.Stores

  @opts [instance: Runlight.PlugParsedTest.RL, token: "secret", accounts: true]

  defmodule Router do
    use Plug.Router

    plug(:match)
    plug(Plug.Parsers, parsers: [:urlencoded, :multipart, :json], json_decoder: Jason)
    plug(:dispatch)

    forward("/stats",
      to: Runlight.Plug,
      init_opts: [instance: Runlight.PlugParsedTest.RL, token: "secret", accounts: true]
    )
  end

  defmodule Kept do
    use Plug.Router

    plug(:match)

    plug(Plug.Parsers,
      parsers: [:urlencoded, :json],
      json_decoder: Jason,
      body_reader: {Runlight.Plug, :body_reader, []}
    )

    plug(:dispatch)

    forward("/stats",
      to: Runlight.Plug,
      init_opts: [instance: Runlight.PlugParsedTest.RL, token: "secret", accounts: true]
    )
  end

  # A connection whose body breaks off part way.
  defmodule Cut do
    def read_req_body(reason, _opts), do: {:error, reason}
    def send_resp(payload, _status, _headers, body), do: {:ok, body, payload}
  end

  setup do
    {store, cleanup} = Stores.store(:sqlite)
    on_exit(cleanup)

    start_supervised!(
      {Runlight,
       name: Runlight.PlugParsedTest.RL,
       store: store,
       secret: String.duplicate("s", 32),
       site: [name: "example.com", hostnames: ["example.com"], timezone: "UTC"],
       trust_proxy: false}
    )

    :ok
  end

  defp setup_form(router) do
    form = "code=secret&email=me%40example.com&password=a+long+passphrase+1&again=a+long+passphrase+1"

    conn(:post, "/stats/setup", form)
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> put_req_header("origin", "http://example.com")
    |> Map.put(:host, "example.com")
    |> router.call(router.init([]))
  end

  test "a form the parsers already read is read as the form it was" do
    conn = setup_form(Router)
    assert conn.status in [302, 303], conn.resp_body
    assert get_resp_header(conn, "set-cookie") != []
  end

  test "the parsers' reader hands on the body as it was sent" do
    conn = setup_form(Kept)
    assert conn.status in [302, 303], conn.resp_body
  end

  test "JSON the parsers already read is read as JSON" do
    conn =
      conn(:post, "/stats/api/link-domains", Jason.encode!(%{domain: "go.example.org"}))
      |> put_req_header("authorization", "Bearer secret")
      |> put_req_header("content-type", "application/json")
      |> Map.put(:host, "example.com")
      |> Router.call(Router.init([]))

    assert conn.status == 201, conn.resp_body
  end

  test "a body that breaks off is refused, not taken for the whole request" do
    for {reason, status} <- [timeout: 408, closed: 400] do
      conn =
        conn(:post, "/stats/api/link-domains")
        |> put_req_header("authorization", "Bearer secret")
        |> put_req_header("content-type", "application/json")
        |> Map.merge(%{host: "example.com", adapter: {Cut, reason}})
        |> Runlight.Plug.call(@opts)

      assert conn.status == status
    end
  end
end
