# frozen_string_literal: true

require "test_helper"
require "webrick"

# Capped reads: Body's checks, and the fetcher's maxBytes, truncate, and resolve against a real server.
class BodyTest < Minitest::Test
  Body = Runlight::Body
  Response = Runlight::Http::Response
  BodyTooLong = Runlight::Http::BodyTooLong

  # A server on a port of its own: /bytes?n=... answers n bytes of "a", in chunks; /endless answers until the
  # client goes (or 64 MB, whichever is first); anything else names the Host it was asked for.
  def self.port
    @port ||= begin
      server = WEBrick::HTTPServer.new(BindAddress: "127.0.0.1", Port: 0, Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
      server.mount_proc("/") do |request, response|
        if request.path == "/bytes" || request.path == "/endless"
          n = request.path == "/endless" ? 64 << 20 : request.query["n"].to_i
          response["content-type"] = "text/html"
          response.chunked = true
          response.body = proc do |out|
            while n.positive?
              part = [n, 8192].min
              out.write("a" * part)
              n -= part
            end
          end
        else
          response["content-type"] = "text/plain"
          response.body = "host #{request["host"]}"
        end
      end
      Thread.new { server.start }
      Minitest.after_run { server.shutdown }
      server.config[:Port]
    end
  end

  def test_text_is_read_up_to_the_cap
    assert_equal "hello", Body.read_text_capped(Response.new("hello"), 5)
    assert_equal({ "a" => 1 }, Body.read_json_capped(Response.new('{"a":1}'), 100))
    assert_equal "a\u{FFFD}b", Body.read_text_capped(Response.new("a\xffb".b), 10), "as TextDecoder reads bytes that are not UTF-8"
    assert_equal "x", Body.read_text_capped(Response.new("\xEF\xBB\xBFx".b), 10)
    error = assert_raises(BodyTooLong) { Body.read_text_capped(Response.new("hello"), 4) }
    assert_equal "Body over 4 bytes", error.message
  end

  def test_a_declared_length_over_the_cap_is_refused_unread
    assert_raises(BodyTooLong) { Body.read_text_capped(Response.new("", headers: { "content-length" => "1000" }), 10) }
  end

  def test_the_fetcher_stops_reading_past_max_bytes
    fetcher = Runlight::Http::NetFetcher.new
    url = "http://127.0.0.1:#{self.class.port}/bytes?n=300000"
    assert_equal 300_000, fetcher.fetch(url, { "maxBytes" => 300_000 }).text.bytesize
    error = assert_raises(BodyTooLong, "a body past maxBytes is refused") { fetcher.fetch(url, { "maxBytes" => 100_000 }) }
    assert_equal "Body over 100000 bytes", error.message
    start = fetcher.fetch(url, { "maxBytes" => 100_000, "truncate" => true })
    assert_equal 200, start.status
    assert_equal "a" * 100_000, start.text, "with truncate, the start comes back"
    assert_equal "text/html", start.headers.get("content-type").to_s.split(";").first
  end

  def test_the_fetcher_stops_at_once_on_a_body_without_end
    url = "http://127.0.0.1:#{self.class.port}/endless"
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    start = Runlight::Http::NetFetcher.new.fetch(url, { "maxBytes" => 10_000, "truncate" => true, "timeoutMs" => 20_000 })
    assert_equal "a" * 10_000, start.text
    assert_raises(BodyTooLong) { Runlight::Http::NetFetcher.new.fetch(url, { "maxBytes" => 10_000, "timeoutMs" => 20_000 }) }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5, "nothing past the cap is read"
  end

  def test_the_fetcher_connects_to_the_pinned_address
    port = self.class.port
    answer = Runlight::Http::NetFetcher.new.fetch("http://pinned.invalid:#{port}/", { "resolve" => ["pinned.invalid:#{port}:127.0.0.1"] })
    assert_equal "host pinned.invalid:#{port}", answer.text
  end
end
