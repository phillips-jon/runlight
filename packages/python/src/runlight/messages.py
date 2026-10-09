"""The dashboard's translations, for text the server writes (email reports).
Same keys, same placeholders, so every language stays in one place."""

from __future__ import annotations

import re
from typing import Any

from . import _js
from .assets import ENGLISH, LOCALES

_parsed: dict[str, dict[str, str]] = {}


def _table(lang: str) -> dict[str, str]:
    found = _parsed.get(lang)
    if found is None:
        raw = ENGLISH if lang == "en" else LOCALES.get(lang)
        found = _js.loads(raw) if raw else {}
        _parsed[lang] = found
    return found


def languages() -> list[str]:
    return ["en", *(code for code in LOCALES if code != "en")]


_PLACEHOLDER = re.compile(r"\{(\w+)\}", re.ASCII)


class Translator:
    """The words for one language: t(key, vars) and tn(key, n, vars), with `lang` the language used, English when
    the one asked for is not known."""

    def __init__(self, lang: str) -> None:
        self.lang = lang if lang in languages() else "en"

    @staticmethod
    def _fill(text: str, vars: dict[str, Any]) -> str:
        return _PLACEHOLDER.sub(lambda m: _js.string(vars[m.group(1)]) if m.group(1) in vars else m.group(0), text)

    def t(self, key: str, vars: dict[str, Any] | None = None) -> str:
        own = _table(self.lang).get(key)
        if own is None:
            own = _table("en").get(key)
        return self._fill(own if own is not None else key, vars or {})

    def tn(self, key: str, n: int | float, vars: dict[str, Any] | None = None) -> str:
        form = plural(self.lang, n)
        table = _table(self.lang)
        own = table.get(f"{key}_{form}")
        if own is None:
            own = table.get(f"{key}_other")
        return self._fill(own, vars or {}) if own else self.t(f"{key}_other", vars)


def translator(lang: str) -> Translator:
    return Translator(lang)


def plural(lang: str, n: int | float) -> str:
    """Intl.PluralRules(lang).select(n) for the dashboard's languages, by CLDR's cardinal rules. As there, the
    number is first written with at most three decimals (rounding half away from zero), and its integer digits i
    and visible decimals v are read from that. Any other language answers "other".

    - en, de: one when i = 1 and v = 0
    - es: one when n = 1; many when i is a non-zero multiple of a million and v = 0
    - fr, pt: one when i is 0 or 1; many as in es
    """
    if not _js.is_finite(n):
        return "other"
    i, fraction = _decimal(abs(n))
    v = len(fraction)
    million = i != "0" and len(i) >= 7 and i.endswith("000000")
    if lang in ("en", "de"):
        return "one" if i == "1" and v == 0 else "other"
    if lang == "es":
        if i == "1" and v == 0:
            return "one"
        return "many" if million and v == 0 else "other"
    if lang in ("fr", "pt"):
        if i in ("0", "1"):
            return "one"
        return "many" if million and v == 0 else "other"
    return "other"


_EXPONENT = re.compile(r"(\d+)(?:\.(\d+))?e([+-]\d+)\Z", re.ASCII)


def _decimal(n: int | float) -> tuple[str, str]:
    """A non-negative number as its integer digits and up to three decimals without trailing zeros, from the
    shortest decimal that reads back as the number, as ICU formats it."""
    text = _js.number_text(n)
    # Plain digits, from JavaScript's exponent form where it uses one.
    m = _EXPONENT.match(text)
    if m:
        digits = m.group(1) + (m.group(2) or "")
        point = len(m.group(1)) + int(m.group(3))
        if point <= 0:
            text = "0." + "0" * -point + digits
        elif point >= len(digits):
            text = digits + "0" * (point - len(digits))
        else:
            text = digits[:point] + "." + digits[point:]
    whole, _, fraction = text.partition(".")
    if len(fraction) > 3:
        up = int(fraction[3]) >= 5
        fraction = fraction[:3]
        if up:
            # Add one at the third decimal, carrying into the whole part.
            everything = str(int(whole + fraction) + 1).rjust(len(whole) + 3, "0")
            whole = everything[:-3]
            fraction = everything[-3:]
    # ICU reads i as a 64-bit integer, keeping only the lowest 18 digits of a larger number, so 1e21 has i = 0.
    whole = whole[-18:].lstrip("0")
    return whole or "0", fraction.rstrip("0")


