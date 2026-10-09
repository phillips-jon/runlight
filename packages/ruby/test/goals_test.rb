# frozen_string_literal: true

require "test_helper"

# Goals and funnels checked from the dashboard, against the goals fixture (written from the TypeScript SDK by
# scripts/php-fixtures-store.mts), and the checks goals.test.ts and funnels.test.ts make.
class GoalsTest < Minitest::Test
  Goals = Runlight::Goals
  Funnels = Runlight::Funnels
  Json = Runlight::Json

  # The answer as the fixture writes it: the row with a new id as "<random>", or the error.
  def outcome(fresh)
    value = yield
    value["id"] = "<random>" if fresh && value["id"].to_s.match?(/\A[0-9a-f]{24}\z/)
    Json.encode({ "value" => value })
  rescue Runlight::GoalError, Runlight::FunnelError => e
    Json.encode({ "error" => { "message" => e.message, "code" => e.code, "params" => e.params } })
  end

  def test_goals_are_checked_as_the_type_script_sdk_checks_them
    fixture = Fixtures.load("goals")
    existing = fixture["existing"]
    assert_operator fixture["goals"].length, :>, 50
    fixture["goals"].each_with_index do |c, i|
      id = c["id"]
      assert_equal Json.encode(c["result"]), outcome(id.nil?) { Goals.goal_from(c["input"], "s", existing, 1000, id) }, "##{i} #{Json.encode(c["input"])}"
    end
  end

  def test_funnels_are_checked_as_the_type_script_sdk_checks_them
    fixture = Fixtures.load("goals")
    existing = fixture["existingFunnels"]
    fixture["funnels"].each_with_index do |c, i|
      id = c["id"]
      assert_equal Json.encode(c["result"]), outcome(id.nil?) { Funnels.funnel_from(c["input"], "s", existing, 1000, id) }, "##{i} #{Json.encode(c["input"])}"
    end
  end

  def test_page_patterns_and_click_rules
    fixture = Fixtures.load("goals")
    fixture["patterns"].each do |c|
      if c["result"].nil?
        assert_nil Goals.page_pattern(c["input"]), c["input"]
      else
        assert_equal c["result"], Goals.page_pattern(c["input"]), c["input"]
      end
    end
    goal = lambda do |id, g|
      { "id" => id, "site" => "s", "name" => id, "kind" => "event", "match" => id, "clickBy" => "", "valueMode" => "none", "value" => 0,
        "valueProp" => "", "currency" => "USD", "createdAt" => 5 }.merge(g)
    end
    rules = Goals.click_rules(
      [{ "id" => "s", "name" => "S", "hostnames" => ["www.example.com", "shop.example.com"], "timezone" => "UTC" },
       { "id" => "t", "name" => "T", "hostnames" => [], "timezone" => "UTC" },
       { "id" => "u", "name" => "U", "hostnames" => ["u.example"], "timezone" => "UTC" }],
      [goal.call("c" * 24, { "name" => "Buy", "kind" => "click", "match" => ".buy", "clickBy" => "selector" }),
       goal.call("d" * 24, { "name" => "Out", "kind" => "click", "match" => "https://x.example/*", "clickBy" => "link", "site" => "t" }),
       goal.call("e" * 24, { "name" => "E", "site" => "u" })],
    )
    assert_equal Json.encode(fixture["rules"]), Json.encode(rules)
  end

  def test_goal_checks_say_what_is_wrong
    made = Goals.goal_from({ "name" => "X", "kind" => "event", "match" => "X" }, "default", [], 1)
    codes = [
      [{ "name" => "x", "kind" => "event", "match" => "Y" }, [made]],
      [{ "name" => "Y", "kind" => "event", "match" => "Y", "currency" => "dollars" }, []],
      [{ "name" => "Z", "kind" => "event", "match" => "Z", "valueMode" => "fixed", "value" => -1 }, []],
      [{ "name" => "W", "kind" => "event", "match" => "W", "valueMode" => "prop", "valueProp" => "a b" }, []],
      [{ "name" => "P", "kind" => "page", "match" => "/p", "valueMode" => "prop" }, []],
    ].map do |input, existing|
      Goals.goal_from(input, "default", existing, 1)
      "none"
    rescue Runlight::GoalError => e
      e.code
    end
    assert_equal %w[goal_exists goal_currency goal_amount goal_prop_name goal_prop_kind], codes
    renamed = Goals.goal_from({ "name" => "Renamed", "kind" => "event", "match" => "X" }, "default", [made], 99, made["id"])
    assert_equal [made["id"], 1], [renamed["id"], renamed["createdAt"]], "a goal changed keeps its id and when it was made"
  end
end
