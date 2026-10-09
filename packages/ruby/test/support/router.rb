# frozen_string_literal: true

# A fetcher that answers from a table of URL patterns, recording what was asked, as the TS tests' serve()
# replaces globalThis.fetch. Each answer is a body to send as JSON, or [status, body].
class Router
  # "METHOD host/path" of each request.
  attr_reader :calls
  # { "url", "init" } of each request.
  attr_reader :requests

  # routes: [[pattern, ->(url, init) { answer }], ...]
  def initialize(routes)
    @routes = routes
    @calls = []
    @requests = []
  end

  def fetch(url, init = {})
    u = Runlight::Http::Url.new(url)
    @calls << "#{init["method"] || "GET"} #{u.host}#{u.pathname}"
    @requests << { "url" => url, "init" => init }
    @routes.each do |pattern, answer|
      next unless u.href.match?(pattern)

      result = answer.call(u, init)
      status, body = result.is_a?(Array) && result.length == 2 && result[0].is_a?(Integer) ? result : [200, result]
      return Runlight::Http::Response.new(Runlight::Json.encode(body), status: status, headers: { "content-type" => "application/json" })
    end
    Runlight::Http::Response.new("{}", status: 404)
  end

  # The authorization header a request carried.
  def self.authorization(init)
    Runlight::Http::Headers.new(init["headers"] || {}).get("authorization")
  end
end
