"""Browser, OS, and device from a user agent, plus the AI agent and bot tests.

A Client is a dict {"browser", "browserVersion", "os", "osVersion", "device"}, device one of "desktop",
"mobile", or "tablet". Client hints are the low entropy ones Chromium browsers send on every request: a dict
{"brands"?, "mobile"?, "platform"?}, each a string or None.

The patterns keep JavaScript's meaning: `.` stops at any line terminator and \\S at any JavaScript white space
(both spelled out), \\d is ASCII, and case-insensitive ones fold ASCII only (re.ASCII).
"""

from __future__ import annotations

import re
from typing import Any

from . import _js
from .data.agents import AI_AGENTS, BOT_PATTERN

# Any character JavaScript's `.` matches.
_DOT = "[^\\n\\r\\u2028\\u2029]"


def ai_agent(ua: str) -> dict[str, str] | None:
    lower = ua.lower()
    for agent in AI_AGENTS:
        if agent["token"] in lower:
            return agent
    return None


_BROWSER_LIKE = re.compile("mozilla|opera", re.IGNORECASE | re.ASCII)


def is_bot(ua: str) -> bool:
    if _js.length(ua) < 20 or not _BROWSER_LIKE.search(ua):
        return True
    return bool(BOT_PATTERN.search(ua))


BROWSERS: list[tuple[str, re.Pattern[str]]] = [
    (name, re.compile(pattern, re.ASCII))
    for name, pattern in [
        ("Edge", r"(?:Edg|EdgA|EdgiOS|Edge)/(\d+)"),
        ("Opera", r"(?:OPR|OPiOS|Opera)/(\d+)"),
        ("Samsung Internet", r"SamsungBrowser/(\d+)"),
        ("Yandex Browser", r"YaBrowser/(\d+)"),
        ("Vivaldi", r"Vivaldi/(\d+)"),
        ("UC Browser", r"UCBrowser/(\d+)"),
        ("DuckDuckGo", r"(?:Ddg|DuckDuckGo)/(\d+)"),
        ("Facebook", r"FB(?:AV|_IAB)/(\d+)"),
        ("Instagram", r"Instagram (\d+)"),
        ("Firefox", r"(?:Firefox|FxiOS)/(\d+)"),
        ("Chrome", r"(?:CriOS|Chrome)/(\d+)"),
        ("Safari", r"Version/(\d+)[\d.]* (?:Mobile/[^" + _js.WHITESPACE + r"]+ )?Safari/"),
        ("Internet Explorer", r"(?:MSIE |Trident/" + _DOT + r"*rv:)(\d+)"),
    ]
]

WINDOWS = {
    "10.0": "10",
    "6.3": "8.1",
    "6.2": "8",
    "6.1": "7",
    "6.0": "Vista",
    "5.1": "XP",
}

_WINDOWS_NT = re.compile(r"Windows NT (\d+\.\d+)", re.ASCII)
_IOS = re.compile(r"(?:iPhone|iPad|iPod)" + _DOT + r"*? OS (\d+)", re.ASCII)
_ANDROID = re.compile(r"Android (\d+)", re.ASCII)
_MAC = re.compile("Mac OS X|Macintosh")
_LINUX = re.compile("Linux|X11")
_TABLET = re.compile("iPad|Tablet|PlayBook|Silk")
_MOBILE = re.compile("Mobi|iPhone|iPod|Opera Mini|IEMobile")


def _unquote(value: str | None) -> str:
    return _js.trim((value or "").replace('"', ""))


def parse_client(ua: str, hints: dict[str, Any] | None = None, screen_width: int | float | None = None) -> dict[str, str]:
    hints = hints or {}
    browser = "Other"
    browser_version = ""
    for name, pattern in BROWSERS:
        match = pattern.search(ua)
        if match:
            browser = name
            browser_version = match.group(1) or ""
            break
    if browser == "Chrome" and "; wv)" in ua:
        browser = "Android WebView"
    # Brave looks like Chrome in the user agent but names itself in the hints.
    if browser == "Chrome" and '"Brave"' in (hints.get("brands") or ""):
        browser = "Brave"

    os = "Other"
    os_version = ""
    if match := _WINDOWS_NT.search(ua):
        os = "Windows"
        os_version = WINDOWS.get(match.group(1), "")
    elif match := _IOS.search(ua):
        os = "iOS"
        os_version = match.group(1)
    elif match := _ANDROID.search(ua):
        os = "Android"
        os_version = match.group(1)
    elif "Android" in ua:
        os = "Android"
    elif "CrOS" in ua:
        os = "Chrome OS"
    elif _MAC.search(ua):
        # macOS froze its version in the user agent at 10.15, so it says nothing.
        os = "macOS"
    elif _LINUX.search(ua):
        os = "Linux"
    platform = _unquote(hints.get("platform"))
    if os == "Other" and platform:
        os = "macOS" if platform == "macOS" else platform

    device = "desktop"
    if _TABLET.search(ua) or (os == "Android" and "Mobile" not in ua):
        device = "tablet"
    elif _MOBILE.search(ua) or _unquote(hints.get("mobile")) == "?1":
        device = "mobile"
    elif os == "macOS" and screen_width is not None and screen_width in (768, 810, 820, 834, 1024):
        # iPadOS asks for desktop sites with a Mac user agent; the screen gives it away.
        device = "tablet"
        os = "iOS"

    return {"browser": browser, "browserVersion": browser_version, "os": os, "osVersion": os_version, "device": device}
