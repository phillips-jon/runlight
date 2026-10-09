# frozen_string_literal: true

require "test_helper"

# The TypeScript SDK's sources tests, then the fixture written from it.
class SourcesTest < Minitest::Test
  Sources = Runlight::Sources
  Url = Runlight::Http::Url
  Json = Runlight::Json

  def visit(url, referrer = "", internal = [])
    Sources.attribute(Sources.parse_page(Url.new(url)), referrer, internal)
  end

  def test_no_referrer_and_no_tags_is_direct
    assert_equal({ "referrerHost" => "", "referrerPath" => "", "source" => "", "channel" => "Direct" }, visit("https://example.com/"))
  end

  def test_search_engines_are_organic_search_by_the_most_specific_host
    assert_equal "Organic Search", visit("https://example.com/", "https://www.google.co.uk/")["channel"]
    assert_equal "Google", visit("https://example.com/", "https://www.google.co.uk/")["source"]
    assert_equal "Gmail", Sources.source_for_host("mail.google.com")["name"]
    assert_equal "Gemini", Sources.source_for_host("gemini.google.com")["name"]
  end

  def test_a_click_id_on_a_search_referrer_is_paid_search
    assert_equal "Paid Search", visit("https://example.com/?gclid=abc", "https://www.google.com/")["channel"]
    assert_equal "Paid Search", visit("https://example.com/?utm_source=google&utm_medium=cpc")["channel"]
  end

  def test_ai_assistants_are_the_ai_channel_by_referrer_or_by_tag
    assert_equal({ "referrerHost" => "chatgpt.com", "referrerPath" => "/", "source" => "ChatGPT", "channel" => "AI" },
                 visit("https://example.com/post", "https://chatgpt.com/"))
    tagged = visit("https://example.com/post?utm_source=chatgpt.com")
    assert_equal "ChatGPT", tagged["source"]
    assert_equal "AI", tagged["channel"]
    assert_equal "Perplexity", visit("https://example.com/", "https://www.perplexity.ai/search/x")["source"]
    assert_equal "AI", visit("https://example.com/", "https://claude.ai/")["channel"]
  end

  def test_social_email_campaigns_and_referrals
    assert_equal "Hacker News", visit("https://example.com/", "https://news.ycombinator.com/item?id=1")["source"]
    assert_equal "Social", visit("https://example.com/", "https://t.co/abc")["channel"]
    assert_equal "Email", visit("https://example.com/?utm_source=weekly&utm_medium=email")["channel"]
    assert_equal "Email", visit("https://example.com/?utm_source=newsletter")["channel"]
    assert_equal "Campaign", visit("https://example.com/?utm_source=partner&utm_campaign=launch")["channel"]
    assert_equal "partner", visit("https://example.com/?utm_source=partner&utm_campaign=launch")["source"]
    assert_equal "Referral", visit("https://example.com/", "https://someblog.net/post")["channel"]
    assert_equal "someblog.net", visit("https://example.com/", "https://someblog.net/post")["source"]
    assert_equal "Product Hunt", visit("https://example.com/?ref=producthunt")["source"]
  end

  def test_the_sites_own_hosts_are_not_a_referrer
    assert_equal "Direct", visit("https://example.com/b", "https://www.example.com/a")["channel"]
    assert_equal "", visit("https://example.com/b", "https://shop.example.com/a", ["shop.example.com"])["referrerHost"]
    assert_equal "Direct", visit("https://example.com/b", "not a url")["channel"]
  end

  def test_only_the_path_and_campaign_parameters_are_kept_from_a_url
    page = Sources.parse_page(Url.new("https://www.example.com/a/b?email=x@y.z&utm_campaign=spring&fbclid=123#top"))
    assert_equal "example.com", page["hostname"]
    assert_equal "/a/b#top", page["path"]
    assert_equal "spring", page["utm"]["campaign"]
    assert page["paid"]
    refute_includes Json.encode(page), "x@y.z"
    refute_includes Json.encode(page), "123"
  end

  def test_app_referrers_email_click_trackers_and_webmail_are_named
    assert_equal "Gmail", Sources.source_for_host("com.google.android.gm")["name"]
    assert_equal "Gmail", visit("https://example.com/", "android-app://com.google.android.gm/")["source"]
    assert_equal "Email", visit("https://example.com/", "https://com.google.android.gm/")["channel"]
    assert_equal "Kit", visit("https://example.com/", "https://15a992bb.click.convertkit-mail4.com/x")["source"]
    assert_equal "Email", visit("https://example.com/", "https://15a992bb.click.convertkit-mail4.com/x")["channel"]
    assert_equal "mail01.orange.fr", visit("https://example.com/", "https://mail01.orange.fr/")["source"]
    assert_equal "Email", visit("https://example.com/", "https://mail01.orange.fr/")["channel"]
    assert_equal "Email", visit("https://example.com/", "https://mail.aol.com/")["channel"]
    assert_equal "Referral", visit("https://example.com/", "https://mailbox.org/")["channel"], "only mail. or webmail. prefixes count"
  end

  def test_hosts_and_aliases
    fixture = Fixtures.load("sources")
    fixture["hosts"].each do |c|
      assert_equal Json.encode(c["source"]), Json.encode(Sources.source_for_host(c["host"])), Fixtures.label(c["host"])
    end
    fixture["aliases"].each do |c|
      assert_equal Json.encode(c["source"]), Json.encode(Sources.source_for_alias(c["alias"])), Fixtures.label(c["alias"])
    end
    fixture["stripWww"].each do |c|
      assert_equal c["host"], Sources.strip_www(c["input"]), Fixtures.label(c["input"])
    end
  end

  def test_pages
    Fixtures.load("sources")["pages"].each do |c|
      url = Url.parse(c["url"])
      assert_equal Json.encode(c["page"]), Json.encode(url.nil? ? nil : Sources.parse_page(url)), Fixtures.label(c["url"])
    end
  end

  def test_visits
    cases = Fixtures.load("sources")["visits"]
    failures = []
    cases.each do |c|
      got = Sources.attribute(Sources.parse_page(Url.new(c["url"])), c["referrer"], c["internal"])
      next if Json.encode(got) == Json.encode(c["attribution"])

      failures << "#{Fixtures.label([c["url"], c["referrer"], c["internal"]])} gave #{Fixtures.label(got)} not #{Fixtures.label(c["attribution"])}"
    end
    assert_operator cases.length, :>, 300
    assert_equal [], failures.first(20)
  end

  def test_recorded_and_readable_paths
    fixture = Fixtures.load("sources")
    fixture["recordedPaths"].each do |c|
      if c["path"].nil?
        assert_nil Sources.recorded_path(c["input"]), Fixtures.label(c["input"])
      else
        assert_equal c["path"], Sources.recorded_path(c["input"]), Fixtures.label(c["input"])
      end
    end
    fixture["readablePaths"].each do |c|
      readable = Sources.readable_path(c["input"])
      # A character newer than this Ruby's Unicode tables reads as unassigned, so it stays encoded where
      # Node, with newer tables, shows it.
      decoded = Runlight::Js.scrub(c["path"].b.gsub(/%([0-9A-Fa-f]{2})/n) { Regexp.last_match(1).hex.chr })
      next if readable != c["path"] && decoded.match?(/\p{Cn}/)

      assert_equal c["path"], readable, Fixtures.label(c["input"])
    end
  end
end
