# frozen_string_literal: true

require "test_helper"

# Replays conformance/ua.json, every case, and the wider fixture written from the TypeScript SDK.
class UaTest < Minitest::Test
  Ua = Runlight::Ua

  def test_conformance
    cases = Fixtures.conformance("ua")["cases"]
    cases.each_with_index do |c, i|
      label = "#{i} #{c["ua"][0, 90]}"
      agent = Ua.ai_agent(c["ua"])
      if c.key?("agent")
        assert_equal c["agent"]["name"], agent&.fetch("name"), label
        assert_equal c["agent"]["kind"], agent&.fetch("kind"), label
        next
      end
      assert_nil agent, "#{label}: not an AI agent"
      assert_equal c["bot"] ? true : false, Ua.bot?(c["ua"]), "#{label}: #{c["bot"] ? "is a bot" : "is a person"}"
      assert_equal c["client"], Ua.parse_client(c["ua"], c["hints"] || {}, c["screenWidth"]), label if c.key?("client")
    end
  end

  def test_client_hints_mark_a_mobile_chromium_as_mobile
    ua = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36"
    assert_equal "tablet", Ua.parse_client(ua)["device"]
    assert_equal "tablet", Ua.parse_client(ua, { "mobile" => "?1" })["device"], "an Android UA without Mobile still reads as a tablet"
    desktop = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36"
    assert_equal "mobile", Ua.parse_client(desktop, { "mobile" => "?1" })["device"]
  end

  def test_fixture
    cases = Fixtures.load("ua")["cases"]
    failures = []
    cases.each do |c|
      got = {
        "agent" => Ua.ai_agent(c["ua"]),
        "bot" => Ua.bot?(c["ua"]),
        "client" => Ua.parse_client(c["ua"], c["hints"] || {}, c["screenWidth"]),
      }
      want = { "agent" => c["agent"], "bot" => c["bot"], "client" => c["client"] }
      failures << "#{Fixtures.label(c)} gave #{Fixtures.label(got)}" if got != want
    end
    assert_operator cases.length, :>, 200
    assert_equal [], failures.first(20)
  end
end
