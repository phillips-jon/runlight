# frozen_string_literal: true

require "test_helper"

# Replays tracker bodies through parse_payload, as the TypeScript SDK read them.
class PayloadTest < Minitest::Test
  Payload = Runlight::Payload
  Json = Runlight::Json

  def test_fixture
    fixture = Fixtures.load("payload")
    assert_equal fixture["maxBody"], Payload::MAX_BODY
    fixture["cases"].each do |c|
      payload = Payload.parse_payload(c["text"])
      unless payload.nil?
        payload["url"] = payload["url"].href
        payload["props"] = payload["props"].nil? ? nil : Json.encode(payload["props"])
      end
      assert_equal Json.encode(c["payload"]), Json.encode(payload), Fixtures.label(c["text"])
    end
  end

  def test_props_with_index_keys_stay_an_object
    payload = Payload.parse_payload('{"k":"event","u":"https://example.com/","n":"x","p":{"1":"b","0":"a"}}')
    assert_equal '{"0":"a","1":"b"}', Json.encode(payload["props"])
  end
end
