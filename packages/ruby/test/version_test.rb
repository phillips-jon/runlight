# frozen_string_literal: true

require "test_helper"

class VersionTest < Minitest::Test
  def test_the_versions_and_icon_are_the_type_script_sdks
    fixture = Fixtures.load("version")
    assert_equal fixture["version"], Runlight::Version.version
    assert_equal fixture["apiVersion"], Runlight::Version.api_version
    assert_equal fixture["icon"], Runlight::Brand.runlight_icon
  end
end
