"""The translator against the messages fixture: Intl.PluralRules' forms and the TypeScript's words."""

from __future__ import annotations

import math

from support import fixtures

from runlight.messages import languages, plural, translator


def test_languages() -> None:
    assert languages() == fixtures.load("messages")["languages"]


def test_plural_forms_match_intl() -> None:
    fixture = fixtures.load("messages")
    # NaN and the infinities come as text, and so do whole numbers too long for a PHP int.
    special = {"NaN": math.nan, "Infinity": math.inf, "-Infinity": -math.inf}
    numbers = [special.get(n, float(n)) if isinstance(n, str) else n for n in fixture["numbers"]]
    for lang, forms in fixture["plural"].items():
        for i, n in enumerate(numbers):
            assert plural(lang, n) == forms[i], f"{lang} {fixture['numbers'][i]!r}"


def test_words_match() -> None:
    for words in fixtures.load("messages")["words"]:
        t = translator(words["lang"])
        assert t.lang == words["code"]
        for case in words["t"]:
            assert t.t(case["key"], case["vars"]) == case["text"], f"{words['lang']} {case['key']}"
        for case in words["tn"]:
            got = t.tn(case["key"], case["n"], {"n": case["n"], "name": "x"})
            assert got == case["text"], f"{words['lang']} {case['key']} {case['n']}"


def test_french_counts_zero_as_one() -> None:
    assert plural("fr", 0) == "one"
    assert plural("fr", 1.5) == "one"
    assert plural("fr", 1_000_000) == "many"
    assert plural("en", 0) == "other"
