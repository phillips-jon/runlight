"""Goals: checking one from the dashboard, and the click rules the tracker carries."""

from __future__ import annotations

import math
import re
from typing import Any

from . import _js
from .hash import random_id
from .sources import recorded_path


class GoalError(Exception):
    """Why a goal was refused, as a code the dashboard says in its own words."""

    def __init__(self, message: str, code: str, params: dict[str, str] | None = None) -> None:
        super().__init__(message)
        self.message = message
        self.code = code
        self.params = params or {}


def page_pattern(input: str) -> str | None:
    """A page to match, written the way paths are recorded: the path of a pasted URL, with a leading slash,
    percent-encoded as browsers send it, so /café matches the recorded /caf%C3%A9, and with a hash route kept, so
    /#/thanks counts only that route. `*` stays a wildcard. None when it is not a path or a URL."""
    starred = input.replace("*", "__STAR__")
    # A pattern written to start with * keeps that start, rather than gaining a slash.
    path = recorded_path(f"/{starred}" if starred.startswith("__STAR__") else starred)
    if path is None:
        return None
    pattern = path.replace("__STAR__", "*")
    return re.sub(r"\A/", "", pattern) if input.startswith("*") else pattern


_KINDS = ("event", "page", "click")
_MODES = ("none", "fixed", "prop")
_PROP = re.compile(r"[A-Za-z0-9_.-]{1,40}\Z")
_CURRENCY = re.compile(r"[A-Z]{3}\Z")


def _get(input: Any, key: str) -> Any:
    """input[key], undefined when it is not there."""
    return input.get(key, _js.UNDEFINED) if isinstance(input, dict) else _js.UNDEFINED


def _field(input: Any, key: str) -> str:
    """String(input[key] ?? "")."""
    value = _get(input, key)
    return "" if value is None or value is _js.UNDEFINED else _js.string(value)


def goal_from(input: dict[str, Any], site: str, existing: list[dict[str, Any]], now: int, id: str | None = None) -> dict[str, Any]:
    """Checks and tidies a goal from the dashboard. `existing` is the site's other goals, so two goals cannot share a
    name."""

    def text(key: str, max: int) -> str:
        # .slice() counts UTF-16 units, as TypeScript does.
        return _js.cut(_js.trim(_field(input, key)), max)

    name = text("name", 80)
    if not name:
        raise GoalError("Give the goal a name", "goal_name")
    if any(g["id"] != id and g["name"].lower() == name.lower() for g in existing):
        raise GoalError(f'There is already a goal called "{name}"', "goal_exists", {"name": name})

    kind = _field(input, "kind")
    if kind not in _KINDS:
        raise GoalError("Pick what the goal counts: an event, a page visit, or a click", "goal_kind")

    match = text("match", 500)
    click_by = ""
    if kind == "event" and not match:
        raise GoalError("Enter the event's name", "goal_event")
    if kind == "page":
        if not match:
            raise GoalError("Enter a page path, like /thanks or /blog/*", "goal_page")
        # A full URL is fine to paste; the path is what counts.
        path = page_pattern(match)
        if path is None:
            raise GoalError("That page is not a path or a URL", "goal_page_bad")
        match = path
    if kind == "click":
        click_by = "link" if _get(input, "clickBy") == "link" else "selector"
        if not match:
            if click_by == "link":
                raise GoalError("Enter the link's address, like https://buy.stripe.com/*", "goal_link")
            raise GoalError("Enter a CSS selector, like #signup or .buy-button", "goal_selector")

    # A click goal sends an event named after itself, so its name and an event goal's match must not meet.
    others = [g for g in existing if g["id"] != id]
    if kind == "click" and any(g["kind"] == "event" and g["match"].lower() == name.lower() for g in others):
        raise GoalError(f'An event goal already counts events called "{name}", so give this click goal another name', "goal_event_taken", {"name": name})
    if kind == "event" and any(g["kind"] == "click" and g["name"].lower() == match.lower() for g in others):
        raise GoalError(f'The click goal "{match}" already sends events with that name', "goal_click_taken", {"match": match})

    mode = _js.string(_get(input, "valueMode"))
    value_mode = mode if mode in _MODES else "none"
    # Page visits and click rules carry no properties, so only an event can send its own amount.
    if value_mode == "prop" and kind != "event":
        raise GoalError("Only an event goal can take its amount from the event; use a fixed amount instead", "goal_prop_kind")
    value = _js.number(_get(input, "value")) if value_mode == "fixed" else 0
    if value_mode == "fixed" and not (math.isfinite(value) and 0 <= value < 1e9):
        raise GoalError("Enter an amount, like 49 or 9.99", "goal_amount")
    value_prop = (text("valueProp", 40) or "revenue") if value_mode == "prop" else ""
    if value_mode == "prop" and not _PROP.match(value_prop):
        raise GoalError("A property name uses letters, numbers, dots, dashes, and underscores", "goal_prop_name")
    currency = text("currency", 20).upper() or "USD"
    if not _CURRENCY.match(currency):
        raise GoalError("Use a three-letter currency code, like USD or EUR", "goal_currency")

    before = next((g for g in existing if g["id"] == id), None)
    return {
        "id": id if id is not None else random_id(),
        "site": site,
        "name": name,
        "kind": kind,
        "match": match,
        "clickBy": click_by,
        "valueMode": value_mode,
        "value": _js.whole(_js.js_round(value * 100) / 100),
        "valueProp": value_prop,
        "currency": currency,
        "createdAt": before["createdAt"] if before is not None else now,
    }


def click_rules(sites: list[dict[str, Any]], goals: list[dict[str, Any]]) -> dict[str, list[list[str]]]:
    """Click rules for the tracker, keyed by site id and by each of the site's hostnames (or "*" for a site with
    none), so the script finds its own. One rule is [s for selector or h for a link, what to match, the event to
    send]."""
    out: dict[str, list[list[str]]] = {}
    for site in sites:
        rules = [["h" if g["clickBy"] == "link" else "s", g["match"], g["name"]] for g in goals if g["site"] == site["id"] and g["kind"] == "click"]
        if not rules:
            continue
        out[site["id"]] = rules
        for host in site["hostnames"] or ["*"]:
            out[re.sub(r"\Awww\.", "", host)] = rules
    return out
