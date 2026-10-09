# frozen_string_literal: true

require "test_helper"

# CSV and ZIP output, byte for byte as the TypeScript SDK writes them.
class ZipTest < Minitest::Test
  Zip = Runlight::Zip

  # A cell back from its fixture form: {"js": "NaN"} and the like become the values JSON cannot carry.
  def cell(value)
    if value.is_a?(Hash) && value.keys == ["js"]
      return {
        "undefined" => Runlight::UNDEFINED, "NaN" => Float::NAN, "Infinity" => Float::INFINITY,
        "-Infinity" => -Float::INFINITY, "-0" => -0.0,
      }.fetch(value["js"])
    end
    value.is_a?(Array) ? value.map { |v| cell(v) } : value
  end

  def test_spreadsheet_formulas_are_defused
    assert_equal "'=SUM(A1),'+1,-2,\"a,b\",\"say \"\"hi\"\"\",12", Zip.csv_row(["=SUM(A1)", "+1", "-2", "a,b", 'say "hi"', 12])
  end

  def test_rows
    Fixtures.load("zip")["rows"].each do |c|
      assert_equal c["row"], Zip.csv_row([cell(c["cell"])]), Fixtures.label(c["cell"])
    end
  end

  def test_csvs
    Fixtures.load("zip")["csvs"].each do |c|
      rows = c["rows"].map { |row| row.map { |v| cell(v) } }
      assert_equal c["csv"], Zip.csv(c["header"], rows)
    end
  end

  def test_zips
    Fixtures.load("zip")["zips"].each do |c|
      assert_equal c["base64"].unpack1("m").unpack1("H*"), Zip.zip(c["files"], c["now"]).unpack1("H*"), Fixtures.label(c["now"])
    end
  end

  def test_a_zip_starts_like_one
    bytes = Zip.zip([{ "name" => "overview.csv", "text" => "a\r\n" }], 0)
    assert_equal "PK\x03\x04".b, bytes[0, 4]
    assert_includes bytes, "overview.csv".b
  end
end
