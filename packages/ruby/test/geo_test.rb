# frozen_string_literal: true

require "test_helper"
require "tempfile"

# Location from platform headers and MMDB files, replayed from the TypeScript SDK and server.
class GeoTest < Minitest::Test
  Geo = Runlight::Geo
  Mmdb = Runlight::Mmdb
  Headers = Runlight::Http::Headers
  Json = Runlight::Json

  def test_headers
    Fixtures.load("geo")["headers"].each do |c|
      assert_equal Json.encode(c["location"]), Json.encode(Geo.location_from_headers(Headers.new(c["headers"]))), Fixtures.label(c["headers"])
    end
  end

  def test_locate
    Fixtures.load("geo")["located"].each do |c|
      lookup = if c["noLookup"]
                 nil
               else
                 lambda do |_ip|
                   raise "broken" if c["throws"]

                   c["found"]
                 end
               end
      assert_equal Json.encode(c["location"]), Json.encode(Geo.locate(Headers.new(c["headers"]), c["ip"], lookup)), Fixtures.label(c)
    end
  end

  def test_mmdb
    Fixtures.load("geo")["databases"].each do |db|
      reader = Mmdb.new(db["base64"].unpack1("m"))
      assert_equal db["ipVersion"], reader.metadata["ip_version"]
      assert_equal db["recordSize"], reader.metadata["record_size"]
      assert_equal 1_759_708_800, reader.metadata["build_epoch"]
      assert_equal({ "en" => "A test database" }, reader.metadata["description"])
      lookup = Geo.lookup_from(reader)
      db["records"].each do |c|
        label = "#{db["ipVersion"]}/#{db["recordSize"]} #{c["ip"]}"
        assert_equal Json.encode(c["record"]), Json.encode(reader.get(c["ip"])), label
        assert_equal Json.encode(c["location"]), Json.encode(lookup.call(c["ip"])), label
      end
    end
  end

  def test_a_file_is_read_a_page_at_a_time_with_the_same_answers
    Fixtures.load("geo")["databases"].each do |db|
      Tempfile.create("rl-mmdb") do |file|
        file.binmode
        file.write(db["base64"].unpack1("m"))
        file.flush
        reader = Mmdb.open(file.path)
        assert_equal db["ipVersion"], reader.metadata["ip_version"]
        db["records"].each do |c|
          assert_equal Json.encode(c["record"]), Json.encode(reader.get(c["ip"])), "#{db["ipVersion"]}/#{db["recordSize"]} #{c["ip"]}"
        end
      end
    end
    assert_raises(RuntimeError) { Mmdb.open(File.join(Dir.tmpdir, "no-such-runlight.mmdb")) }
  end

  # A stand-in reader answering from a Hash, or raising.
  class Reader
    def initialize(records = nil)
      @records = records
    end

    def get(ip)
      raise "bad address" if @records.nil?

      @records[ip]
    end
  end

  def test_db_ip_records_become_a_country_code_a_readable_region_and_a_plain_city
    records = {
      "24.114.0.1" => { "country" => { "iso_code" => "CA" }, "subdivisions" => [{ "names" => { "en" => "Ontario" } }],
                        "city" => { "names" => { "en" => "Toronto (Old Toronto)" } } },
      "8.8.8.8" => { "country" => { "iso_code" => "US" }, "subdivisions" => [{ "iso_code" => "CA", "names" => { "en" => "California" } }],
                     "city" => { "names" => { "en" => "Mountain View" } } },
      "10.0.0.1" => nil,
    }
    lookup = Geo.lookup_from(Reader.new(records))
    assert_equal({ "country" => "CA", "region" => "Ontario", "city" => "Toronto" }, lookup.call("24.114.0.1"))
    assert_equal({ "country" => "US", "region" => "CA", "city" => "Mountain View" }, lookup.call("8.8.8.8"), "a code wins when the database has one")
    assert_nil lookup.call("10.0.0.1")
    broken = Geo.lookup_from(Reader.new)
    assert_nil broken.call("nonsense")
  end

  def test_a_real_database_when_one_is_given
    file = ENV.fetch("RUNLIGHT_TEST_MMDB", "")
    skip "Set RUNLIGHT_TEST_MMDB to an MMDB file to read a real database." if file.empty?

    reader = Mmdb.open(file)
    refute_nil reader.get("8.8.8.8")
    assert_nil reader.get("127.0.0.1")
  end
end
