# frozen_string_literal: true

module Runlight
  # JavaScript's undefined, for the few answers that build an object with a
  # field that may be left out: Json.encode skips a field holding it, and
  # writes it as null inside an array, as JSON.stringify does.
  UNDEFINED = Object.new
  def UNDEFINED.inspect = "undefined"
  def UNDEFINED.to_s = "undefined"
  UNDEFINED.freeze
end
