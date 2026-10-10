defmodule Runlight.EmbedTest do
  @moduledoc "The SDK's routes.test.ts on the dashboard inside a CMS: embed tokens, tickets, framing, and sessions."
  use ExUnit.Case, async: false

  alias Runlight.Http.Request
  alias Runlight.Http.Response
  alias Runlight.Store
  alias Runlight.Test.Stores

  defp rl(opts) do
    {store, cleanup} = Stores.store(:sqlite)
    on_exit(cleanup)
    rl = Runlight.new([store: store] ++ opts)
    Runlight.init(rl)
    rl
  end

  defp req(path, method \\ "GET", headers \\ [], body \\ ""),
    do: Request.new("https://example.com#{path}", method: method, headers: headers, body: body)

  defp owner(path, method, body, bearer \\ "secret"),
    do:
      req(
        path,
        method,
        [{"authorization", "Bearer #{bearer}"}, {"content-type", "application/json"}],
        if(body, do: Jason.encode!(body), else: "")
      )

  defp body(%Response{body: body}), do: Jason.decode!(body)

  test "a ticket opens one framed page once, whose session reads one site" do
    rl =
      rl(
        sites: [
          [id: "a", name: "Site A", hostnames: ["a.com"], timezone: "UTC"],
          [id: "b", name: "Site B", hostnames: ["b.com"], timezone: "UTC"]
        ]
      )

    routes = Runlight.routes(rl, token: "secret")
    handle = &Runlight.Routes.handle(routes, &1)

    made = body(handle.(owner("/runlight/api/tokens", "POST", %{name: "CMS", site: "a", scope: "embed"})))
    assert made["token"]["scope"] == "embed"
    mint = fn origin -> handle.(owner("/runlight/api/embed", "POST", %{origin: origin}, made["secret"])) end

    assert mint.("https://b.com").status == 400, "only an origin on the site's own domains"
    minted = mint.("https://www.a.com")
    assert minted.status == 201
    %{"ticket" => ticket, "path" => path, "site" => site} = body(minted)
    assert site == "a"
    assert path == "/runlight/embed?ticket=#{ticket}"
    refute ticket =~ made["token"]["id"], "a ticket never names its token"

    # Three loads at once: the ticket opens a session for one of them only.
    pages = 1..3 |> Enum.map(fn _ -> Task.async(fn -> handle.(req(path)) end) end) |> Enum.map(&Task.await/1)
    assert pages |> Enum.map(& &1.status) |> Enum.sort() == [200, 410, 410]
    page = Enum.find(pages, &(&1.status == 200))
    assert Response.header(page, "content-security-policy") =~ ~r/frame-ancestors https:\/\/www\.a\.com\z/
    assert Response.header(page, "x-frame-options") == nil
    assert Response.header(page, "referrer-policy") == "no-referrer"
    [_, session] = Regex.run(~r/data-embed="([^"]+)"/, page.body)
    assert session =~ ~r/\A\d+\.[a-f0-9]{24}\.[a-f0-9]{64}\z/
    used = Enum.find(pages, &(&1.status == 410))

    assert String.ends_with?(Response.header(used, "content-security-policy"), "frame-ancestors https://www.a.com"),
           "a used ticket still says so inside its frame"

    as = [{"x-runlight-embed", session}]
    assert body(handle.(req("/runlight/api/stats?site=b", "GET", as)))["site"] == "a", "pinned to its token's site"

    assert handle.(req("/runlight/api/links?site=a", "GET", as ++ [{"authorization", "Bearer secret"}])).status == 403,
           "nothing a share cannot read, even beside the owner's token"

    assert Response.header(handle.(req("/runlight/")), "x-frame-options") == "DENY", "every other page refuses frames"

    assert handle.(owner("/runlight/api/tokens/#{made["token"]["id"]}", "DELETE", nil)).status == 200
    assert handle.(req("/runlight/api/stats", "GET", as)).status == 401, "deleting the token ends its sessions at once"
  end

  test "a ticket that is not signed, or a session that ran out, opens nothing" do
    now = Agent.start_link(fn -> 1_791_288_000_000 end) |> elem(1)
    rl = rl(site: [hostnames: ["a.com"]], now: fn -> Agent.get(now, & &1) end)
    routes = Runlight.routes(rl, token: "secret")
    handle = &Runlight.Routes.handle(routes, &1)

    made = body(handle.(owner("/runlight/api/tokens", "POST", %{name: "CMS", site: "default", scope: "embed"})))

    %{"ticket" => ticket} =
      body(handle.(owner("/runlight/api/embed", "POST", %{origin: "https://a.com"}, made["secret"])))

    forged = String.replace(ticket, ~r/[a-f0-9]\z/, fn c -> if c == "0", do: "1", else: "0" end)
    gone = handle.(req("/runlight/embed?ticket=#{forged}"))
    assert gone.status == 404
    assert Response.header(gone, "content-security-policy") =~ "frame-ancestors 'none'"

    page = handle.(req("/runlight/embed?ticket=#{ticket}"))
    [_, session] = Regex.run(~r/data-embed="([^"]+)"/, page.body)
    as = [{"x-runlight-embed", session}]
    assert handle.(req("/runlight/api/stats", "GET", as)).status == 200
    Agent.update(now, &(&1 + 60 * 60_000 + 1))
    expired = handle.(req("/runlight/api/stats", "GET", as))
    assert expired.status == 401
    assert body(expired)["code"] == "embed_expired"
  end

  for {kind, url} <- Stores.kinds() do
    @tag kind: kind
    test "a setting can be taken once on #{kind}" do
      {store, cleanup} = Stores.store(unquote(kind), unquote(url))
      on_exit(cleanup)
      rl = Runlight.new(store: store, site: [hostnames: ["a.com"]])
      Runlight.init(rl)
      Store.set_setting(rl.store, "x", "1")

      taken =
        1..2 |> Enum.map(fn _ -> Task.async(fn -> Store.take_setting(rl.store, "x") end) end) |> Enum.map(&Task.await/1)

      assert Enum.sort(taken, :desc) == ["1", nil]
      assert Store.take_setting(rl.store, "x") == nil
      assert Store.setting(rl.store, "x") == nil
    end
  end
end
