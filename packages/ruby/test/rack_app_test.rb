# frozen_string_literal: true

require "test_helper"
require "rack/mock"
require "rack/lint"

# Runlight::RackApp on its own and as middleware in front of a plain Rack app: Runlight's paths, short links,
# AI agent fetches, bodies left for the app, and the work that runs once an answer is sent.
class RackAppTest < Minitest::Test
  TOKEN = "rack-test-token"
  SAFARI = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

  def setup
    @now = 1_791_000_000_000
    @store = Runlight::Stores.sqlite(":memory:")
    @rl = Runlight.new(store: @store, site: { name: "Example", hostnames: ["example.com"] }, now: -> { @now })
    @inner = lambda do |env|
      [200, { "content-type" => "text/plain" }, ["app saw #{env["REQUEST_METHOD"]} #{env["PATH_INFO"]} #{env["rack.input"]&.read}"]]
    end
    @app = Rack::MockRequest.new(Rack::Lint.new(Runlight::RackApp.new(@inner, runlight: @rl, base_path: "/runlight", token: TOKEN)))
  end

  def test_runlight_paths_are_answered_and_the_rest_reach_the_app
    tracker = @app.get("/runlight/s.js", "HTTP_HOST" => "example.com")
    assert_equal 200, tracker.status
    assert_match(/javascript/, tracker.headers["content-type"])

    page = @app.post("/contact", "HTTP_HOST" => "example.com", "CONTENT_TYPE" => "text/plain", input: "hello")
    assert_equal "app saw POST /contact hello", page.body

    assert_equal 401, @app.get("/runlight/api/sites", "HTTP_HOST" => "example.com").status
    sites = @app.get("/runlight/api/sites", "HTTP_HOST" => "example.com", "HTTP_AUTHORIZATION" => "Bearer #{TOKEN}")
    assert_equal 200, sites.status
  end

  def test_a_pageview_is_recorded_and_an_ai_agent_fetch_of_an_app_page_is_observed
    event = Runlight::Json.encode({ "k" => "pageview", "u" => "https://example.com/pricing", "r" => "" })
    answer = @app.post("/runlight/e", "HTTP_HOST" => "example.com", "CONTENT_TYPE" => "text/plain", input: event,
                                      "HTTP_USER_AGENT" => SAFARI, "REMOTE_ADDR" => "203.0.113.9")
    assert_equal 202, answer.status
    page = @app.get("/docs", "HTTP_HOST" => "example.com", "HTTP_USER_AGENT" => "Mozilla/5.0 (compatible; GPTBot/1.2; +https://openai.com/gptbot)")
    assert_equal "app saw GET /docs ", page.body
    kinds = @store.db.all("SELECT kind, path FROM rl_events ORDER BY kind").map { |row| [row["kind"], row["path"]] }
    assert_equal [["fetch", "/docs"], ["pageview", "/pricing"]], kinds
  end

  def test_a_short_link_redirects_on_the_apps_own_domain
    @rl.links.create("default", { "slug" => "launch", "url" => "https://example.org/launch" })
    answer = @app.get("/go/launch", "HTTP_HOST" => "example.com", "HTTP_USER_AGENT" => SAFARI)
    assert_includes [301, 302, 307, 308], answer.status
    assert_equal "https://example.org/launch", answer.headers["location"]
  end

  def test_a_link_domain_is_answered_before_the_app_and_the_apps_own_host_reaches_the_app
    @rl.init
    @store.add_link_domain("go.example.com", "default", @now)
    @rl.forget_link_domains
    @rl.links.create("default", { "slug" => "launch", "url" => "https://example.org/launch", "domain" => "go.example.com" })
    answer = @app.get("/launch", "HTTP_HOST" => "go.example.com", "HTTP_USER_AGENT" => SAFARI)
    assert_includes [301, 302, 307, 308], answer.status
    assert_equal "https://example.org/launch", answer.headers["location"]
    assert_equal "app saw GET /launch ", @app.get("/launch", "HTTP_HOST" => "example.com", "HTTP_USER_AGENT" => SAFARI).body
  end

  def test_alone_it_answers_everything_and_a_head_has_no_body
    alone = Rack::MockRequest.new(Runlight::RackApp.new(runlight: @rl, base_path: "/runlight", token: TOKEN))
    assert_equal 404, alone.get("/elsewhere", "HTTP_HOST" => "example.com").status
    head = alone.request("HEAD", "/elsewhere", "HTTP_HOST" => "example.com")
    assert_equal 404, head.status
    assert_equal "", head.body
  end

  # A request body that never ends, as a chunked upload with no Content-Length can be, counting what is read.
  class Endless
    attr_reader :read_bytes

    def initialize
      @read_bytes = 0
    end

    def read(length = nil, buffer = nil)
      raise "read without a length would never end" if length.nil?

      @read_bytes += length
      chunk = "x" * length
      buffer ? buffer.replace(chunk) : chunk
    end

    def rewind; end
  end

  def post(path, input, headers = {})
    env = Rack::MockRequest.env_for(path, { method: "POST", "HTTP_HOST" => "example.com", "CONTENT_TYPE" => "text/plain" }.merge(headers))
    env["rack.input"] = input
    Runlight::RackApp.new(runlight: @rl, base_path: "/runlight", token: TOKEN).call(env)
  end

  def test_a_body_past_its_limit_is_answered_413_after_reading_one_byte_past_it
    collect = Endless.new
    status, headers, body = post("/runlight/e", collect)
    assert_equal 413, status
    assert_equal "close", headers["connection"]
    assert_equal({ "error" => "That request is too large" }, Runlight::Json.decode(body.join))
    assert_operator collect.read_bytes, :<=, (16 * 1024) + 1, "the collect endpoint reads at most 16 KB and a byte"

    api = Endless.new
    status, = post("/runlight/api/links/import", api, "HTTP_AUTHORIZATION" => "Bearer #{TOKEN}")
    assert_equal 413, status
    assert_operator api.read_bytes, :<=, (10 * 1024 * 1024) + 1, "everything else reads at most 10 MB and a byte"
  end

  def test_a_content_length_past_the_limit_is_refused_unread_and_one_under_it_is_not_trusted
    declared = Endless.new
    status, = post("/runlight/e", declared, "CONTENT_LENGTH" => (2 * 1024 * 1024 * 1024).to_s)
    assert_equal 413, status
    assert_equal 0, declared.read_bytes

    lying = Endless.new
    status, = post("/runlight/e", lying, "CONTENT_LENGTH" => "10")
    assert_equal 413, status
    assert_operator lying.read_bytes, :<=, (16 * 1024) + 1

    event = Runlight::Json.encode({ "k" => "pageview", "u" => "https://example.com/", "r" => "" })
    status, = post("/runlight/e", StringIO.new(event), "CONTENT_LENGTH" => event.bytesize.to_s, "HTTP_USER_AGENT" => SAFARI,
                                                         "REMOTE_ADDR" => "203.0.113.9")
    assert_equal 202, status, "a body within the limit is read whole"
  end

  def test_the_routes_as_a_rack_app_cap_the_body_too
    env = Rack::MockRequest.env_for("/runlight/e", method: "POST", "HTTP_HOST" => "example.com")
    env["rack.input"] = Endless.new
    status, = @rl.routes({ base_path: "/runlight" }).call(env)
    assert_equal 413, status
  end
end
