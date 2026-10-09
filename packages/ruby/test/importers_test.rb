# frozen_string_literal: true

require "test_helper"

# Replays the importer scenarios in tests/fixtures/outbound.json (the cases of importers.test.ts and
# more): each importer, run step by step against the same answers, must send the TypeScript SDK's
# exact requests, wait as long between retries, ask about the same known links, and hand back the
# same steps, cursors included. The store side of an import (import_step, write_link) is in
# core/import_step_test.rb.
class ImportersTest < Minitest::Test
  Client = Runlight::Importers::Client
  Json = Runlight::Json
  IMPORTERS = {
    "bitly" => Runlight::Importers::Bitly, "dub" => Runlight::Importers::Dub, "rebrandly" => Runlight::Importers::Rebrandly,
    "shortio" => Runlight::Importers::Shortio, "umami" => Runlight::Importers::Umami,
  }.freeze

  def run_scenario(scenario)
    now = Fixtures.load("outbound")["now"]
    left = scenario["routes"].map { |r| r["times"] || Float::INFINITY }
    fetcher = FakeFetcher.new do |url, _init|
      answer = nil
      scenario["routes"].each_with_index do |route, i|
        next if left[i] <= 0 || !url.match?(Regexp.new(route["pattern"]))

        left[i] -= 1
        raise Runlight::Http::FetchError, "fetch failed" if route["unreachable"]

        answer = Runlight::Http::Response.new(Json.encode(route["body"]), status: route["status"] || 200,
                                                                          headers: { "content-type" => "application/json" }.merge(route["headers"] || {}))
        break
      end
      answer || Runlight::Http::Response.new("{}", status: 404)
    end
    waits = []
    http = Client.new(fetcher, ->(ms) { waits << ms })
    importer = IMPORTERS.fetch(scenario["source"]).new(http, -> { now })
    assert_kind_of Runlight::Importers::Importer, importer
    known_calls = []
    known = lambda do |source_id, slug = nil, url = nil|
      known_calls << [source_id, slug, url]
      scenario["known"].include?(source_id) || scenario["known"].include?("#{slug} #{url}")
    end

    expected = scenario["steps"]
    cursor = expected[0] ? expected[0]["cursor"] : nil
    expected.each_with_index do |want, i|
      assert_equal Json.encode(want["cursor"]), Json.encode(cursor), "step #{i} starts from the same cursor"
      begin
        result = importer.step(scenario["credentials"], cursor, known)
      rescue Runlight::Importers::ImportError => e
        assert want.key?("error"), "step #{i} should not fail: #{e.message}"
        got = { "message" => e.message, "code" => e.code, "params" => e.params }
        got["status"] = e.status if e.is_a?(Runlight::Importers::HttpError)
        got["name"] = e.class.name.split("::").last
        assert_equal Json.encode(want["error"]), Json.encode(got)
        next
      end
      refute want.key?("error"), "step #{i} should fail"
      assert_equal Json.encode(want["result"]), Json.encode(result), "step #{i}"
      cursor = result["cursor"]
    end

    sent = fetcher.requests
    requests = scenario["requests"]
    unless scenario["ordered"]
      # Umami asks for a link's events and sessions at once in TS; here one follows the other.
      sent = sent.map { |r| Json.encode(r) }.sort
      requests = requests.map { |r| Json.encode(r) }.sort
    end
    assert_equal requests, sent
    assert_equal scenario["waits"], waits
    assert_equal scenario["knownCalls"], known_calls
  end

  Fixtures.load("outbound")["importers"].each do |scenario|
    define_method("test_scenario_matches_typescript: #{scenario["name"]}") { run_scenario(scenario) }
  end

  def test_dates_parse_as_javascript_parses_them
    assert_equal 1_767_225_600_000, Client.parse_date("2026-01-01T00:00:00Z")
    assert_equal 1_767_225_600_000, Client.parse_date("2026-01-01T00:00:00+0000")
    assert_equal 1_767_225_600_000, Client.parse_date("2026-01-01")
    assert_equal 1_767_225_600_500, Client.parse_date("2026-01-01T02:00:00.5+02:00")
    local = 1_767_225_600_000 - (Time.at(1_767_225_600).utc_offset * 1000)
    assert_equal local, Client.parse_date("2026-01-01T00:00:00"), "local time, in the process's zone"
    assert_equal 0, Client.parse_date("1970-01-01T00:00:00.000Z")
    assert Client.parse_date("nope").nan?
    assert Client.parse_date("2026-02-30").nan?
    assert Client.parse_date(nil).nan?
    assert_equal "2026-03-02T00:00:00.000Z", Client.iso_string(1_772_409_600_000)
    assert_equal "1969-12-31T23:59:59.999Z", Client.iso_string(-1)
    assert_raises(RangeError) { Client.iso_string(Float::NAN) }
  end

  def test_javascript_values_read_as_they_do
    assert_equal [false, false, false, true, true, false, true], [nil, "", 0, "0", [], Float::NAN, 0.5].map { |v| Client.truthy?(v) }
    assert_equal ["7", "7", "null", "undefined", "a,b", "1e+21"], [7, 7.0, nil, Runlight::UNDEFINED, %w[a b], 1e21].map { |v| Client.str(v) }
    assert_equal [0, 2, 1.5, 31], [nil, " 2 ", "1.5", "0x1f"].map { |v| Client.number(v) }
    assert Client.number("soon").nan?
    assert_equal "a%20b%2Fc!'()*~", Client.encode_uri_component("a b/c!'()*~")
  end
end
