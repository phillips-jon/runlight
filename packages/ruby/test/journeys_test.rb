# frozen_string_literal: true

require "test_helper"

# Journeys, as journeys.test.ts tests them, and against the journeys fixture.
class JourneysTest < Minitest::Test
  Journeys = Runlight::Journeys
  Json = Runlight::Json

  def rows(visits)
    visits.flat_map { |session, pages| pages.map { |path| { "session" => session.to_s, "path" => path } } }
  end

  def test_journeys_line_paths_up_by_step_with_flows_and_follow_a_start_an_end_and_one_page
    data = rows({
                  "a" => ["/", "/pricing", "/signup"],
                  "b" => ["/", "/pricing", "/pricing", "/docs"],
                  "c" => ["/", "/blog"],
                  "d" => ["/blog", "/", "/pricing"],
                  "e" => ["/docs"],
                })
    all = Journeys.journeys(data, { "steps" => 3 })
    assert_equal 5, all["visits"]
    assert_equal({ "items" => [{ "value" => "/", "visits" => 3 }, { "value" => "/blog", "visits" => 1 }, { "value" => "/docs", "visits" => 1 }],
                   "visits" => 5, "left" => 1 }, all["columns"][0])
    assert_equal({ "value" => "/pricing", "visits" => 2 }, all["columns"][1]["items"][0], "a refresh counts once")
    from_home = all["links"].select { |l| l["step"].zero? && l["from"] == "/" }
    assert_equal [["/pricing", 2], ["/blog", 1]], from_home.map { |l| [l["to"], l["visits"]] }
    assert_equal 5, all["paths"].length
    # With two steps, visits a, b, and d go on to a third page, so only c went no further than step two.
    two = Journeys.journeys(data, { "steps" => 2 })
    assert_equal [4, 1], [two["columns"][1]["visits"], two["columns"][1]["left"]], "the last step counts only visits that ended there"
    assert_equal({ "pages" => ["/", "/blog"], "visits" => 1 }, all["paths"][0], "ties in a fixed order")

    from_pricing = Journeys.journeys(data, { "steps" => 3, "start" => "/pricing" })
    assert_equal 3, from_pricing["visits"], "visits that reached /pricing, from there on"
    assert_equal [{ "value" => "/pricing", "visits" => 3 }], from_pricing["columns"][0]["items"]

    to_signup = Journeys.journeys(data, { "steps" => 4, "end" => "/signup" })
    assert_equal [{ "pages" => ["/", "/pricing", "/signup"], "visits" => 1 }], to_signup["paths"]

    through = Journeys.journeys(data, { "steps" => 3, "through" => { "step" => 1, "value" => "/blog" } })
    assert_equal 1, through["visits"]
  end

  def test_fixtures_match
    fixture = Fixtures.load("journeys")
    fixture["runs"].each do |run|
      options = run["options"].dup
      options["steps"] = Float::NAN if options["steps"] == "NaN"
      result = Journeys.journeys(fixture["datasets"][run["dataset"]], options)
      assert_equal Json.encode(run["result"]), Json.encode(result), "dataset #{run["dataset"]} with #{Json.encode(run["options"])}"
    end
  end
end
