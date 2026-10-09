"""The pieces of JavaScript's Intl the email reports use, for the dashboard's languages (en, de, es, fr, and
pt): Intl.NumberFormat for counts, percents, one decimal place, and money, Intl.DateTimeFormat for a month and
year or a short day, and Intl.DisplayNames for a region's name. Python has no ICU, so region names, currency
symbols, and currency fraction digits come from data/intl.json, which scripts/python-intl.mts writes from
Node's own ICU.

Numbers round as ICU does, half away from zero on the number's shortest decimal form, so 2.05 to one
place is 2.1, though the double just under it is what is stored.
"""

from __future__ import annotations

import json
import math
import re
from functools import cache
from pathlib import Path
from typing import Any

from . import _js

_GROUP = {"en": ",", "de": ".", "es": ".", "fr": " ", "pt": "."}
_DECIMAL = {"en": ".", "de": ",", "es": ",", "fr": ",", "pt": ","}
_PERCENT = {"en": "{}%", "de": "{} %", "es": "{} %", "fr": "{} %", "pt": "{}%"}

_MONTHS = {
    "en": ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
           "November", "December"],
    "de": ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November",
           "Dezember"],
    "es": ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre",
           "noviembre", "diciembre"],
    "fr": ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre",
           "novembre", "décembre"],
    "pt": ["janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho", "agosto", "setembro", "outubro",
           "novembro", "dezembro"],
}  # fmt: skip
_SHORT_MONTHS = {
    "en": ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
    "de": ["Jan.", "Feb.", "März", "Apr.", "Mai", "Juni", "Juli", "Aug.", "Sept.", "Okt.", "Nov.", "Dez."],
    "es": ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sept", "oct", "nov", "dic"],
    "fr": ["janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc."],
    "pt": ["jan.", "fev.", "mar.", "abr.", "mai.", "jun.", "jul.", "ago.", "set.", "out.", "nov.", "dez."],
}
# { month: "long", year: "numeric" }, then { month: "short", day: "numeric" } without and with the year.
_DATE_PATTERNS = {
    "en": ["{M} {y}", "{m} {d}", "{m} {d}, {y}"],
    "de": ["{M} {y}", "{d}. {m}", "{d}. {m} {y}"],
    "es": ["{M} de {y}", "{d} {m}", "{d} {m} {y}"],
    "fr": ["{M} {y}", "{d} {m}", "{d} {m} {y}"],
    "pt": ["{M} de {y}", "{d} de {m}", "{d} de {m} de {y}"],
}

_THREES = re.compile(r"\B(?=(\d{3})+\Z)", re.ASCII)


@cache
def _data() -> dict[str, Any]:
    return json.loads((Path(__file__).parent / "data" / "intl.json").read_text("utf-8"))


def _lang(lang: str) -> str:
    return lang if lang in _GROUP else "en"


def number(lang: str, n: int | float, min_fraction: int = 0, max_fraction: int = 3) -> str:
    """new Intl.NumberFormat(lang, { minimumFractionDigits, maximumFractionDigits }).format(n); the defaults are 0
    and 3."""
    lang = _lang(lang)
    if isinstance(n, float) and math.isnan(n):
        return "NaN"
    if isinstance(n, float) and math.isinf(n):
        return ("-" if n < 0 else "") + "∞"
    negative, whole, fraction = _rounded(n, min_fraction, max_fraction)
    # Spanish groups only from five digits on (CLDR's minimum grouping digits of 2).
    if not (lang == "es" and len(whole) < 5):
        whole = _THREES.sub(_GROUP[lang], whole)
    return ("-" if negative else "") + whole + (_DECIMAL[lang] + fraction if fraction else "")


def percent(lang: str, n: int | float) -> str:
    """new Intl.NumberFormat(lang, { style: "percent", maximumFractionDigits: 0 }).format(n)."""
    lang = _lang(lang)
    if isinstance(n, float) and not math.isfinite(n):
        return _PERCENT[lang].format(number(lang, n))
    return _PERCENT[lang].format(number(lang, _times100(n), 0, 0))


_CODE = re.compile(r"[A-Za-z]{3}\Z")


