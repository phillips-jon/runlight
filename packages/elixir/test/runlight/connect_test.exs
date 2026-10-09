defmodule Runlight.ConnectTest do
  @moduledoc "Connecting an install through its consent page, as hub.test.ts tests it, with the install played by a fake fetcher."
  use ExUnit.Case, async: true

  alias Runlight.Connect
  alias Runlight.ConnectError
  alias Runlight.Http.Response
  alias Runlight.JS
  alias Runlight.SearchParams
  alias Runlight.Store
  alias Runlight.Test.FakeFetcher
  alias Runlight.Test.Stores
  alias Runlight.Url

  @app "http://127.0.0.1:4100/runlight"
  @now 1_791_288_000_000

  defp o(pairs), do: JS.obj(pairs)

  defp answer(body, status \\ 200),
    do: {:ok, Response.new(JS.stringify(body), status, [{"content-type", "application/json"}])}

  # An install that speaks OAuth, as an app's Runlight does.
  defp install(meta \\ nil, registered \\ o(client_id: "c1"), register_status \\ 201) do
    meta =
      meta ||
        o(
          authorization_endpoint: "http://127.0.0.1:4100/runlight/oauth/authorize",
          token_endpoint: "http://127.0.0.1:4100/runlight/oauth/token",
          registration_endpoint: "http://127.0.0.1:4100/runlight/oauth/register",
          scopes_supported: ["read", "manage"]
        )

    FakeFetcher.new(fn url, _ ->
      cond do
        String.ends_with?(url, "/.well-known/oauth-authorization-server") ->
          answer(meta)

        String.ends_with?(url, "/oauth/register") ->
          answer(registered, register_status)

        String.ends_with?(url, "/oauth/token") ->
          answer(o(access_token: "rl_manage", site: "blog"))

        String.ends_with?(url, "/api/sites") ->
          answer(
            o(
              sites: [
                o(id: "shop", name: "Shop", timezone: "UTC", hostnames: ["shop.example.com"]),
                o(id: "blog", name: "Blog", timezone: "Asia/Tokyo", hostnames: ["blog.example.com"])
              ]
            )
          )

        String.ends_with?(url, "/api/token") ->
          answer(o(scope: "manage", site: "blog"))

        true ->
          {:ok, Response.new("{}", 404)}
      end
    end)
  end

  defp hub(fetcher) do
    {store, cleanup} = Stores.store(:sqlite)
    on_exit(cleanup)
    clock = :counters.new(1, [])
    :counters.put(clock, 1, @now)

    rl =
      Runlight.new(
        store: store,
        managed_sites: true,
        secret: String.duplicate("k", 32),
        fetcher: fetcher,
        now: fn -> :counters.get(clock, 1) end
      )

    Runlight.init(rl)
    {rl, clock}
  end

  defp refused(fun, code) do
    error = assert_raise ConnectError, fun
    assert error.code == code
    error
  end

  test "a hub connects an app through its consent page for the one site the owner picked" do
    {fetcher, agent} = install()
    {hub, _} = hub(fetcher)
    back = "http://localhost:4900/runlight/api/sites/connect/done"
    consent = Url.new(Connect.start_connect(hub, @app <> "/", back))
    assert Url.origin(consent) <> consent.pathname == "http://127.0.0.1:4100/runlight/oauth/authorize"
    q = Url.search_params(consent)

    assert Enum.map(~w(response_type client_id redirect_uri code_challenge_method scope), &SearchParams.get(q, &1)) ==
             ["code", "c1", back, "S256", "manage"]

    assert SearchParams.get(q, "state") =~ ~r/\A[a-f0-9]{32}\z/
    assert SearchParams.get(q, "site") == nil
    registration = JS.parse!(Enum.at(FakeFetcher.requests(agent), 1)["body"])
    assert registration == o(client_name: "Runlight at localhost:4900", redirect_uris: [back])

    pending = JS.parse!(Store.setting(hub.store, "connect:" <> SearchParams.get(q, "state")))

    assert SearchParams.get(q, "code_challenge") ==
             Base.url_encode64(:crypto.hash(:sha256, pending["verifier"]), padding: false)

    assert pending["expires"] == @now + 15 * 60_000

    id = Connect.finish_connect(hub, [{"state", SearchParams.get(q, "state")}, {"code", "the-code"}])
    assert id == "blog.example.com"

    assert Runlight.remote(hub, id) ==
             o(url: @app, token: "rl_manage", site: "blog", hostnames: ["blog.example.com"], scope: "manage")

    assert Runlight.site(hub, id) == o(id: "blog.example.com", name: "Blog", hostnames: [], timezone: "Asia/Tokyo")
    exchange = Enum.find(FakeFetcher.requests(agent), &String.ends_with?(&1["url"], "/oauth/token"))
    form = SearchParams.parse(exchange["body"])

    assert Enum.map(~w(grant_type code client_id redirect_uri code_verifier), &SearchParams.get(form, &1)) ==
             ["authorization_code", "the-code", "c1", back, pending["verifier"]]

    # A code works once.
    refused(
      fn -> Connect.finish_connect(hub, [{"state", SearchParams.get(q, "state")}, {"code", "the-code"}]) end,
      "expired"
    )
  end

  test "what went wrong comes back as a code" do
    {fetcher, _} = install()
    {hub, clock} = hub(fetcher)

    start = fn site ->
      hub |> Connect.start_connect(@app, "https://hub.example/done", site) |> Url.new() |> Url.search_params()
    end

    assert SearchParams.get(start.("blog"), "site") == "blog", "which of its sites to offer first"
    denied = start.("")

    refused(
      fn -> Connect.finish_connect(hub, [{"state", SearchParams.get(denied, "state")}, {"error", "access_denied"}]) end,
      "denied"
    )

    other = start.("")

    error =
      refused(
        fn ->
          Connect.finish_connect(hub, [
            {"state", SearchParams.get(other, "state")},
            {"error", "server_error"},
            {"error_description", "Sign in again"}
          ])
        end,
        "refused"
      )

    assert error.message == "Sign in again"
    refused(fn -> Connect.finish_connect(hub, [{"state", "not-a-state"}]) end, "expired")
    # An attempt nobody came back from in time.
    late = start.("")
    :counters.add(clock, 1, 16 * 60_000)
    refused(fn -> Connect.finish_connect(hub, [{"state", SearchParams.get(late, "state")}]) end, "expired")
    # Starting again clears the ones that ran out.
    start.("")
    assert length(Store.settings_starting_with(hub.store, "connect:")) == 1
  end

  test "a hub only follows an install's own endpoints when connecting" do
    {fetcher, agent} =
      install(
        o(
          authorization_endpoint: "http://127.0.0.1:1/authorize",
          token_endpoint: "http://169.254.169.254/token",
          registration_endpoint: "http://169.254.169.254/register",
          scopes_supported: ["read", "manage"]
        )
      )

    {hub, _} = hub(fetcher)

    error =
      refused(fn -> Connect.start_connect(hub, "http://127.0.0.1:4100", "https://hub.example/done") end, "endpoints")

    assert error.message =~ "named endpoints on another address"
    assert length(FakeFetcher.requests(agent)) == 1, "nothing else was asked"
  end

  test "an install that cannot connect says why" do
    {fetcher, _} = install()
    {hub, _} = hub(fetcher)
    refused(fn -> Connect.start_connect(hub, "ftp://x", "https://hub.example/done") end, "url")

    {empty, _} = FakeFetcher.new(fn _, _ -> {:ok, Response.new("{}", 404)} end)
    {hub, _} = hub(empty)
    refused(fn -> Connect.start_connect(hub, @app, "https://hub.example/done") end, "not_runlight")

    for scopes <- [["read"], "manage"] do
      {old, _} =
        install(
          o(
            authorization_endpoint: @app <> "/oauth/authorize",
            token_endpoint: @app <> "/oauth/token",
            registration_endpoint: @app <> "/oauth/register",
            scopes_supported: scopes
          )
        )

      {hub, _} = hub(old)
      refused(fn -> Connect.start_connect(hub, @app, "https://hub.example/done") end, "old")
    end

    {why, _} = install(nil, o(error_description: "redirect_uris must use https"), 400)
    {hub, _} = hub(why)
    error = refused(fn -> Connect.start_connect(hub, @app, "http://hub.example/done") end, "register")
    assert error.params == %{"url" => @app, "reason" => "redirect_uris must use https."}

    {no_why, _} = install(nil, o(nope: true), 400)
    {hub, _} = hub(no_why)
    error = refused(fn -> Connect.start_connect(hub, @app, "http://hub.example/done") end, "register")
    assert error.params["reason"] == "This server's address must use https."

    {down, _} = FakeFetcher.new(fn _, _ -> {:error, :econnrefused} end)
    {hub, _} = hub(down)
    error = refused(fn -> Connect.start_connect(hub, @app, "https://hub.example/done") end, "unreachable")
    assert error.params == %{"host" => "127.0.0.1:4100"}
  end
end
