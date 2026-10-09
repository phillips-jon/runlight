"""The account pages against tests/fixtures/pages.json, the TypeScript's HTML for the same inputs."""

from __future__ import annotations

import re

from support import fixtures

from runlight.accounts import pages

NAMES = {
    "loginPage": pages.login_page,
    "codePage": pages.code_page,
    "invitePage": pages.invite_page,
    "inviteGonePage": pages.invite_gone_page,
    "setupPage": pages.setup_page,
    "setupLockedPage": pages.setup_locked_page,
    "setupNeedsTokenPage": pages.setup_needs_token_page,
}


def test_styles_and_script_match():
    fixture = fixtures.load("pages")
    assert pages.AUTH_CSS == fixture["css"]
    assert pages.AUTH_JS == fixture["js"]


def test_pages_match():
    fixture = fixtures.load("pages")
    for case in fixture["pages"]:
        page = NAMES[case["fn"]]
        html = page(case["base"]) if case["opts"] is None else page(case["base"], case["opts"])
        assert html == case["html"], f'{case["fn"]} at "{case["base"]}"'
    for case in fixture["roles"]:
        assert pages.role_text(case["role"]) == case["text"]


def test_setup_asks_for_the_token_when_told():
    page = pages.setup_page("/runlight", {"code": "", "askCode": True})
    assert re.search("RUNLIGHT_TOKEN", page)
    assert re.search(r'action="/runlight/setup"', page)
    assert re.search(r'href="/runlight/auth\.css"', page)
    assert "as a member" in pages.invite_page("", {"code": "c", "email": "a@b.c", "role": "member", "host": "x"})
