# frozen_string_literal: true

# The canned HTTP API of tests/fixtures/mcp.json, as the MCP and assistant tests read it.
module McpApi
  # A read_api that logs each read into `log` and answers from the fixture's canned API.
  def self.read_api(log)
    api = Fixtures.load("mcp")["api"]
    lambda do |path, params|
      log << { "path" => path, "params" => params }
      canned = api[path] || { "status" => 404, "body" => "{\"error\":\"Not found: #{path.delete('"')}\"}" }
      Runlight::Http::Response.new(canned["body"], status: canned["status"], headers: { "content-type" => "application/json" })
    end
  end
end
