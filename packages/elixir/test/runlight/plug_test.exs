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

  test "records a pageview the tracker sends" do
    body = Jason.encode!(%{"k" => "pageview", "u" => "https://example.com/hello", "r" => ""})

    conn =
      conn(:post, "/stats/e", body)
      |> put_req_header("content-type", "text/plain")
      |> put_req_header("user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Firefox/130.0")
      |> call()

    assert conn.status in [200, 202, 204]
  end
end
