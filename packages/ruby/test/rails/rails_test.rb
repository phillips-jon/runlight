# frozen_string_literal: true

require_relative "../support/rails_app"
require "rake"
require "rack/mock"

# The engine in a booted Rails app: the install generator, its migration, the middleware serving Runlight
# beside the app's own routes, and the rake tasks.
class RailsEngineTest < Minitest::Test
  TOKEN = "rails-test-token"

  def setup
    connection = ActiveRecord::Base.connection
    connection.tables.grep(/\Arl_/).each { |table| connection.drop_table(table) }
    Runlight.configure(store: Runlight::Stores.active_record, site: { name: "Example", hostnames: ["example.com"] },
                       routes: { base_path: "/runlight", token: TOKEN })
    @app = Rack::MockRequest.new(RailsApp::Application)
  end

  def test_the_generator_writes_the_initializer_and_a_migration_that_makes_the_tables
    Dir.mktmpdir do |dir|
      Runlight::Generators::InstallGenerator.start([], destination_root: dir, shell: Thor::Shell::Basic.new.tap { |s| s.mute { nil } })
      initializer = File.read(File.join(dir, "config/initializers/runlight.rb"))
      assert_includes initializer, "Runlight.configure("
      assert_includes initializer, "Runlight::Stores.active_record"
      migration = Dir[File.join(dir, "db/migrate/*_create_runlight_tables.rb")].first
      refute_nil migration
      load migration
      CreateRunlightTables.new.migrate(:up)
      tables = ActiveRecord::Base.connection.tables
      assert_includes tables, "rl_events"
      assert_includes tables, "rl_meta"
      CreateRunlightTables.new.migrate(:down)
      assert_empty ActiveRecord::Base.connection.tables.grep(/\Arl_/)
    end
  end

  def test_the_middleware_serves_runlight_and_passes_the_rest_to_the_app
    tracker = @app.get("/runlight/s.js", "HTTP_HOST" => "example.com")
    assert_equal 200, tracker.status
    assert_match(/javascript/, tracker.headers["content-type"])

    hello = @app.get("/hello", "HTTP_HOST" => "example.com")
    assert_equal 200, hello.status
    assert_equal "hello from the app", hello.body

    # A body the app answers is left for the app to read.
    form = @app.post("/form", "HTTP_HOST" => "example.com", "CONTENT_TYPE" => "text/plain", input: "a=1")
    assert_equal "a=1", form.body

    closed = @app.get("/runlight/api/sites", "HTTP_HOST" => "example.com")
    assert_equal 401, closed.status
    sites = @app.get("/runlight/api/sites", "HTTP_HOST" => "example.com", "HTTP_AUTHORIZATION" => "Bearer #{TOKEN}")
    assert_equal 200, sites.status
    assert_equal "Example", Runlight::Json.decode(sites.body).dig(0, "name") || Runlight::Json.decode(sites.body).dig("sites", 0, "name")
  end

  def test_a_link_domain_is_answered_before_the_router_and_the_apps_own_host_reaches_the_app
    core = Runlight.instance
    core.init
    core.store.add_link_domain("go.example.com", "default", core.now)
    core.forget_link_domains
    core.links.create("default", { "slug" => "hello", "url" => "https://example.org/launch", "domain" => "go.example.com" })
    safari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    answer = @app.get("/hello", "HTTP_HOST" => "go.example.com", "HTTP_USER_AGENT" => safari)
    assert_includes [301, 302, 307, 308], answer.status
    assert_equal "https://example.org/launch", answer.headers["location"]
    hello = @app.get("/hello", "HTTP_HOST" => "example.com", "HTTP_USER_AGENT" => safari)
    assert_equal "hello from the app", hello.body
  end

  def test_the_tracker_records_a_pageview_without_a_csrf_token
    event = Runlight::Json.encode({ "k" => "pageview", "u" => "https://example.com/pricing", "r" => "" })
    answer = @app.post("/runlight/e", "HTTP_HOST" => "example.com", "CONTENT_TYPE" => "text/plain", input: event,
                                      "HTTP_USER_AGENT" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                                      "REMOTE_ADDR" => "203.0.113.9")
    assert_equal 202, answer.status
    count = ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM rl_events WHERE kind = 'pageview'").to_i
    assert_equal 1, count
  end

  def test_rake_tasks_run_the_check_and_migrate
    RailsApp::Application.load_tasks if Rake::Task.tasks.none? { |t| t.name == "runlight:check" }
    out = capture_io { Rake::Task["runlight:migrate"].execute }.first
    assert_includes out, "up to date"
    out = capture_io { Rake::Task["runlight:check"].execute }.first
    assert_equal true, Runlight::Json.decode(out)["ok"]
  end
end
