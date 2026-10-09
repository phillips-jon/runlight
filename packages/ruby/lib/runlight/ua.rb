# frozen_string_literal: true

module Runlight
  # Browser, OS, and device from a user agent, plus the AI agent and bot tests.
  #
  # A client is a Hash {"browser", "browserVersion", "os", "osVersion", "device" ("desktop", "mobile", or
  # "tablet")}. Client hints are the low entropy ones Chromium browsers send on every request: a Hash with
  # "brands", "mobile", and "platform", each a String or nil.
  #
  # The patterns keep JavaScript's meaning: `.` stops at any line terminator and \S at any JavaScript white
  # space (both spelled out), and case-insensitive ones run on bytes so folding stays ASCII.
  module Ua
    # Any character JavaScript's `.` matches.
    DOT = "[^\\n\\r\\u2028\\u2029]"

    BROWSERS = [
      ["Edge", %r{(?:Edg|EdgA|EdgiOS|Edge)/(\d+)}],
      ["Opera", %r{(?:OPR|OPiOS|Opera)/(\d+)}],
      ["Samsung Internet", %r{SamsungBrowser/(\d+)}],
      ["Yandex Browser", %r{YaBrowser/(\d+)}],
      ["Vivaldi", %r{Vivaldi/(\d+)}],
      ["UC Browser", %r{UCBrowser/(\d+)}],
      ["DuckDuckGo", %r{(?:Ddg|DuckDuckGo)/(\d+)}],
      ["Facebook", %r{FB(?:AV|_IAB)/(\d+)}],
      ["Instagram", /Instagram (\d+)/],
      ["Firefox", %r{(?:Firefox|FxiOS)/(\d+)}],
      ["Chrome", %r{(?:CriOS|Chrome)/(\d+)}],
      ["Safari", %r{Version/(\d+)[\d.]* (?:Mobile/[^#{Js::SPACE}]+ )?Safari/}],
      ["Internet Explorer", %r{(?:MSIE |Trident/#{DOT}*rv:)(\d+)}],
    ].freeze

    WINDOWS = {
      "10.0" => "10",
      "6.3" => "8.1",
      "6.2" => "8",
      "6.1" => "7",
      "6.0" => "Vista",
      "5.1" => "XP",
    }.freeze

    IOS = /(?:iPhone|iPad|iPod)#{DOT}*? OS (\d+)/
    PERSON = /mozilla|opera/in
    private_constant :BROWSERS, :WINDOWS, :IOS, :PERSON

    module_function

    # The AI agent a user agent names: a Hash {"name", "company", "kind", "token"}, or nil.
    def ai_agent(ua)
      lower = Js.lower(ua)
      Data::Agents::AI_AGENTS.find { |agent| lower.include?(agent["token"]) }
    end

    def bot?(ua)
      return true if Js.length(ua) < 20 || !ua.b.match?(PERSON)

      ua.b.match?(Data::Agents::BOT_PATTERN)
    end

    # hints: {"brands", "mobile", "platform"}, each optional. screen_width: Integer, Float, or nil.
    def parse_client(ua, hints = {}, screen_width = nil)
      ua = Js.scrub(ua)
      browser = "Other"
      browser_version = ""
      BROWSERS.each do |name, pattern|
        match = ua.match(pattern)
        next unless match

        browser = name
        browser_version = match[1] || ""
        break
      end
      browser = "Android WebView" if browser == "Chrome" && ua.include?("; wv)")
      # Brave looks like Chrome in the user agent but names itself in the hints.
      browser = "Brave" if browser == "Chrome" && hints["brands"].to_s.include?('"Brave"')

      os = "Other"
      os_version = ""
      if (match = ua.match(/Windows NT (\d+\.\d+)/))
        os = "Windows"
        os_version = WINDOWS[match[1]] || ""
      elsif (match = ua.match(IOS))
        os = "iOS"
        os_version = match[1]
      elsif (match = ua.match(/Android (\d+)/))
        os = "Android"
        os_version = match[1]
      elsif ua.include?("Android")
        os = "Android"
      elsif ua.include?("CrOS")
        os = "Chrome OS"
      elsif ua.match?(/Mac OS X|Macintosh/)
        # macOS froze its version in the user agent at 10.15, so it says nothing.
        os = "macOS"
      elsif ua.match?(/Linux|X11/)
        os = "Linux"
      end
      platform = unquote(hints["platform"])
      os = platform == "macOS" ? "macOS" : platform if os == "Other" && platform != ""

      device = "desktop"
      if ua.match?(/iPad|Tablet|PlayBook|Silk/) || (os == "Android" && !ua.include?("Mobile"))
        device = "tablet"
      elsif ua.match?(/Mobi|iPhone|iPod|Opera Mini|IEMobile/) || unquote(hints["mobile"]) == "?1"
        device = "mobile"
      elsif os == "macOS" && !screen_width.nil? && [768, 810, 820, 834, 1024].include?(screen_width)
        # iPadOS asks for desktop sites with a Mac user agent; the screen gives it away.
        device = "tablet"
        os = "iOS"
      end

      { "browser" => browser, "browserVersion" => browser_version, "os" => os, "osVersion" => os_version, "device" => device }
    end

    def unquote(value)
      Js.trim((value || "").delete('"'))
    end

    private_class_method :unquote
  end
end
