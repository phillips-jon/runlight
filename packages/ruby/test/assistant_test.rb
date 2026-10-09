# frozen_string_literal: true

require "test_helper"
require "openssl"
require_relative "support/mcp_api"

# The assistant against tests/fixtures/assistant.json: for each provider and failure, the very requests the
# TypeScript sends (bodies compared by SHA-256), the API reads its tools make, and what it answers.
class AssistantTest < Minitest::Test
  Assistant = Runlight::Assistant
  Json = Runlight::Json
  Response = Runlight::Http::Response

  CONTEXT = { "site" => { "id" => "default", "name" => "Blog", "timezone" => "UTC" }, "today" => "2026-10-08", "view" => "today", "language" => "en" }.freeze

  # An empty Hash written as an object, as the fixture writes it.
  def object(value)
    value == [] ? {} : value
  end

  def test_scenarios_send_the_same_requests_and_answer_the_same
    Fixtures.load("assistant")["scenarios"].each do |scenario|
      name = scenario["name"]
      queue = scenario["responses"].map do |c|
        c.key?("throws") ? c["throws"] : Response.new(c["body"], status: c["status"], headers: { "content-type" => "application/json" })
      end
      fetcher = RecordingFetcher.new(queue)
      tools = []
      begin
        result = if scenario["call"] == "chat"
                   Assistant.chat(scenario["settings"], scenario["messages"], scenario["context"], McpApi.read_api(tools), fetcher)
                 else
                   Assistant.list_models(scenario["settings"], fetcher)
                 end
        assert scenario.key?("result"), "#{name} answered #{Json.encode(result)}"
        assert_equal Json.encode(scenario["result"]), Json.encode(result), name
      rescue Runlight::AssistantError => e
        assert scenario.key?("error"), "#{name} threw #{e.message}"
        assert_equal scenario["error"]["message"], e.message, name
        assert_equal scenario["error"]["code"], e.code, name
        assert_equal Json.encode(object(scenario["error"]["params"])), Json.encode(e.params), name
      end
      assert_equal Json.encode(scenario["tools"]), Json.encode(tools), "#{name} read the API differently"
      assert_equal scenario["requests"].length, fetcher.requests.length, name
      scenario["requests"].each_with_index do |expected, i|
        sent = fetcher.requests[i]
        assert_equal expected["url"], sent["url"], "#{name} request #{i}"
        assert_equal expected["method"], sent["method"], "#{name} request #{i}"
        assert_equal Json.encode(object(expected["headers"])), Json.encode(sent["headers"]), "#{name} request #{i} headers"
        body = sent["body"].nil? ? nil : OpenSSL::Digest::SHA256.hexdigest(sent["body"])
        if expected["bodySha256"].nil?
          assert_nil body, "#{name} request #{i} body"
        else
          assert_equal expected["bodySha256"], body, "#{name} request #{i} body: #{sent["body"]}"
        end
      end
    end
  end

  def test_acknowledgements_match
    Fixtures.load("assistant")["acknowledgements"].each do |c|
      expected = c["reply"]
      actual = Assistant.acknowledgement(c["text"], c["language"])
      label = Json.encode([c["text"], c["language"]])
      expected.nil? ? assert_nil(actual, label) : assert_equal(expected, actual, label)
    end
  end

  def test_thanks_gets_a_short_reply_without_the_model_or_the_tools
    ["Thanks!", "thank you", "Thanks!! 🙏", "ok", "Great, thanks.", "👍", "merci beaucoup", "Danke schön!", "valeu"].each do |text|
      refute_nil Assistant.acknowledgement(text, "en"), text
    end
    ["Thanks, and what about last week?", "What was my bounce rate?", "ok so which pages?", "great results?"].each do |text|
      assert_nil Assistant.acknowledgement(text, "en"), text
    end
    assert_match(/plaisir/, Assistant.acknowledgement("merci", "fr").to_s)
  end

  def test_each_request_has_the_time_left_and_the_deadline_stops_the_rest
    clock = 1_000_000
    now = -> { clock }
    tool_use = lambda do |id|
      Response.new(Json.encode({ "stop_reason" => "tool_use", "content" => [{ "type" => "tool_use", "id" => id, "name" => "list_sites", "input" => {} }] }))
    end
    fetcher = RecordingFetcher.new([tool_use.call("a"), tool_use.call("b"), tool_use.call("c")])
    log = []
    read_api = McpApi.read_api(log)
    slow_api = lambda do |path, params|
      clock += 50_000
      read_api.call(path, params)
    end
    error = assert_raises(Runlight::AssistantError) do
      Assistant.chat({ "provider" => "anthropic", "model" => "m", "baseUrl" => "", "key" => "k" }, [{ "role" => "user", "content" => "All of it" }],
                     CONTEXT, slow_api, fetcher, now)
    end
    assert_equal "assistant_slow", error.code
    assert_equal [90_000, 70_000, 20_000], fetcher.requests.map { |r| r["timeoutMs"] }
    assert_equal 3, log.length
  end

  def test_a_cancelled_question_stops_before_its_next_request
    fetcher = RecordingFetcher.new([])
    error = assert_raises(Runlight::AssistantError) do
      Assistant.chat({ "provider" => "openai", "model" => "m", "baseUrl" => "", "key" => "k" }, [{ "role" => "user", "content" => "Hi?" }],
                     CONTEXT, McpApi.read_api([]), fetcher, nil, -> { true })
    end
    assert_equal "assistant_cancelled", error.code
    assert_equal "The question was cancelled.", error.message
    assert_equal [], fetcher.requests
  end

  def test_models_are_listed_within_twenty_seconds
    fetcher = RecordingFetcher.new([Response.new('{"data":[{"id":"b"},{"id":"a"}]}')])
    assert_equal [{ "id" => "a", "name" => "a" }, { "id" => "b", "name" => "b" }],
                 Assistant.list_models({ "provider" => "ollama", "baseUrl" => "", "key" => "" }, fetcher)
    assert_equal 20_000, fetcher.requests[0]["timeoutMs"]
    assert_equal "http://localhost:11434/v1/models", fetcher.requests[0]["url"]
  end
end
