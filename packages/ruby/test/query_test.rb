# frozen_string_literal: true

require "test_helper"

# Replays the query fixture written from the TypeScript SDK.
class QueryTest < Minitest::Test
  Query = Runlight::Query
  Json = Runlight::Json

  def test_dimension_lists
    fixture = Fixtures.load("query")
    assert_equal Json.encode(fixture["eventDimensions"]), Json.encode(Query::EVENT_DIMENSIONS)
    assert_equal Json.encode(fixture["sessionDimensions"]), Json.encode(Query::SESSION_DIMENSIONS)
    assert_equal fixture["dimensions"], Query::DIMENSIONS
    assert_equal Query::EVENT_DIMENSIONS.keys + Query::SESSION_DIMENSIONS.keys + Query::FETCH_DIMENSIONS, Query::DIMENSIONS
    assert_equal fixture["maxFilters"], Query::MAX_FILTERS
  end

  def test_dimension_tests
    Fixtures.load("query")["dimensionTests"].each do |c|
      assert_equal [c["isDimension"], c["isSessionDimension"], c["isEventDimension"]],
                   [Query.dimension?(c["value"]), Query.session_dimension?(c["value"]), Query.event_dimension?(c["value"])],
                   c["value"]
    end
  end

  def test_parse_filter
    Fixtures.load("query")["filters"].each do |c|
      assert_equal Json.encode(c["filter"]), Json.encode(Query.parse_filter(c["text"])), Fixtures.label(c["text"])
    end
  end
end
