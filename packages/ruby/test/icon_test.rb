# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

# A site's icon: the links picked as TypeScript picks them, and the fetches with their caps.
class IconTest < Minitest::Test
  Icon = Runlight::Icon
  Response = Runlight::Http::Response

  def setup
    @dir = Dir.mktmpdir("runlight-icon-test-")
    Icon.instance_variable_set(:@cache, {})
  end

  def teardown
    FileUtils.rm_rf(@dir)
    Icon.instance_variable_set(:@cache, {})
    super
  end

  def test_icon_links_match_type_script
    Fixtures.load("outbound")["icons"].each do |c|
      assert_equal c["links"], Icon.icon_links(c["html"], c["base"]), c["html"]
    end
  end

  def test_the_best_linked_icon_is_fetched_with_its_caps
    # An address as the origin, so no name is looked up.
    origin = "https://93.184.215.14"
    fetcher = FakeFetcher.new do |url, _init|
      case url
      when "https://93.184.215.14/"
        Response.new('<link rel="apple-touch-icon" href="/touch.png"><link rel="icon" href="/i.svg">',
                     headers: { "content-type" => "text/html; charset=utf-8" })
      when "https://93.184.215.14/touch.png" then Response.new("<html>", headers: { "content-type" => "text/html" })
      when "https://93.184.215.14/i.svg" then Response.new("<svg/>", headers: { "content-type" => "Image/SVG+xml; charset=utf-8" })
      else Response.new("", status: 404)
      end
    end
    now = 1_791_471_600_000
    icon = Icon.fetch_icon(origin, now, fetcher, @dir)
    assert_equal({ "body" => "<svg/>", "type" => "image/svg+xml" }, icon)
    assert_equal ["https://93.184.215.14/", "https://93.184.215.14/touch.png", "https://93.184.215.14/i.svg"], fetcher.requests.map { |r| r["url"] }
    assert_equal({ "maxBytes" => 200_000, "truncate" => true }, fetcher.inits[0].slice("maxBytes", "truncate"))
    assert_equal 262_144, fetcher.inits[1]["maxBytes"]
    refute fetcher.inits[1].key?("truncate"), "an image must arrive whole"
    assert_equal "Runlight (+https://runlight.sh)", fetcher.requests[0]["headers"]["user-agent"]
    assert_operator fetcher.inits[0]["timeoutMs"], :<=, 4000

    # Cached for a day, even across processes (here, with the process cache emptied).
    assert_equal icon, Icon.fetch_icon(origin, now + 86_399_000, fetcher, @dir)
    assert_equal 3, fetcher.requests.length
    Icon.instance_variable_set(:@cache, {})
    assert_equal icon, Icon.fetch_icon(origin, now + 86_399_000, fetcher, @dir)
    assert_equal 3, fetcher.requests.length
    Icon.fetch_icon(origin, now + 86_400_000, fetcher, @dir)
    assert_equal 6, fetcher.requests.length, "and looked up again after it"
  end

  def test_favicon_is_the_fallback_and_no_icon_is_remembered_for_an_hour
    origin = "https://1.1.1.1"
    answers = { "https://1.1.1.1/favicon.ico" => Response.new("", headers: { "content-type" => "image/x-icon" }) }
    fetcher = FakeFetcher.new { |url, _init| answers[url] || Response.new("nope", status: 500) }
    now = 1_791_471_600_000
    assert_nil Icon.fetch_icon(origin, now, fetcher, @dir), "an empty image is no icon"
    assert_equal ["https://1.1.1.1/", "https://1.1.1.1/favicon.ico"], fetcher.requests.map { |r| r["url"] }
    assert_nil Icon.fetch_icon(origin, now + 3_599_000, fetcher, @dir)
    assert_equal 2, fetcher.requests.length
    Icon.fetch_icon(origin, now + 3_600_000, fetcher, @dir)
    assert_equal 4, fetcher.requests.length
  end

  def test_a_private_origin_is_never_fetched
    fetcher = FakeFetcher.new { |_url, _init| Response.new("x", headers: { "content-type" => "image/png" }) }
    assert_nil Icon.fetch_icon("https://192.168.1.1", 0, fetcher, @dir)
    assert_equal [], fetcher.requests
  end
end
