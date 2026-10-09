# frozen_string_literal: true

require "test_helper"
require_relative "support/mcp_api"

# The MCP server against tests/fixtures/mcp.json: the TypeScript's API reads and answers for the same JSON-RPC
# messages and tool arguments, over canned API answers. The parts of mcp.test.ts that need no store are here too.
class McpTest < Minitest::Test
  Mcp = Runlight::Mcp
  Json = Runlight::Json

  def request(body)
    Runlight::Http::Request.new("https://x.com/mcp", method: "POST", body: body)
  end

  def test_tool_calls_read_the_same_api_and_answer_the_same
    Fixtures.load("mcp")["calls"].each do |c|
      label = Json.encode(c["params"])
      log = []
      begin
        result = Mcp.call_tool(c["params"], McpApi.read_api(log))
      rescue Runlight::McpError => e
        assert c.key?("throws"), "#{label} threw #{e.message}"
        assert_equal c["message"], e.message, label
        next
      end
      refute c.key?("throws"), "#{label} should throw"
      assert_equal Json.encode(c["requests"]), Json.encode(log), label
      assert_equal Json.encode(c["value"]), Json.encode(result), label
    end
  end

  def test_json_rpc_answers_match
    Fixtures.load("mcp")["rpcs"].each do |c|
      body = c.key?("bodyHex") ? [c["bodyHex"]].pack("H*") : c["body"]
      log = []
      req = Runlight::Http::Request.new("https://example.com/runlight/mcp", method: "POST", body: body)
      if c.key?("throws")
        assert_raises(TypeError, body) { Mcp.mcp_response(req, McpApi.read_api(log)) }
        next
      end
      answer = Mcp.mcp_response(req, McpApi.read_api(log))
      assert_equal c["status"], answer.status, body
      headers = {}
      answer.headers.each { |name, value| headers[name] = value }
      assert_equal c["headers"], headers, body
      assert_equal c["text"], answer.text, body
      assert_equal Json.encode(c["requests"]), Json.encode(log), body
    end
  end

  def test_tools_are_listed_read_only_in_order
    answer = Mcp.mcp_response(request('{"jsonrpc":"2.0","id":1,"method":"tools/list"}'), McpApi.read_api([]))
    tools = Json.decode(answer.text)["result"]["tools"]
    assert_equal Fixtures.load("mcp")["tools"], tools.map { |t| t["name"] }
    tools.each { |tool| assert_equal true, tool["annotations"]["readOnlyHint"] }
    assert_includes answer.text, '"properties":{}', "an empty schema is an object"
  end

  def test_initialize_answers_the_asked_version_or_the_newest
    ask = lambda do |version|
      body = Json.encode({ "jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => { "protocolVersion" => version } })
      Json.decode(Mcp.mcp_response(request(body), McpApi.read_api([])).text)["result"]
    end
    assert_equal "2025-06-18", ask.call("2025-06-18")["protocolVersion"]
    assert_equal "runlight", ask.call("2025-06-18")["serverInfo"]["name"]
    assert_equal "2025-11-25", ask.call("1999-01-01")["protocolVersion"], "an unknown version gets the newest"
    note = Mcp.mcp_response(request('{"jsonrpc":"2.0","method":"notifications/initialized"}'), McpApi.read_api([]))
    assert_equal 202, note.status
    assert_equal "", note.text
  end
end
