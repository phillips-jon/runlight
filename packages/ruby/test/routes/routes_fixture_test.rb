# frozen_string_literal: true

require "test_helper"
require_relative "make"

# Replays packages/php/tests/fixtures/routes.json, which scripts/php-fixtures-routes.mts writes from the TypeScript
# SDK: the dashboard's page, the tracker, refusals with their codes, and OAuth's documents, each answer byte for
# byte with every header, and the helpers routes.ts and oauth.ts export.
class RoutesRoutesFixtureTest < RoutesTestCase
  Routes = Runlight::Routes

  Fixtures.load("routes")["exchanges"].each_with_index do |exchange, index|
    define_method("test_answers_as_the_typescript_does: #{exchange["name"]}") { replay(index) }
  end

  def replay(index)
    fixture = Fixtures.load("routes")
    exchange = fixture["exchanges"][index]
    now = fixture["now"]
    rl = RoutesMake.runlight(exchange["runlight"].merge("now" => -> { now }))
    routes = rl.routes(exchange["routes"])
    exchange["answers"].each do |answer|
      ask = answer["ask"]
      label = "#{ask["method"] || "GET"} #{ask["path"]}"
      headers = (ask["headers"] || {}).transform_keys(&:downcase)
      headers["content-type"] = "text/plain;charset=UTF-8" if ask.key?("body") && !ask["body"].nil? && !headers.key?("content-type")
      response = routes.handle(Runlight::Http::Request.new("https://example.com#{ask["path"]}", method: ask["method"] || "GET", headers: headers, body: ask["body"] || ""))
      assert_equal answer["status"], response.status, "#{label}: status"
      got = {}
      response.headers.all.each { |name, values| got[name] = name == "set-cookie" ? values : values.join(", ") }
      assert_equal answer["headers"].sort.to_h, got.sort.to_h, "#{label}: headers"
      body = response.text
      if answer.key?("sha256")
        assert_equal answer["sha256"], OpenSSL::Digest::SHA256.hexdigest(body), "#{label}: body"
      else
        assert_equal answer["text"], body, "#{label}: body"
      end
    end
  end

  def test_coded_errors_are_the_same_bytes
    Fixtures.load("routes")["coded"].each do |c|
      error, code, status, params, headers = c["args"]
      response = Routes.coded(error, code, status, params, headers || {})
      assert_equal c["status"], response.status
      assert_equal c["text"], response.text, code
      got = response.headers.all.transform_values { |v| v.join(", ") }
      assert_equal c["headers"].sort.to_h, got.sort.to_h, code
    end
  end

  def test_host_names_are_bare_as_the_typescript_makes_them
    Fixtures.load("routes")["hostName"].each do |given, want|
      assert_equal want, Routes.host_name(given), given
    end
  end

  def test_manage_paths_are_the_same
    Fixtures.load("routes")["managePath"].each do |method, path, want|
      assert_equal want, Routes.manage_path(method, path), "#{method} #{path}"
    end
  end

  def test_pkce_s256_matches_the_typescript
    Fixtures.load("routes")["s256"].each do |verifier, want|
      assert_equal want, Runlight::OAuth.s256(verifier), verifier
    end
    # RFC 7636's own example.
    assert_equal "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", Runlight::OAuth.s256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
  end

  def test_resource_metadata_url
    Fixtures.load("routes")["resourceMetadataUrl"].each do |origin, base, want|
      assert_equal want, Runlight::OAuth.resource_metadata_url(origin, base)
    end
  end
end