def currency(lang: str, n: int | float, code: str, max_fraction: int) -> str:
    """new Intl.NumberFormat(lang, { style: "currency", currency, maximumFractionDigits }).format(n), or
    `${n} ${currency}` where Intl throws (a currency code that is not three letters)."""
    lang = _lang(lang)
    if not _CODE.match(code):
        return f"{_js.string(n)} {code}"
    code = code.upper()
    data = _data()
    own = data["currencies"][lang].get(code)
    if own is None:
        before, after = (part.replace("{c}", code) for part in data["unknown"][lang])
    else:
        before, after = own
    min_fraction = min(data["digits"].get(code, 2), max_fraction)
    amount = number(lang, abs(n) if _js.is_finite(n) else n, min_fraction, max_fraction)
    negative = n < 0 or (isinstance(n, float) and n == 0 and math.copysign(1, n) < 0)
    if amount.startswith("-"):
        amount = amount[1:]
    return ("-" if negative else "") + before + amount + after


def month_year(lang: str, date: str) -> str:
    """A date, YYYY-MM-DD, as { month: "long", year: "numeric" } writes it."""
    return _date(lang, date, 0)


def short_day(lang: str, date: str, with_year: bool) -> str:
    """A date as { month: "short", day: "numeric" } writes it, with `year: "numeric"` too when asked."""
    return _date(lang, date, 2 if with_year else 1)


def _date(lang: str, date: str, pattern: int) -> str:
    lang = _lang(lang)
    y, m, d = (int(part) for part in date.split("-"))
    return (
        _DATE_PATTERNS[lang][pattern]
        .replace("{M}", _MONTHS[lang][m - 1])
        .replace("{m}", _SHORT_MONTHS[lang][m - 1])
        .replace("{d}", str(d))
        .replace("{y}", str(y))
    )


_REGION = re.compile(r"([A-Z]{2}|[0-9]{3})\Z")


def region(lang: str, code: str) -> str:
    """new Intl.DisplayNames(lang, { type: "region" }).of(code), or the code where that throws. Only an upper case
    code is looked up; Intl gives any other back as it came."""
    if not _REGION.match(code):
        return code
    return _data()["regions"][_lang(lang)].get(code, code)


def _times100(n: int | float) -> int | float:
    """n * 100, worked out on the decimal digits, as ICU scales a percent, so 0.135 is 13.5 and not
    13.500000000000002."""
    if isinstance(n, int):
        return n * 100
    negative, digits, point = _decimal(n)
    return float(("-" if negative else "") + _plain(digits, point + 2))


def _rounded(n: int | float, min: int, max: int) -> tuple[bool, str, str]:
    """The number's sign, whole digits, and fraction digits, rounded half away from zero to at most `max` places
    and padded to at least `min`."""
    if isinstance(n, int):
        return n < 0, str(abs(n)), "0" * min
    negative, digits, point = _decimal(n)
    # Digits as a whole number of units of 10^-max.
    keep = point + max
    if keep < 0:
        units = "0"
    elif len(digits) > keep:
        units = "0" if keep == 0 else digits[:keep]
        if int(digits[keep]) >= 5:
            units = str(int(units) + 1)
    else:
        units = digits.ljust(keep, "0")
    units = units.rjust(max + 1, "0")
    whole = units[: len(units) - max].lstrip("0")
    fraction = (units[-max:] if max > 0 else "").rstrip("0")
    fraction = fraction.ljust(min, "0")
    return negative, whole or "0", fraction


def _decimal(n: float) -> tuple[bool, str, int]:
    """The shortest decimal form of a double: its sign, its significant digits, and where the point goes (the
    number of digits before it, which may be zero or negative)."""
    negative = n < 0 or (n == 0 and math.copysign(1, n) < 0)
    text = repr(abs(n))
    exponent = 0
    if "e" in text:
        text, power = text.split("e")
        exponent = int(power)
    whole, _, fraction = text.partition(".")
    digits = whole + fraction
    point = len(whole) + exponent
    trimmed = digits.lstrip("0")
    point -= len(digits) - len(trimmed)
    trimmed = trimmed.rstrip("0")
    return negative, trimmed or "0", point if trimmed else 1


def _plain(digits: str, point: int) -> str:
    """Digits with the point after `point` of them, written out in full."""
    if point <= 0:
        return "0." + "0" * -point + digits
    if point >= len(digits):
        return digits + "0" * (point - len(digits))
    return digits[:point] + "." + digits[point:]
