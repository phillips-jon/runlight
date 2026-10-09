# frozen_string_literal: true

require "test_helper"
require "base64"
require_relative "routes/make"

# The edge cases of edges.test.ts: mail keys, ports, and webhook addresses, MCP notifications and odd batch
# elements, assistant answers in shapes it cannot read, icon link attributes, importer and browser names like
# a JavaScript object's own properties, and connect attempts without an expiry.
class EdgesTest < Minitest::Test
  include RoutesMake

  Json = Runlight::Json
  Transports = Runlight::Mail::Transports
  MESSAGE = { "to" => "jon@example.com", "from" => "reports@example.com", "subject" => "Hello", "html" => "<p>Hi</p>", "text" => "Hi" }.freeze

  def code
    yield
    nil
  rescue StandardError => e
    e.respond_to?(:code) ? e.code : e.class.name
  end

  def test_mail_basic_auth_carries_a_key_as_utf8_whatever_its_characters
    fetcher = FakeFetcher.new { Runlight::Http::Response.new("{}") }
    Transports.deliver({ "service" => "mailgun", "apiKey" => "ключ", "domain" => "mg.example.com", "region" => "us" }, MESSAGE, fetcher)
    Transports.deliver({ "service" => "mailjet", "apiKey" => "mj", "secretKey" => "kéy 😀" }, MESSAGE, fetcher)
    assert_equal ["Basic #{Base64.strict_encode64("api:ключ")}", "Basic #{Base64.strict_encode64("mj:kéy 😀")}"],
                 fetcher.requests.map { |r| r["headers"]["authorization"] }
  end

  def test_mail_an_smtp_port_out_of_range_is_refused_before_anything_is_saved_or_sent
    smtp = ->(port) { { "service" => "smtp", "host" => "smtp.example.com", "port" => port, "security" => "starttls" } }
    %w[70000 65536 0 -1 1.5 abc Infinity 0o200000 0b0 1e6].each do |port|
      assert_equal "mail_port", code { Transports.check_config(smtp.call(port)) }, port
    end
    ["587", " 465 ", "65535", "1", "0x24b", "0o1113", "0b1001001011", "5.87e2"].each do |port|
      assert_nil code { Transports.check_config(smtp.call(port)) }, port
    end
    error = assert_raises(Runlight::Mail::MailError) { Transports.check_config(smtp.call("70000")) }
    assert_equal "The port must be a whole number from 1 to 65535", error.message
  end

  def test_mail_a_webhook_address_that_is_not_a_url_is_refused_before_anything_is_saved_or_sent
    ["https://", "https://[", "https:// /x"].each do |url|
      error = assert_raises(Runlight::Mail::MailError, url) { Transports.check_config({ "service" => "webhook", "url" => url }) }
      assert_equal "mail_url", error.code, url
      assert_equal "Enter the webhook's whole URL, like https://example.com/hooks/mail", error.message
    end
    assert_nil code { Transports.check_config({ "service" => "webhook", "url" => "https://hooks.example.com/mail" }) }
    assert_equal "mail_https", code { Transports.check_config({ "service" => "webhook", "url" => "http://example.com/x" }) }
  end

  def mcp(body)
    asked = []
    request = Runlight::Http::Request.new("https://x.com/mcp", method: "POST", body: Json.encode(body))
    answer = Runlight::Mcp.mcp_response(request, lambda { |path, _params|
      asked << path
      Runlight::Http::Response.new('{"ok":true}')
    })
    { "status" => answer.status, "body" => answer.status == 202 ? nil : Json.decode(answer.text), "asked" => asked }
  end

  def test_mcp_a_notification_runs_nothing_and_is_answered_with_nothing
    assert_equal({ "status" => 202, "body" => nil, "asked" => [] }, mcp({ "jsonrpc" => "2.0", "method" => "tools/call", "params" => { "name" => "get_stats" } }))
    assert_equal({ "status" => 202, "body" => nil, "asked" => [] }, mcp([{ "jsonrpc" => "2.0", "method" => "tools/call", "params" => { "name" => "list_sites" } }]))
  end

  def test_mcp_a_batch_element_that_is_not_an_object_is_an_invalid_request_of_its_own
    invalid = { "jsonrpc" => "2.0", "id" => nil, "error" => { "code" => -32_600, "message" => "Invalid request" } }
    answer = mcp([nil, { "jsonrpc" => "2.0", "id" => 1, "method" => "ping" }, 5, []])
    assert_equal 200, answer["status"]
    assert_equal Json.encode([invalid, { "jsonrpc" => "2.0", "id" => 1, "result" => {} }, invalid, invalid]), Json.encode(answer["body"])
    alone = mcp([nil])
    assert_equal 200, alone["status"]
    assert_equal Json.encode([invalid]), Json.encode(alone["body"])
  end

  def test_mcp_a_refusal_whose_body_is_null_or_not_an_object_reads_like_any_other_refusal
    ["null", "5", '"text"', "[1]"].each do |body|
      result = Runlight::Mcp.call_tool({ "name" => "list_sites" }, ->(_p, _q) { Runlight::Http::Response.new(body, status: 403) })
      assert_equal Json.encode({ "content" => [{ "type" => "text", "text" => "Runlight answered 403" }], "isError" => true }), Json.encode(result), body
    end
    # An answer that is fine but null is passed on as it is, even through a tool that reshapes its answers.
    ["null", "[1]", "5"].each do |body|
      fine = Runlight::Mcp.call_tool({ "name" => "get_visit_times" }, ->(_p, _q) { Runlight::Http::Response.new(body) })
      assert_equal Json.encode({ "content" => [{ "type" => "text", "text" => body }] }), Json.encode(fine), body
    end
  end

  CONTEXT = { "site" => { "id" => "default", "name" => "Site", "timezone" => "UTC" }, "today" => "2026-10-08", "view" => "today", "language" => "en" }.freeze
  QUESTION = [{ "role" => "user", "content" => "How many visitors?" }].freeze

  def answering(body)
    FakeFetcher.new { Runlight::Http::Response.new(Json.encode(body)) }
  end

  def test_assistant_an_answer_in_a_shape_it_cannot_read_is_assistant_failed_for_every_protocol
    read_api = ->(_p, _q) { Runlight::Http::Response.new("{}") }
    [
      ["anthropic", { "content" => "text" }],
      ["anthropic", { "content" => [nil] }],
      ["anthropic", { "stop_reason" => "tool_use", "content" => [{ "type" => "tool_use", "id" => "t", "name" => "list_sites", "input" => {} }, 5] }],
      ["anthropic", { "content" => { "type" => "text" } }],
      ["openai", { "choices" => [{ "message" => { "tool_calls" => "abc" } }] }],
      ["openai", { "choices" => [{ "message" => { "tool_calls" => [nil] } }] }],
      ["openai", { "choices" => [{ "message" => { "tool_calls" => [{}] } }] }],
      ["openai", { "choices" => [{ "message" => { "tool_calls" => [{ "id" => "c", "function" => nil }] } }] }],
      ["openai", { "choices" => [{ "message" => { "tool_calls" => { "length" => 1 } } }] }],
    ].each do |provider, body|
      label = "#{provider} #{Json.encode(body)}"
      error = assert_raises(Runlight::AssistantError, label) do
        Runlight::Assistant.chat({ "provider" => provider, "model" => "m", "baseUrl" => "", "key" => "k" }, QUESTION, CONTEXT, read_api, answering(body))
      end
      assert_equal "assistant_failed", error.code, label
      assert_kind_of String, error.params["detail"], label
      assert_equal "#{error.params["host"]} sent an answer Runlight could not read", error.message, label
    end
    [{ "data" => "x" }, { "data" => {} }].each do |body|
      error = assert_raises(Runlight::AssistantError) { Runlight::Assistant.list_models({ "provider" => "openai", "baseUrl" => "", "key" => "k" }, answering(body)) }
      assert_equal "assistant_failed", error.code, Json.encode(body)
    end
    # A list with entries that are not models is read like one with entries that have no id.
    listed = Runlight::Assistant.list_models({ "provider" => "openai", "baseUrl" => "", "key" => "k" }, answering({ "data" => [nil, 5, { "id" => "m1" }] }))
    assert_equal [{ "id" => "m1", "name" => "m1" }], listed
  end

  def test_assistant_the_chat_route_answers_a_reply_it_cannot_read_with_502_assistant_failed
    fetcher = FakeFetcher.new { Runlight::Http::Response.new('{"content":"text"}') }
    routes = runlight({ "secret" => "k" * 32, "fetcher" => fetcher }).routes({ "token" => "owner" })
    saved = routes.handle(owner("/runlight/api/assistant", "PUT", { "provider" => "anthropic", "model" => "m", "key" => "k" }, "owner"))
    assert_equal 200, saved.status, saved.text
    answer = routes.handle(owner("/runlight/api/assistant/chat", "POST", { "messages" => QUESTION }, "owner"))
    assert_equal 502, answer.status
    assert_equal "assistant_failed", body(answer)["code"]
  end

  def test_assistant_thanks_in_a_language_named_like_a_property_of_every_object_is_answered_in_english
    %w[constructor __proto__ toString].each do |language|
      assert_equal Runlight::Assistant.acknowledgement("Thanks!", "en"), Runlight::Assistant.acknowledgement("Thanks!", language), language
    end
  end

  def test_icons_only_the_rel_attribute_itself_says_what_a_link_is
    base = "https://example.com/"
    assert_equal ["https://example.com/a.png"], Runlight::Icon.icon_links('<link data-rel="x" rel="icon" href="/a.png">', base)
    assert_equal ["https://example.com/right.png"], Runlight::Icon.icon_links('<link rel="icon" data-href="/wrong.png" href="/right.png">', base)
    assert_equal [], Runlight::Icon.icon_links('<link title="rel=icon" rel="stylesheet" href="/s.css">', base)
    assert_equal ["https://example.com/first.png"], Runlight::Icon.icon_links('<link rel="icon" href="/first.png" href="/second.png">', base)
  end

  def test_importers_a_source_named_like_a_property_of_every_object_is_unknown
    rl = runlight
    routes = rl.routes({ "token" => nil })
    answer = routes.handle(req("/runlight/api/links/import/constructor", "POST", { "content-type" => "application/json" }, Json.encode({ "credentials" => {} })))
    assert_equal 400, answer.status
    assert_equal "import_source", body(answer)["code"]
    %w[constructor toString __proto__ hasOwnProperty].each do |source|
      error = assert_raises(Runlight::Importers::ImportError, source) { Runlight::Importers::Index.import_step(rl, "default", source, {}, nil, 0) }
      assert_equal "import_source", error.code, source
    end
    write = Runlight::Importers::Write
    assert_equal %w[Constructor __proto__ ToString], %w[constructor __proto__ toString].map { |n| write.browser(n) }
    assert_equal %w[constructor toString], %w[constructor toString].map { |n| write.system_name(n) }
    assert_equal ["", ""], %w[constructor valueOf].map { |n| write.device(n) }
  end

  def test_importers_a_browser_system_or_device_named_like_a_property_of_every_object_is_just_a_name
    rl = runlight({ "site" => { "hostnames" => ["blog.example.com"], "timezone" => "UTC" }, "now" => -> { utc(2026, 3, 4) } })
    routes = rl.routes({ "token" => nil })
    rows = [{ "time" => "2026-03-01T10:00:00Z", "path" => "/", "visitor" => "a", "browser" => "constructor", "os" => "toString", "device" => "valueOf" }]
    answer = routes.handle(req("/runlight/api/import/csv/visits", "POST", { "content-type" => "application/json" }, Json.encode({ "rows" => rows })))
    assert_equal 200, answer.status, answer.text
    assert_equal 1, body(answer)["visits"]
    assert_equal [{ "browser" => "Constructor", "os" => "toString", "device" => "" }], rl.store.db.all("SELECT browser, os, device FROM rl_sessions")

    # Clicks from a link service take the same path.
    fetcher = FakeFetcher.new do |url, _init|
      answer = if url.include?("startingAfter") then []
               elsif url.match?(%r{/links\?}) then [{ "id" => "l1", "domain" => "dub.sh", "key" => "x", "url" => "https://a.com/x", "title" => "X", "createdAt" => "2026-01-02T00:00:00Z" }]
               else [{ "timestamp" => "2026-03-01T10:00:00Z", "click" => { "id" => "c1", "country" => "CA", "device" => "constructor", "browser" => "__proto__", "os" => "constructor" } }]
               end
      Runlight::Http::Response.new(Json.encode(answer), headers: { "content-type" => "application/json" })
    end
    links = runlight({ "fetcher" => fetcher })
    cursor = nil
    clicks = 0
    loop do
      step = Runlight::Importers::Index.import_step(links, "default", "dub", { "apiKey" => "k" }, cursor, 0)
      assert_equal [], step["failed"]
      clicks += step["clicks"]
      cursor = step["cursor"]
      break if cursor.nil?
    end
    assert_equal 1, clicks
    assert_equal [{ "browser" => "__proto__", "os" => "constructor", "device" => "" }], links.store.db.all("SELECT browser, os, device FROM rl_sessions")
  end

  def test_connect_an_attempt_saved_without_an_expiry_has_expired
    fetcher = FakeFetcher.new { raise "nothing should be fetched" }
    rl = runlight({ "managedSites" => true, "secret" => "k" * 32, "fetcher" => fetcher })
    rl.init
    state = "a" * 32
    [{ "url" => "https://example.com", "client" => "c", "verifier" => "v", "redirect" => "https://x.com/back", "token" => "https://example.com/token" },
     nil, 5, { "expires" => "9999999999999" }].each do |stored|
      rl.store.set_setting("connect:#{state}", Json.encode(stored))
      error = assert_raises(Runlight::ConnectError, Json.encode(stored)) do
        Runlight::Connect.finish_connect(rl, Runlight::Http::SearchParams.new({ "state" => state, "code" => "c" }))
      end
      assert_equal "expired", error.code, Json.encode(stored)
    end
    assert_equal [], fetcher.requests
  end

  def test_connect_an_address_the_url_parser_refuses_is_the_address_error
    ["https://[", "https://[::1", "https://a b"].each do |url|
      error = assert_raises(Runlight::ConnectError, url) { Runlight::Connect.install_url(url) }
      assert_equal "url", error.code, url
    end
    assert_equal "https://example.com/runlight", Runlight::Connect.install_url("https://example.com/runlight/")
  end
end
