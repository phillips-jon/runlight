# frozen_string_literal: true

require "test_helper"
require_relative "make"

# mcp.test.ts, ported: API tokens and the MCP server through the routes, on every store.
class RoutesMcpTest < RoutesTestCase
  Json = Runlight::Json
  Request = Runlight::Http::Request
  CHROME_MAC = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36"
  SITES = [
    { "id" => "a", "name" => "Site A", "hostnames" => ["a.com"], "timezone" => "UTC" },
    { "id" => "b", "name" => "Site B", "hostnames" => ["b.com"], "timezone" => "UTC" },
  ].freeze

  def setup
    super
    @now = RoutesMake.utc(2026, 10, 6, 12)
  end

  # A Runlight on a fresh store of this kind, its routes with the token "secret", and a way to send tracker hits.
  def make(kind)
    rl = RoutesMake.runlight({ "store" => Databases.fresh(kind), "sites" => SITES, "now" => -> { @now } })
    routes = rl.routes({ "token" => "secret" })
    send = lambda do |body, ip = "203.0.113.1"|
      answer = routes.handle(Request.new("https://example.com/runlight/e", method: "POST",
                                                                           headers: { "user-agent" => CHROME_MAC, "x-forwarded-for" => ip, "content-type" => "text/plain;charset=UTF-8" },
                                                                           body: Json.encode(body)))
      raise "collect answered #{answer.status}" if answer.status != 202
    end
    [rl, routes, send]
  end

  on_every_database("api tokens read cannot write can be limited to a site and stop at revocation") do |kind|
    _, routes, send = make(kind)
    make_token = lambda do |body|
      answer = routes.handle(RoutesMake.owner("/runlight/api/tokens", "POST", body))
      { "status" => answer.status, "body" => RoutesMake.body(answer) }
    end
    assert_equal 400, make_token.call({ "name" => "" })["status"]
    assert_equal 404, make_token.call({ "name" => "X", "site" => "nope" })["status"]
    all = make_token.call({ "name" => "Claude" })
    assert_equal 201, all["status"]
    assert_match(/\Arl_[a-f0-9]{40}\z/, all["body"]["secret"])
    assert_equal all["body"]["secret"][-4..], all["body"]["token"]["hint"]
    one = make_token.call({ "name" => "Client B", "site" => "b" })["body"]

    listed_answer = routes.handle(RoutesMake.owner("/runlight/api/tokens"))
    listed = RoutesMake.body(listed_answer)
    assert_equal ["Claude", "Client B"], listed["tokens"].map { |t| t["name"] }.sort
    refute_includes listed_answer.text, all["body"]["secret"], "a token is shown once, never listed"
    refute listed["tokens"][0].key?("hash"), "nor its hash"

    send.call({ "k" => "pageview", "u" => "https://a.com/", "i" => "p1" })
    send.call({ "k" => "pageview", "u" => "https://b.com/", "i" => "p2" }, "203.0.113.2")

    as = ->(path, secret, method = "GET", body = nil) { routes.handle(RoutesMake.owner("/runlight#{path}", method, body, secret)) }
    stats = as.call("/api/stats?site=a&period=today", all["body"]["secret"])
    assert_equal 200, stats.status
    assert_equal 1, RoutesMake.body(stats)["stats"]["visitors"]
    assert_equal 200, as.call("/api/links?site=a", all["body"]["secret"]).status, "links can be read"

    # Nothing that writes, and nothing that manages access.
    assert_equal 403, as.call("/api/goals?site=a", all["body"]["secret"], "POST", { "name" => "G", "kind" => "page", "match" => "/" }).status
    assert_equal 403, as.call("/api/links?site=a", all["body"]["secret"], "POST", { "url" => "https://x.com" }).status
    assert_equal 401, as.call("/api/tokens", all["body"]["secret"]).status, "a token cannot list tokens"
    assert_equal 401, as.call("/api/shares?site=a", all["body"]["secret"]).status
    assert_equal 401, as.call("/api/mail", all["body"]["secret"]).status

    # A site's token sees only that site.
    assert_equal ["b"], RoutesMake.body(as.call("/api/sites", one["secret"]))["sites"].map { |s| s["id"] }
    assert_equal "b", RoutesMake.body(as.call("/api/stats?period=today", one["secret"]))["site"], "and defaults to it"
    assert_equal 404, as.call("/api/stats?site=a", one["secret"]).status
    assert_equal 404, as.call("/api/links?site=a", one["secret"]).status

    used = RoutesMake.body(routes.handle(RoutesMake.owner("/runlight/api/tokens")))
    used["tokens"].each do |token|
      assert_equal @now, token["lastUsedAt"] if token["name"] == "Claude"
    end

    id = all["body"]["token"]["id"]
    assert_equal 403, as.call("/api/tokens/#{id}", all["body"]["secret"], "DELETE").status, "a token cannot revoke"
    assert_equal 200, routes.handle(RoutesMake.owner("/runlight/api/tokens/#{id}", "DELETE")).status
    assert_equal 404, routes.handle(RoutesMake.owner("/runlight/api/tokens/#{id}", "DELETE")).status
    assert_equal 401, as.call("/api/stats?site=a", all["body"]["secret"]).status, "revoked at once"
  end

  on_every_database("the mcp server answers initialize lists its tools and calls them with the tokens reach") do |kind|
    _, routes, send = make(kind)
    secret = RoutesMake.body(routes.handle(RoutesMake.owner("/runlight/api/tokens", "POST", { "name" => "B only", "site" => "b" })))["secret"]
    send.call({ "k" => "pageview", "u" => "https://b.com/pricing", "r" => "https://news.ycombinator.com/", "i" => "p1" })
    send.call({ "k" => "pageview", "u" => "https://a.com/", "i" => "p2" })

    id = 0
    rpc = lambda do |method, params = nil, auth = nil|
      id += 1
      message = { "jsonrpc" => "2.0", "id" => id, "method" => method }
      message["params"] = params unless params.nil?
      answer = routes.handle(Request.new("https://example.com/runlight/mcp", method: "POST",
                                                                            headers: { "authorization" => "Bearer #{auth || secret}", "content-type" => "application/json", "accept" => "application/json, text/event-stream" },
                                                                            body: Json.encode(message)))
      { "status" => answer.status, "headers" => answer.headers, "body" => answer.status == 202 ? nil : RoutesMake.body(answer) }
    end

    refused = rpc.call("initialize", {}, "rl_#{"0" * 40}")
    assert_equal 401, refused["status"]
    assert_match(/\ABearer/, refused["headers"].get("www-authenticate") || "")
    assert_equal 405, routes.handle(RoutesMake.owner("/runlight/mcp")).status, "no event stream"

    init = rpc.call("initialize", { "protocolVersion" => "2025-06-18", "capabilities" => {}, "clientInfo" => { "name" => "test", "version" => "1" } })
    assert_equal "2025-06-18", init["body"]["result"]["protocolVersion"]
    assert_equal "runlight", init["body"]["result"]["serverInfo"]["name"]
    assert init["body"]["result"]["capabilities"].key?("tools")
    assert_equal "2025-11-25", rpc.call("initialize", { "protocolVersion" => "1999-01-01" })["body"]["result"]["protocolVersion"], "an unknown version gets the newest"

    note = routes.handle(Request.new("https://example.com/runlight/mcp", method: "POST", headers: { "authorization" => "Bearer #{secret}", "content-type" => "application/json" },
                                                                         body: Json.encode({ "jsonrpc" => "2.0", "method" => "notifications/initialized" })))
    assert_equal 202, note.status

    listed = rpc.call("tools/list")
    assert_equal(Runlight::Mcp.tools.map { |t| t["name"] }, listed["body"]["result"]["tools"].map { |t| t["name"] })
    listed["body"]["result"]["tools"].each { |tool| assert_equal true, tool["annotations"]["readOnlyHint"] }

    call = lambda do |name, args = nil|
      result = rpc.call("tools/call", { "name" => name, "arguments" => args || {} })["body"]["result"]
      result.merge("data" => Runlight::Js.truthy?(result["isError"]) ? nil : Json.decode(result["content"][0]["text"])) { |_k, mine, _theirs| mine }
    end
    assert_equal ["b"], call.call("list_sites")["data"]["sites"].map { |s| s["id"] }
    stats = call.call("get_stats", { "period" => "today" })
    assert_equal "b", stats["data"]["site"]
    assert_equal 1, stats["data"]["stats"]["pageviews"]
    assert_equal true, call.call("get_stats", { "site" => "a" })["isError"], "another site is out of reach"
    sources = call.call("get_breakdown", { "period" => "today", "dimension" => "source", "limit" => 500 })
    assert_equal "Hacker News", sources["data"]["rows"][0]["value"]
    assert_equal 0, call.call("get_stats", { "period" => "today", "filters" => ["page:is:/nowhere"] })["data"]["stats"]["pageviews"]
    bad = call.call("get_stats", { "filters" => ["nonsense"] })
    assert_equal true, bad["isError"]
    assert_match(/Bad filter/, bad["content"][0]["text"])
    times = call.call("get_visit_times", { "period" => "today" })
    assert_equal 7, times["data"]["grid"].length
    refute times["data"].key?("cells"), "trimmed to what an assistant needs"
    assert_equal 0, call.call("list_goals", { "period" => "today" })["data"]["goals"].length
    assert_equal true, call.call("get_goal", { "goal_id" => "f" * 24 })["isError"]
    refute call.call("list_links").key?("isError")
    refute call.call("get_realtime").key?("isError")

    assert_equal(-32_602, rpc.call("tools/call", { "name" => "drop_tables" })["body"]["error"]["code"])
    assert_equal(-32_601, rpc.call("resources/list")["body"]["error"]["code"])
    assert_equal({}, rpc.call("ping")["body"]["result"])

    # The owner's own token works too, across every site.
    everything = rpc.call("tools/call", { "name" => "list_sites", "arguments" => {} }, "secret")
    assert_equal %w[a b], Json.decode(everything["body"]["result"]["content"][0]["text"])["sites"].map { |s| s["id"] }
  end
end
