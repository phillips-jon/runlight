# frozen_string_literal: true

require "test_helper"
require_relative "normalizer"

# The normalizer against cases run through normalize() in http-conformance.ts (tests/fixtures/conformance-normalize.json).
class ConformanceNormalizerTest < Minitest::Test
  N = Conformance::Normalizer

  Fixtures.load("conformance-normalize").each_with_index do |c, i|
    define_method("test_normalizes_as_type_script_does_case_#{i + 1}") do
      assert_equal N.canonical(c["output"]), N.canonical(N.normalize(c["input"])), Fixtures.label(c["input"])
    end
  end

  def test_keeps_objects_and_arrays_apart
    assert_equal '{"a":{},"b":[]}', Runlight::Json.encode(N.normalize({ "a" => {}, "b" => [] }))
  end

  def test_cookie_shape
    assert_equal "rl_session=<value>; Path=/; HttpOnly", N.cookie_shape("rl_session=abc123; Path=/; HttpOnly")
    assert_equal "rl_session=; Path=/; Max-Age=0", N.cookie_shape("rl_session=; Path=/; Max-Age=0")
    assert_equal "a=<value>", N.cookie_shape("a=b=c")
    assert_equal "no value here", N.cookie_shape("no value here")
    assert_equal "=x; Path=/", N.cookie_shape("=x; Path=/")
  end

  def test_canonical_ignores_key_order_and_number_form
    assert_equal N.canonical(Runlight::Json.decode('{"b":1,"a":[{"y":2.0,"x":null}]}')),
                 N.canonical(Runlight::Json.decode('{"a":[{"x":null,"y":2}],"b":1.0}'))
    refute_equal N.canonical(Runlight::Json.decode('{"a":{}}')), N.canonical(Runlight::Json.decode('{"a":[]}'))
    refute_equal N.canonical(Runlight::Json.decode("[1,2]")), N.canonical(Runlight::Json.decode("[2,1]"))
  end

  def test_reads_text_that_is_not_utf8_byte_by_byte
    text = "\xFF id=0123456789abcdef01234567 ?code=x\xA0y".b
    assert_equal "\xFF id=<hex> ?code=<value>".b, N.scrub(text).b
  end
end
