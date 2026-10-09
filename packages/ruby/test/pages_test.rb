# frozen_string_literal: true

require "test_helper"

# The account pages against the pages fixture, the TypeScript's HTML for the same inputs.
class PagesTest < Minitest::Test
  Pages = Runlight::Accounts::Pages

  def snake(name)
    name.gsub(/([A-Z])/) { "_#{Regexp.last_match(1).downcase}" }
  end

  def test_styles_and_script_match
    fixture = Fixtures.load("pages")
    assert_equal fixture["css"], Pages::AUTH_CSS
    assert_equal fixture["js"], Pages::AUTH_JS
  end

  def test_pages_match
    fixture = Fixtures.load("pages")
    fixture["pages"].each do |c|
      html = c["opts"].nil? ? Pages.public_send(snake(c["fn"]), c["base"]) : Pages.public_send(snake(c["fn"]), c["base"], c["opts"])
      assert_equal c["html"], html, "#{c["fn"]} at \"#{c["base"]}\""
    end
    fixture["roles"].each do |c|
      assert_equal c["text"], Pages.role_text(c["role"])
    end
  end

  def test_setup_asks_for_the_token_when_told
    page = Pages.setup_page("/runlight", { "code" => "", "askCode" => true })
    assert_match(/RUNLIGHT_TOKEN/, page)
    assert_match(%r{action="/runlight/setup"}, page)
    assert_match(%r{href="/runlight/auth\.css"}, page)
    assert_includes Pages.invite_page("", { "code" => "c", "email" => "a@b.c", "role" => "member", "host" => "x" }), "as a member"
  end
end
