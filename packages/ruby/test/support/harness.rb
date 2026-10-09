# frozen_string_literal: true

# A Runlight on a fresh database with a clock the test moves, as helpers.ts's setup() is. Tracker hits go
# straight to collect(), and reports are read from the store, so nothing here needs the routes.
class Harness
  CHROME_MAC = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36"
  SAFARI_IPHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
  DAY = 86_400_000
  HOUR = 3_600_000
  MIN = 60_000
  # Date.UTC(2026, 9, 6, 12), where the TS tests start the clock.
  START = 1_791_288_000_000

  attr_reader :rl
  attr_accessor :now

  # kind: a database kind from Databases.kinds, or a store.
  def initialize(kind, options = {})
    store = kind.is_a?(Runlight::Store::SqlStore) ? kind : Databases.fresh(kind)
    @now = START
    @rl = Runlight::Core.new({ "store" => store, "now" => -> { @now } }.merge(options))
  end

  def store
    @rl.store
  end

  def advance(ms)
    @now += ms
  end

  # A tracker hit, as the routes pass it to collect(). init: "ua", "ip", and "headers".
  def track(body, init = {})
    @rl.collect(Harness.hit("https://example.com/runlight/e", body, init))
  end

  def self.hit(url, body, init = {})
    headers = { "user-agent" => init["ua"] || CHROME_MAC, "x-forwarded-for" => init["ip"] || "203.0.113.1",
                "content-type" => "text/plain;charset=UTF-8" }.merge(init["headers"] || {})
    Runlight::Http::Request.new(url, method: "POST", headers: headers, body: Runlight::Json.encode(body))
  end

  # A query over local dates of a site, as the dashboard's from and to make one.
  def query(from, to, site = nil, filters = [])
    row = @rl.site(site)
    tz = row["timezone"]
    { "site" => row["id"], "from" => Runlight::Dates.start_of(from, tz),
      "to" => Runlight::Dates.start_of(Runlight::Dates.add_days(to, 1), tz), "filters" => filters }
  end

  # Today in the site's timezone, as period=today.
  def today(site = nil, filters = [])
    @rl.init
    day = Runlight::Dates.local_date(@now, @rl.site(site)["timezone"])
    query(day, day, site, filters)
  end

  # Everything, as period=all reads it, wide enough for any test.
  def all(site = nil)
    @rl.init
    { "site" => @rl.site(site)["id"], "from" => 0, "to" => @now + DAY, "filters" => [] }
  end

  def stats(query)
    store.stats(query)
  end

  # One field of each breakdown row.
  def values(query, dimension, field = "value", limit = 10)
    store.breakdown(query, dimension, limit, 0).map { |r| r[field] }
  end

  def count(sql, params = [])
    store.db.all(sql, params)[0]["n"].to_i
  end
end
