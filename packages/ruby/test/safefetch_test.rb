# frozen_string_literal: true

require "test_helper"
require "socket"

# Ports safefetch.test.ts, replays the address checks in the outbound fixture, and covers each hop's checks.
class SafefetchTest < Minitest::Test
  Safefetch = Runlight::Safefetch
  Response = Runlight::Http::Response
  FetchError = Runlight::Http::FetchError
  PrivateAddressError = Runlight::PrivateAddressError

  # A DNS stand-in.
  def dns(names)
    ->(name) { names[name] || [] }
  end

  def test_only_addresses_on_the_public_internet_count_as_public
    ["93.184.215.14", "1.1.1.1", "2606:4700:4700::1111", "2a00:1450:4001:82a::200e"].each do |ip|
      assert Safefetch.public_address?(ip), ip
    end
    [
      "127.0.0.1", "10.0.0.1", "172.16.5.4", "192.168.1.1", "169.254.169.254", "100.64.0.1", "0.0.0.0", "224.0.0.1", "255.255.255.255",
      "::1", "::", "fe80::1", "fd00::1", "ff02::1", "::ffff:127.0.0.1", "::ffff:7f00:1", "::ffff:169.254.169.254", "64:ff9b::a00:1",
      "2002:a00:1::", "2001:db8::1", "2001:0:4136:e378::1", "[::1]", "not an address", "1.2.3", "1.2.3.256",
    ].each do |ip|
      refute Safefetch.public_address?(ip), ip
    end
  end

  def test_address_checks_match_type_script
    Fixtures.load("outbound")["ips"].each do |c|
      assert_equal c["public"], Safefetch.public_address?(c["ip"]), c["ip"]
    end
  end

  def test_a_public_fetch_never_reaches_the_installs_own_network_however_the_address_is_written
    # Something listening locally, which none of these may reach.
    inside = TCPServer.new("127.0.0.1", 0)
    port = inside.addr[1]
    begin
      ["http://127.0.0.1:#{port}/", "https://127.0.0.1:#{port}/", "https://[::1]:#{port}/", "https://[::ffff:127.0.0.1]:#{port}/",
       "https://localhost:#{port}/", "https://LOCALHOST.:#{port}/", "https://app.localhost:#{port}/"].each do |url|
        assert_raises(PrivateAddressError, "#{url} should be refused") { Safefetch.public_fetch(url, { "timeoutMs" => 2000 }) }
      end
      assert_nil inside.wait_readable(0), "nothing connected"
      assert Safefetch.resolves_privately?("localhost")
      refute Safefetch.resolves_privately?("name.that.does.not.resolve.invalid")
      assert_equal [], Safefetch.public_addresses("name.that.does.not.resolve.invalid")
      assert_equal ["8.8.8.8"], Safefetch.public_addresses("8.8.8.8")
      assert_equal [], Safefetch.public_addresses("localhost")
    ensure
      inside.close
    end
  end

  def test_the_checked_addresses_are_pinned
    fetcher = FakeFetcher.new { |_url, _init| Response.new("ok") }
    answer = Safefetch.public_fetch("https://Example.com/icon", {
                                      "timeoutMs" => 2000, "headers" => { "user-agent" => "Runlight" }, "maxBytes" => 10,
                                      "lookup" => dns({ "example.com" => ["93.184.215.14", "2606:4700::1111"] }),
                                    }, fetcher)
    assert_equal "ok", answer.text
    assert_equal ["example.com:443:93.184.215.14,[2606:4700::1111]"], fetcher.inits[0]["resolve"]
    assert_equal "manual", fetcher.inits[0]["redirect"]
    assert_equal 10, fetcher.inits[0]["maxBytes"]
    assert_equal({ "method" => "GET", "url" => "https://example.com/icon", "headers" => { "user-agent" => "Runlight" }, "body" => "" }, fetcher.requests[0])

    literal = FakeFetcher.new { |_url, _init| Response.new("ok") }
    Safefetch.public_fetch("https://93.184.215.14:8443/", { "timeoutMs" => 2000, "lookup" => dns({}) }, literal)
    refute literal.inits[0].key?("resolve"), "an address needs no pin"
  end

  def test_a_name_with_any_private_address_is_refused
    fetcher = FakeFetcher.new { |_url, _init| Response.new("ok") }
    { "inside.example" => ["10.0.0.5"], "mixed.example" => ["93.184.215.14", "169.254.169.254"], "mapped.example" => ["::ffff:127.0.0.1"] }.each do |name, addresses|
      error = assert_raises(PrivateAddressError, "#{name} should be refused") do
        Safefetch.public_fetch("https://#{name}/", { "timeoutMs" => 2000, "lookup" => dns({ name => addresses }) }, fetcher)
      end
      assert_equal "#{name} is not a public address", error.message
    end
    assert_equal [], fetcher.requests
    assert_raises(FetchError) { Safefetch.public_fetch("https://nowhere.example/", { "timeoutMs" => 2000, "lookup" => dns({}) }, fetcher) }
  end

  def test_redirects_are_followed_by_hand_under_the_same_rules
    lookup = dns({ "a.example" => ["93.184.215.14"], "b.example" => ["1.1.1.1"], "inside.example" => ["192.168.0.2"] })
    hops = ->(answers) { FakeFetcher.new { |_url, _init| answers.shift || Response.new("end") } }

    fetcher = hops.call([Response.redirect("/next", status: 301), Response.redirect("https://b.example/last", status: 302), Response.new("done")])
    answer = Safefetch.public_fetch("https://a.example/", { "timeoutMs" => 2000, "redirects" => 3, "lookup" => lookup }, fetcher)
    assert_equal "done", answer.text
    assert_equal ["https://a.example/", "https://a.example/next", "https://b.example/last"], fetcher.requests.map { |r| r["url"] }
    assert_equal ["b.example:443:1.1.1.1"], fetcher.inits[2]["resolve"]

    fetcher = hops.call([Response.redirect("https://b.example/", status: 302)])
    assert_equal 302, Safefetch.public_fetch("https://a.example/", { "timeoutMs" => 2000, "lookup" => lookup }, fetcher).status,
                 "a redirect past the last comes back as it is"

    { "https://10.0.0.1/" => "10.0.0.1", "https://inside.example/" => "inside.example", "http://b.example/" => "http://b.example/",
      "https://[fe80::1]/" => "fe80::1" }.each do |location, what|
      error = assert_raises(PrivateAddressError, "#{location} should be refused") do
        Safefetch.public_fetch("https://a.example/", { "timeoutMs" => 2000, "redirects" => 3, "lookup" => lookup }, hops.call([Response.redirect(location)]))
      end
      assert_equal "#{what} is not a public address", error.message
    end
  end

  def test_running_out_of_time_says_so
    fetcher = FakeFetcher.new { |_url, _init| raise FetchError.new("Operation timed out", timed_out: true) }
    error = assert_raises(FetchError, "should time out") do
      Safefetch.public_fetch("https://a.example/", { "timeoutMs" => 2000, "lookup" => dns({ "a.example" => ["1.1.1.1"] }) }, fetcher)
    end
    assert error.timed_out?
    assert_equal "The operation was aborted due to timeout", error.message
    refused = FakeFetcher.new { |_url, _init| raise FetchError, "Connection refused" }
    error = assert_raises(FetchError) do
      Safefetch.public_fetch("https://a.example/", { "timeoutMs" => 2000, "lookup" => dns({ "a.example" => ["1.1.1.1"] }) }, refused)
    end
    assert_equal "Connection refused", error.message
  end

  def test_another_install_is_only_fetched_at_a_public_https_address_with_no_redirect_followed
    ["https://example.com/runlight", "https://example.com"].each { |url| assert Safefetch.install_address?(url, false), url }
    ["http://127.0.0.1:4100/runlight", "http://localhost", "http://example.com", "ftp://example.com"].each { |url| refute Safefetch.install_address?(url, false), url }
    # Only code allows an install on this machine, and then only at these two names.
    ["http://127.0.0.1:4100/runlight", "http://localhost", "http://localhost:3000/runlight"].each { |url| assert Safefetch.install_address?(url, true), url }
    ["http://10.0.0.1", "http://localhost.example.com", "http://localhost@example.com", "http://127.0.0.1:80@example.com"].each do |url|
      refute Safefetch.install_address?(url, true), url
    end

    asked = []
    inside = FakeFetcher.new do |url, init|
      asked << [url, init["redirect"]]
      Response.new("", status: 302, headers: { "location" => "http://169.254.169.254/" })
    end
    ["http://127.0.0.1:4100/api/sites", "https://127.0.0.1:4100/api/sites", "https://localhost:4100/api/sites", "https://169.254.169.254/latest/meta-data/"].each do |url|
      assert_raises(PrivateAddressError, url) { Safefetch.owner_fetch(url, { "timeoutMs" => 2000 }, inside) }
    end
    assert_equal [], asked, "nothing on this machine was asked"
    # Allowed in code, a local install is asked, and its redirect is handed back, not followed.
    assert_equal 302, Safefetch.owner_fetch("http://127.0.0.1:4100/api/sites", { "timeoutMs" => 2000 }, inside, true).status
    assert_equal [["http://127.0.0.1:4100/api/sites", "manual"]], asked
  end
end
