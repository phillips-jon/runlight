# frozen_string_literal: true

require "stringio"

# What the route tests share: a Runlight on an in-memory SQLite, and requests written as the TypeScript tests
# write them. (The PHP tests' stand-in for a core that was not written yet has no place here: the Ruby core is.)
module RoutesMake
  # What the routes and the core read from the environment, cleared around each test.
  ENV_NAMES = %w[RUNLIGHT_TOKEN RUNLIGHT_SECRET CRON_SECRET RUNLIGHT_OBSERVE_KEY NODE_ENV].freeze

  module_function

  # A Runlight with these options and an in-memory SQLite unless a store is given.
  def runlight(options = {})
    Runlight::Core.new({ "store" => Runlight::Stores.sqlite(":memory:") }.merge(options))
  end

  def req(path, method = "GET", headers = {}, body = nil)
    headers = headers.dup
    # JavaScript's Request gives a string body this type when none is named.
    headers["content-type"] = "text/plain;charset=UTF-8" if !body.nil? && !headers.key?("content-type")
    Runlight::Http::Request.new("https://example.com#{path}", method: method, headers: headers, body: body || "")
  end

  # A JSON request with a bearer token, as the tests' owner sends it.
  def owner(path, method = "GET", body = nil, token = "secret")
    headers = { "authorization" => "Bearer #{token}" }
    headers["content-type"] = "application/json" unless body.nil?
    req(path, method, headers, body.nil? ? nil : Runlight::Json.encode(body))
  end

  # The answer's body as JSON.
  def body(response)
    Runlight::Json.decode(response.text)
  end

  # Clears the environment the routes read, returning what was there to put back.
  def clear_env
    ENV_NAMES.to_h { |name| [name, ENV.delete(name)] }
  end

  def restore_env(saved)
    saved.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  # Runs the block with what it warns kept out of the test's output.
  def quietly
    saved = $stderr
    $stderr = StringIO.new
    yield
  ensure
    $stderr = saved
  end

  # Date.UTC with months counted from 1.
  def utc(y, m, d, h = 0, i = 0, s = 0)
    Time.utc(y, m, d, h, i, s).to_i * 1000
  end
end

# A test with the environment the routes read cleared around it.
class RoutesTestCase < Minitest::Test
  def setup
    super
    @env = RoutesMake.clear_env
  end

  def teardown
    RoutesMake.restore_env(@env)
    super
  end

  # Defines one test per database kind, as a PHPUnit data provider over kinds() does.
  def self.on_every_database(name, &block)
    Databases.kinds.each do |kind|
      define_method("test_#{name}_on_#{kind}") { instance_exec(kind, &block) }
    end
  end
end
