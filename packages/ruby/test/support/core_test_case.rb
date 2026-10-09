# frozen_string_literal: true

require_relative "harness"

# Tests of the Runlight core that run on every database at hand (see Databases).
class CoreTestCase < Minitest::Test
  DAY = Harness::DAY
  HOUR = Harness::HOUR
  MIN = Harness::MIN

  # Defines one test per database kind, as a PHPUnit data provider over kinds() does.
  def self.on_every_database(name, &block)
    Databases.kinds.each do |kind|
      define_method("test_#{name.tr(" ", "_")}_on_#{kind}") { instance_exec(kind, &block) }
    end
  end

  # Date.UTC with months counted from 1.
  def self.utc(y, m, d, h = 0, i = 0, s = 0)
    Time.utc(y, m, d, h, i, s).to_i * 1000
  end

  def utc(...)
    self.class.utc(...)
  end
end
