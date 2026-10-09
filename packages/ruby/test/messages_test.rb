# frozen_string_literal: true

require "test_helper"

# The translator against the messages fixture: Intl.PluralRules' forms and the TypeScript's words.
class MessagesTest < Minitest::Test
  Messages = Runlight::Messages

  def test_languages
    assert_equal Fixtures.load("messages")["languages"], Messages.languages
  end

  def test_plural_forms_match_intl
    fixture = Fixtures.load("messages")
    # NaN and the infinities come as text, and so do whole numbers too long to read exactly.
    numbers = fixture["numbers"].map do |n|
      case n
      when "NaN" then Float::NAN
      when "Infinity" then Float::INFINITY
      when "-Infinity" then -Float::INFINITY
      when String then Float(n)
      else n
      end
    end
    fixture["plural"].each do |lang, forms|
      numbers.each_with_index do |n, i|
        assert_equal forms[i], Messages.plural(lang, n), "#{lang} #{fixture["numbers"][i].inspect}"
      end
    end
  end

  def test_words_match
    Fixtures.load("messages")["words"].each do |set|
      words = Messages.translator(set["lang"])
      assert_equal set["code"], words["lang"]
      set["t"].each do |c|
        assert_equal c["text"], words["t"].call(c["key"], c["vars"]), "#{set["lang"]} #{c["key"]}"
      end
      set["tn"].each do |c|
        assert_equal c["text"], words["tn"].call(c["key"], c["n"], { "n" => c["n"], "name" => "x" }), "#{set["lang"]} #{c["key"]} #{c["n"]}"
      end
    end
  end

  def test_french_counts_zero_as_one
    assert_equal "one", Messages.plural("fr", 0)
    assert_equal "one", Messages.plural("fr", 1.5)
    assert_equal "many", Messages.plural("fr", 1_000_000)
    assert_equal "other", Messages.plural("en", 0)
  end
end
