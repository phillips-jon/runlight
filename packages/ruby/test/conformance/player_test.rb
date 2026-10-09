# frozen_string_literal: true

require "test_helper"
require "openssl"
require_relative "player"
require_relative "answers"
require_relative "fake/replay_target"
require_relative "fake/scripted_target"

# The runner itself, proved before the Ruby core exists.
class ConformancePlayerTest < Minitest::Test
  KEY = "rl_ABCDEFGHJKMNPQRSTVWXYZ12"
  HEX24 = "0123456789abcdef01234567"
  HEX32 = "0123456789abcdef0123456789abcdef"
  SECRET = "JBSWY3DPEHPK3PXP"
  START = 1_700_000_000_000

  Player = Conformance::Player
  Normalizer = Conformance::Normalizer
  Response = Runlight::Http::Response
  Json = Runlight::Json

  def test_the_format_is_the_one_this_runner_reads
    assert_equal Player::FORMAT_SHA256, OpenSSL::Digest::SHA256.hexdigest(Conformance::Scenarios.file["description"]),
                 "conformance/http.json describes its format differently now. Read the change, port it to Player, " \
                 "then update FORMAT_SHA256."
  end

  # A fake that answers every step with the expected answer, its placeholders filled with fresh values, must
  # come out of the runner as exactly the expected answers again.
  Conformance::Scenarios.all.each do |scenario|
    define_method("test_replays_through_a_fake: #{scenario["name"]}") do
      fake = nil
      saved = set_env
      begin
        answers = Player.new.play(scenario, lambda { |runlight, routes|
          fake = Conformance::Fake::ReplayTarget.new(scenario, runlight, routes)
        }, "a store")
        assert_env_restored
      ensure
        Player.restore_env(saved)
      end
      Conformance::Answers.assert_answers(self, scenario, answers)
      assert_equal scenario["steps"].length, fake.idled, "idle runs after every step"
      assert_equal "a store", fake.runlight_options["store"]
    end
  end

  def test_maps_the_scenario_options
    scenario = Json.decode('{"site":{"hostnames":["a.com"],"timezone":"UTC"},"token":null,"options":{"secret":"s",' \
                           '"rateLimit":false,"accounts":true,"origin":"https://o.example","observeKey":"k","cronSecret":"c"}}')
    assert_equal({ "site" => { "hostnames" => ["a.com"], "timezone" => "UTC" }, "secret" => "s", "rateLimit" => false },
                 Player.runlight_options(scenario))
    assert_equal({ "token" => nil, "observeKey" => "k", "cronSecret" => "c", "accounts" => true, "origin" => "https://o.example" },
                 Player.routes_options(scenario))

    scenario = Json.decode('{"site":{"hostnames":[],"timezone":"UTC"},"sites":[{"id":"a","hostnames":["a.com"],' \
                           '"timezone":"Europe/Paris","name":"A"}],"token":""}')
    assert_equal({ "sites" => [{ "id" => "a", "hostnames" => ["a.com"], "timezone" => "Europe/Paris", "name" => "A" }] },
                 Player.runlight_options(scenario))
    assert_equal({ "token" => "", "observeKey" => "", "cronSecret" => "" }, Player.routes_options(scenario))

    scenario = Json.decode('{"site":{"hostnames":[],"timezone":"UTC"},"sites":[],"token":"t","options":{"managedSites":true,"rateLimit":4}}')
    assert_equal({ "managedSites" => true, "rateLimit" => 4 }, Player.runlight_options(scenario))
  end

  def test_sends_and_keeps_what_the_type_script_runner_does
    scenario = Json.decode(<<~'JSON')
      {
        "name": "the runner",
        "site": {"hostnames": ["example.com"], "timezone": "UTC"},
        "start": 1700000000000,
        "token": "t",
        "upstream": [
          {"url": "https://api.example.com/json", "method": "POST", "body": {"ok": true}},
          {"url": "https://api.example.com/", "status": 201, "body": "plain", "headers": {"x-up": "1"}}
        ],
        "steps": [
          {"method": "POST", "path": "/login", "form": {"email": "a b@x.com", "next": "/runlight/?a=1&b=2"},
           "capture": {"tok": "token", "id": "nested.list.0.id", "etag": "header:etag", "code": "header:location~code=([a-f0-9]+)",
             "cookies": "header:set-cookie", "sec": "secret", "raw": "text~\"id\":\"(\\w+)\"", "missing": "nested.nothing.deep",
             "count": "nested.count", "flag": "nested.flag", "arr": "nested.arr", "obj": "nested", "nomatch": "text~(zzz)"}},
          {"advance": 30000, "method": "put", "path": "/x/{{id}}?c={{code}}",
           "headers": {"Authorization": "Bearer {{tok}}", "X-Otp": "{{totp:sec}}", "X-All": "{{missing}}|{{count}}|{{flag}}|{{arr}}|{{obj}}|{{unknown}}|{{nomatch}}|{{raw}}"},
           "body": {"a": "{{etag}}", "n": 1.5, "o": {}, "l": [], "t": "{{totp:sec}}"}},
          {"method": "GET", "path": "/go/x", "to": "links", "host": "s.example.com", "jar": "other"},
          {"method": "GET", "path": "/.well-known/x", "absolute": true, "jar": false, "capture": {"unsub": "fetched~/unsubscribe/([a-f0-9]{32})"}},
          {"method": "GET", "path": "/r/{{unsub}}", "to": "linkDomain", "headers": {"Cookie": "mine=1"}},
          {"method": "POST", "path": "/raw", "body": "{{tok}} as text", "headers": {"content-type": "text/csv"}, "look": ["a,b", "zzz"]},
          {"method": "GET", "path": "/export"},
          {"method": "GET", "path": "/null"}
        ]
      }
    JSON
    fetcher = nil
    now = nil
    script = [
      lambda do |r, _to|
        assert_equal "https://example.com/runlight/login", r.url
        assert_equal "POST", r.method
        assert_equal "email=a+b%40x.com&next=%2Frunlight%2F%3Fa%3D1%26b%3D2", r.text
        assert_equal "application/x-www-form-urlencoded", r.headers.get("content-type")
        assert_nil r.headers.get("cookie")
        assert_equal START, now.call
        Player::ENV_NAMES.each { |name| assert_nil Runlight::Env.get(name), "#{name} is cleared" }
        Response.new(
          Json.encode({ "token" => KEY, "secret" => SECRET, "id" => HEX24,
                        "nested" => { "list" => [{ "id" => "x1" }], "count" => 3, "flag" => true, "arr" => [1, nil, "b"] } }),
          status: 200,
          headers: {
            "content-type" => "application/json; charset=utf-8",
            "etag" => 'W/"1"',
            "location" => "/cb?code=deadbeef&state=#{HEX32}",
            "set-cookie" => ["sid=abc; Path=/; HttpOnly", "old=; Max-Age=0", "keep=k1"],
            "cache-control" => "no-store",
            "x-other" => "not compared",
          },
        )
      end,
      lambda do |r, _to|
        assert_equal "https://example.com/runlight/x/x1?c=deadbeef", r.url
        assert_equal "PUT", r.method
        assert_equal START + 30_000, now.call
        code = Player.totp(SECRET, (START + 30_000) / 30_000)
        assert_equal "Bearer #{KEY}", r.headers.get("authorization")
        assert_equal code, r.headers.get("x-otp")
        assert_equal "|3|true|1,,b|[object Object]|||#{HEX24}", r.headers.get("x-all")
        assert_equal "sid=abc; keep=k1", r.headers.get("cookie")
        assert_equal Player::TEXT_BODY_TYPE, r.headers.get("content-type")
        assert_equal "{\"a\":\"W/\\\"1\\\"\",\"n\":1.5,\"o\":{},\"l\":[],\"t\":\"#{code}\"}", r.text

        json = fetcher.fetch("https://api.example.com/json", { "method" => "post", "headers" => { "Content-Type" => "application/json", "X-B" => "2", "a-first" => "1" }, "body" => "{\"q\":\"#{KEY}\"}" })
        assert_equal [200, "application/json", '{"ok":true}'], [json.status, json.headers.get("content-type"), json.text]
        plain = fetcher.fetch("https://api.example.com/json")
        assert_equal [201, nil, "1", "plain"], [plain.status, plain.headers.get("content-type"), plain.headers.get("x-up"), plain.text]
        error = assert_raises(Runlight::Http::FetchError) { fetcher.fetch("https://nowhere.example/", { "method" => "DELETE" }) }
        assert_equal "fetch failed", error.message
        Response.new("", status: 204, headers: { "set-cookie" => "sid=gone; Max-Age=0" })
      end,
      lambda do |r, to|
        assert_equal "links", to
        assert_equal "https://s.example.com/go/x", r.url
        assert_nil r.headers.get("cookie")
        Response.new("", status: 302, headers: { "location" => "https://shop.example.com/?ref=#{KEY}", "set-cookie" => "o=1" })
      end,
      lambda do |r, _to|
        assert_equal "https://example.com/.well-known/x", r.url
        assert_nil r.headers.get("cookie")
        fetcher.fetch("https://api.example.com/mail", { "method" => "POST", "headers" => { "content-type" => "application/json" }, "body" => "{\"link\":\"https://stats.example.com/unsubscribe/#{HEX32}\"}" })
        fetcher.fetch("https://api.example.com/form", { "method" => "POST", "headers" => { "content-type" => "application/x-www-form-urlencoded" }, "body" => "a=1&b=x+y&a=2" })
        Response.new("<p>hi</p>", status: 200, headers: { "content-type" => "text/html" })
      end,
      lambda do |r, to|
        assert_equal "linkDomain", to
        assert_equal "https://example.com/r/#{HEX32}", r.url
        assert_equal "mine=1", r.headers.get("cookie")
        nil
      end,
      lambda do |r, _to|
        assert_equal "#{KEY} as text", r.text
        assert_equal "text/csv", r.headers.get("content-type")
        assert_equal "keep=k1", r.headers.get("cookie")
        Response.new("a,b\n1,#{KEY}", status: 200, headers: { "content-type" => "text/csv; charset=utf-8" })
      end,
      lambda do |_r, _to|
        Response.new(Conformance::Zip.zip([{ "name" => "a.csv", "text" => "x,#{HEX32}" }, { "name" => "b.txt", "text" => "\u{FEFF}plain" }]),
                     status: 200, headers: { "content-type" => "application/zip", "content-disposition" => 'attachment; filename="export.zip"' })
      end,
      ->(_r, _to) { Response.new("null", status: 200) },
    ]
    target = Conformance::Fake::ScriptedTarget.new(script)
    answers = Player.new.play(scenario, lambda { |runlight, _routes|
      fetcher = runlight["fetcher"]
      now = runlight["now"]
      target
    })

    expected = Json.decode(<<~'JSON')
      [
        {"status": 200, "headers": {"content-type": "application/json", "cache-control": "no-store", "location": "/cb?code=<value>&state=<hex>",
          "set-cookie": ["sid=<value>; Path=/; HttpOnly", "old=; Max-Age=0", "keep=<value>"]},
         "body": {"token": "<token>", "secret": "<secret>", "id": "<id>", "nested": {"list": [{"id": "x1"}], "count": 3, "flag": true, "arr": [1, null, "b"]}}},
        {"status": 204, "headers": {"set-cookie": ["sid=<value>; Max-Age=0"]}, "fetched": [
          {"method": "POST", "url": "https://api.example.com/json", "headers": {"a-first": "1", "content-type": "application/json", "x-b": "2"}, "body": {"q": "<q>"}},
          {"method": "GET", "url": "https://api.example.com/json"},
          {"method": "DELETE", "url": "https://nowhere.example/"}
        ]},
        {"status": 302, "headers": {"location": "https://shop.example.com/?ref=<key>", "set-cookie": ["o=<value>"]}},
        {"status": 200, "headers": {"content-type": "text/html"}, "fetched": [
          {"method": "POST", "url": "https://api.example.com/mail", "headers": {"content-type": "application/json"}, "body": {"link": "https://stats.example.com/unsubscribe/<hex>"}},
          {"method": "POST", "url": "https://api.example.com/form", "headers": {"content-type": "application/x-www-form-urlencoded"}, "body": {"a": "2", "b": "x y"}}
        ]},
        {"pass": true},
        {"status": 200, "headers": {"content-type": "text/csv"}, "text": "a,b\n1,<key>", "found": [true, false]},
        {"status": 200, "headers": {"content-type": "application/zip", "content-disposition": "attachment; filename=\"export.zip\""},
         "files": [{"name": "a.csv", "text": "x,<hex>"}, {"name": "b.txt", "text": "plain"}]},
        {"status": 200, "body": null}
      ]
    JSON
    assert_equal Normalizer.canonical(expected), Normalizer.canonical(answers)
    assert_equal 8, target.idled
  end

  def test_names_the_step_that_threw
    scenario = Json.decode('{"name":"broken","site":{"hostnames":[],"timezone":"UTC"},"start":0,"token":"",' \
                           '"steps":[{"method":"GET","path":"/a"},{"method":"POST","path":"/b"}]}')
    target = Conformance::Fake::ScriptedTarget.new([->(_r, _to) { Response.new("", status: 200) }, ->(_r, _to) { raise ArgumentError, "boom" }])
    error = assert_raises(RuntimeError) { Player.new.play(scenario, ->(_rl, _routes) { target }) }
    assert_equal "broken: step 2, POST /b: boom", error.message
  end

  def test_keeps_going_past_a_step_that_threw_when_asked
    scenario = Json.decode('{"name":"broken","site":{"hostnames":[],"timezone":"UTC"},"start":0,"token":"",' \
                           '"steps":[{"method":"GET","path":"/a"},{"method":"POST","path":"/b"},{"method":"GET","path":"/c"}]}')
    target = Conformance::Fake::ScriptedTarget.new([->(_r, _to) { raise ArgumentError, "boom" }, ->(_r, _to) { Response.new("", status: 201) },
                                                    ->(_r, _to) { Response.new("", status: 202) }])
    answers = Player.new.play(scenario, ->(_rl, _routes) { target }, keep_going: true)
    assert_match(/\AArgumentError: boom/, answers[0]["raised"])
    assert_equal [{ "status" => 201 }, { "status" => 202 }], answers[1..]
  end

  def test_upstream_answers
    fetcher = Conformance::UpstreamFetcher.new(Json.decode('[{"url":"https://a.example/null","body":null},' \
                                                           '{"url":"https://a.example/list","body":[1],"headers":{"Content-Type":"text/plain"}},' \
                                                           '{"url":"https://a.example/big","body":"0123456789"},{"url":"https://a.example/empty","method":""}]'))
    null = fetcher.fetch("https://a.example/null")
    assert_equal ["application/json", "null"], [null.headers.get("content-type"), null.text]
    # Spread over {"content-type": ...}, a differently spelled name is a second value, as new Headers() makes it.
    assert_equal "application/json, text/plain", fetcher.fetch("https://a.example/list").headers.get("content-type")
    assert_equal "01234", fetcher.fetch("https://a.example/big", { "maxBytes" => 5, "truncate" => true }).text
    assert_raises(Runlight::Http::BodyTooLong) { fetcher.fetch("https://a.example/big", { "maxBytes" => 5 }) }
    empty = fetcher.fetch("https://a.example/empty", { "method" => "PATCH" })
    assert_equal [200, "", nil], [empty.status, empty.text, empty.headers.get("content-type")]
    assert_equal 5, fetcher.take.length
    assert_equal [], fetcher.take
  end

  def test_capture_helpers
    parsed = Json.decode('{"a":{"b":[{"c":"x"},0,""]},"n":1.0,"f":0.5,"big":1e21}')
    assert_equal "x", Player.js_string(Player.dig(parsed, "a.b.0.c"))
    assert_equal "0", Player.js_string(Player.dig(parsed, "a.b.1"))
    assert_equal "", Player.js_string(Player.dig(parsed, "a.b.1.c"))
    assert_equal "", Player.js_string(Player.dig(parsed, "a.b.01"))
    assert_equal "1", Player.js_string(Player.dig(parsed, "n"))
    assert_equal "0.5", Player.js_string(Player.dig(parsed, "f"))
    assert_equal "1e+21", Player.js_string(Player.dig(parsed, "big"))
    assert_equal "[object Object],0,", Player.js_string(Player.dig(parsed, "a.b"))
    assert_equal "", Player.js_string(Player.dig(nil, "a"))
    assert_equal "abc", Player.first_group("state=([a-f0-9]+)", "x?state=abc&y")
    assert_equal "", Player.first_group("state=([a-f0-9]+)", "nothing")
    assert_equal "", Player.first_group("(x)?y", "y")
    assert_equal "/assets/app.1f.css", Player.first_group('href="/runlight(/assets/app\\.[a-f0-9]+\\.css)"', '<link href="/runlight/assets/app.1f.css">')
  end

  # RFC 6238's SHA-1 test vectors (the 20-byte key "12345678901234567890" in base32), cut to six digits.
  def test_totp
    secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    assert_equal "287082", Player.totp(secret, 59 / 30)
    assert_equal "081804", Player.totp(secret, 1_111_111_109 / 30)
    assert_equal "005924", Player.totp(secret, 1_234_567_890 / 30)
    assert_equal Player.totp(secret, 1), Player.totp("gezd gnbv gy3t qojq gezd gnbv gy3t qojq====", 1)
  end

  def test_zip_round_trip
    files = [{ "name" => "a.txt", "text" => "héllo" }, { "name" => "b/c.csv", "text" => "" }]
    assert_equal files, Conformance::Zip.unzip(Conformance::Zip.zip(files))
    assert_equal files, Conformance::Zip.unzip(Conformance::Zip.zip(files, deflate: false))
  end

  def test_describes_the_first_difference
    expected = Json.decode('{"status":200,"body":{"a":[1,2,3],"b":"x"}}')
    assert_equal "status: expected 200, got 404", Conformance::Answers.describe(expected, Json.decode('{"status":404,"body":{}}'))
    assert_equal "body.a.1: expected 2, got 5", Conformance::Answers.describe(expected, Json.decode('{"status":200,"body":{"a":[1,5,3],"b":"y"}}'))
    assert_equal "body.a: expected 3 items, got 2 items (first missing: 3)", Conformance::Answers.describe(expected, Json.decode('{"status":200,"body":{"a":[1,2],"b":"x"}}'))
    assert_equal "body.b: expected \"x\", got (absent)", Conformance::Answers.describe(expected, Json.decode('{"status":200,"body":{"a":[1,2,3]}}'))
    assert_equal "raised NoMethodError: x", Conformance::Answers.describe(expected, { "raised" => "NoMethodError: x" })
  end

  private

  # Sets every variable the runner clears, returning what was there before, to put back.
  def set_env
    saved = Player.clear_env
    Player::ENV_NAMES.each { |name| ENV[name] = "from-outside" }
    saved
  end

  def assert_env_restored
    Player::ENV_NAMES.each { |name| assert_equal "from-outside", ENV.fetch(name, nil), "#{name} is put back" }
  end
end
