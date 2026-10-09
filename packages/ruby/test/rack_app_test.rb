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

  def test_alone_it_answers_everything_and_a_head_has_no_body
    alone = Rack::MockRequest.new(Runlight::RackApp.new(runlight: @rl, base_path: "/runlight", token: TOKEN))
    assert_equal 404, alone.get("/elsewhere", "HTTP_HOST" => "example.com").status
    head = alone.request("HEAD", "/elsewhere", "HTTP_HOST" => "example.com")
    assert_equal 404, head.status
    assert_equal "", head.body
  end
end
