"""CSV and ZIP output, byte for byte as the TypeScript SDK writes them."""

from __future__ import annotations

import base64
import math
from typing import Any

from support import fixtures

from runlight import _js
from runlight.zip import csv, csv_row, zip


def cell(value: Any) -> Any:
    """A cell back from its fixture form: {"js": "NaN"} and the like become the values JSON cannot carry."""
    if isinstance(value, dict) and list(value) == ["js"]:
        return {"undefined": _js.UNDEFINED, "NaN": math.nan, "Infinity": math.inf, "-Infinity": -math.inf, "-0": -0.0}[
            value["js"]
        ]
    if isinstance(value, list):
        return [cell(v) for v in value]
    return value


def test_spreadsheet_formulas_are_defused() -> None:
    assert csv_row(["=SUM(A1)", "+1", "-2", "a,b", 'say "hi"', 12]) == "'=SUM(A1),'+1,-2,\"a,b\",\"say \"\"hi\"\"\",12"


def test_rows() -> None:
    for case in fixtures.load("zip")["rows"]:
        assert csv_row([cell(case["cell"])]) == case["row"], fixtures.label(case["cell"])


def test_csvs() -> None:
    for case in fixtures.load("zip")["csvs"]:
        rows = [[cell(v) for v in row] for row in case["rows"]]
        assert csv(case["header"], rows) == case["csv"]


def test_zips() -> None:
    for case in fixtures.load("zip")["zips"]:
        assert zip(case["files"], case["now"]).hex() == base64.b64decode(case["base64"]).hex(), case["now"]


def test_a_zip_starts_like_one() -> None:
    data = zip([{"name": "overview.csv", "text": "a\r\n"}], 0)
    assert data[:4] == b"PK\x03\x04"
    assert b"overview.csv" in data
