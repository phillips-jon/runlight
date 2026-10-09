# frozen_string_literal: true

module Runlight
  module Brand
    module_function

    # The Runlight mark for the dashboard's tab: an R in a rounded lamp housing, one corner lit. A data: URL.
    def runlight_icon
      Version.build["icon"].to_s
    end
  end
end
