"""routes.test.ts, ported (through the PHP port's RoutesTest), then the unit checks of the routes' own helpers:
cookies, bearer tokens, JSON-only writes, and the dashboard's page."""

from __future__ import annotations

import calendar
import contextlib
import hashlib
import io
import os
import re
from urllib.parse import quote

import pytest

from runlight import _js, assets
from runlight.routes import bearer, coded, cookie_value, dashboard, is_json, read_cookie
from runlight.store import Stores
from support.routes import body, owner, req, runlight


def test_the_tracker_is_public_cached_and_answers_304_to_its_etag() -> None:
    routes = runlight().routes({"token": "secret"})
    first = routes.handle(req("/runlight/s.js"))
    assert first.status == 200
    assert "javascript" in (first.headers.get("content-type") or "")
    assert "sendBeacon" in first.text()
    etag = first.headers.get("etag") or ""
    assert etag.startswith(f'"{assets.TRACKER_HASH}-'), "the etag covers the script and its click rules"
    assert routes.handle(req("/runlight/s.js", "GET", {"if-none-match": etag})).status == 304


def test_stats_need_the_token_as_a_bearer_or_through_the_cookie() -> None:
    routes = runlight().routes({"token": "secret"})
    assert routes.handle(req("/runlight/api/stats")).status == 401
    assert routes.handle(req("/runlight/api/stats", "GET", {"authorization": "Bearer wrong"})).status == 401
    assert routes.handle(req("/runlight/api/stats", "GET", {"authorization": "Bearer secret"})).status == 200

    sign_in = routes.handle(req("/runlight/?token=secret"))
    assert sign_in.status == 303
    assert sign_in.headers.get("location") == "/runlight/"
    cookie = sign_in.headers.get("set-cookie") or ""
    assert "HttpOnly" in cookie
    assert "Secure" in cookie
    assert "secret" not in cookie, "the cookie holds a digest, not the token"
    value = cookie.split(";")[0]
    assert routes.handle(req("/runlight/api/stats", "GET", {"cookie": value})).status == 200
    assert routes.handle(req("/runlight/", "GET", {"cookie": value})).status == 200


def test_with_no_token_everything_but_development_refuses_writes_included() -> None:
    for value in ("production", "", "staging"):
        if value:
            os.environ["NODE_ENV"] = value
        else:
            os.environ.pop("NODE_ENV", None)
        routes = runlight().routes({})
        assert routes.handle(req("/runlight/api/stats")).status == 503, f"NODE_ENV={value or '(unset)'}"
        minted = routes.handle(req("/runlight/api/tokens", "POST", {"content-type": "application/json"}, _js.dumps({"name": "x"})))
        assert minted.status == 503, "nobody can make a token on an install with no token"
    os.environ["NODE_ENV"] = "development"
    with contextlib.redirect_stderr(io.StringIO()):
        assert runlight().routes({}).handle(req("/runlight/api/stats")).status == 200


def test_authorize_replaces_the_token() -> None:
    routes = runlight().routes({"authorize": lambda r: r.headers.get("x-admin") == "yes"})
    assert routes.handle(req("/runlight/api/sites")).status == 401
    assert routes.handle(req("/runlight/api/sites", "GET", {"x-admin": "yes"})).status == 200


def test_the_element_picker_sends_its_choice_only_to_the_dashboard_its_ticket_names() -> None:
    now = [calendar.timegm((2026, 10, 7, 12, 0, 0)) * 1000]
    rl = runlight({"sites": [{"id": "blog", "hostnames": ["blog.example.com"]}], "now": lambda: now[0]})
    routes = rl.routes({"token": "secret"})

    def ask(given, auth="secret"):
        return routes.handle(owner("/runlight/api/pick?site=blog", "POST", given, auth))

    def target(ticket: str) -> str | None:
        script = routes.handle(req(f"/runlight/pick.js?runlight=pick&runlight_ticket={quote(ticket, safe='')}")).text()
        m = re.search(r'var \w+="([^"]*)";if\(', script)
        return m.group(1) if m else None

    assert ask({"origin": "https://stats.example.com"}, "wrong").status == 401, "only the owner gets a ticket"
    assert ask({"origin": "javascript:alert(1)"}).status == 400
    ticket = body(ask({"origin": "https://stats.example.com"}))["ticket"]
    assert target(ticket) == "https://stats.example.com"
    # A page that opens the site some other way has no ticket, or only a changed one, and the picker sends nowhere.
    assert target("") == ""
    assert target(re.sub(r"\.[a-f0-9]+\.", "." + b"https://evil.example".hex() + ".", ticket, count=1)) == ""
    assert routes.handle(req("/runlight/pick.js")).headers.get("cache-control") == "no-store"
    now[0] += 31 * 60_000
    assert target(ticket) == "", "a ticket runs out after half an hour"

    # The script also learns the site the ticket is for, and does nothing on any other site's pages.
    fresh = body(ask({"origin": "https://stats.example.com"}))["ticket"]
    script = routes.handle(req(f"/runlight/pick.js?runlight_ticket={quote(fresh, safe='')}")).text()
    assert _js.dumps(_js.dumps(["blog.example.com"])) in script
    assert "__RUNLIGHT_PICK_HOSTS__" not in script

    # A hub's manage token gets one only for the hub it connected from, recorded when it did.
    made = body(routes.handle(owner("/runlight/api/tokens", "POST", {"name": "Hub", "scope": "manage", "site": "blog"})))
    manage = made["secret"]
    refused = ask({"origin": "https://hub.example.net"}, manage)
    assert refused.status == 403
    assert body(refused)["code"] == "pick_hub"
    rl.store.set_setting(f"token-origin:{made['token']['id']}", "https://hub.example.net")
    assert ask({"origin": "https://evil.example"}, manage).status == 403, "never another origin"
    hub = body(ask({"origin": "https://hub.example.net"}, manage))["ticket"]
    assert target(hub) == "https://hub.example.net"


def test_the_check_endpoint_takes_the_cron_secret() -> None:
    routes = runlight().routes({"token": "secret", "cronSecret": "cron"})
    assert routes.handle(req("/runlight/api/check", "POST", {"content-type": "application/json"})).status == 401
    assert routes.handle(req("/runlight/api/check", "POST", {"authorization": "Bearer cron"})).status == 200
    assert routes.handle(req("/runlight/api/check", "POST", {"authorization": "Bearer secret"})).status == 200
    routes = runlight().routes({"token": "secret", "cronSecret": "cron"})
    assert routes.handle(req("/runlight/api/check", "GET", {"authorization": "Bearer cron"})).status == 200, "Vercel Cron sends GET"
    assert routes.handle(req("/runlight/api/check")).status == 401


def test_base_path_moves_everything() -> None:
    routes = runlight().routes({"token": "secret", "basePath": "/admin/runlight/"})
    assert routes.handle(req("/admin/runlight/s.js")).status == 200
    assert routes.handle(req("/runlight/s.js")).status == 404
    info = body(routes.handle(req("/admin/runlight/api")))
    assert info["name"] == "runlight"
    assert info["library"] == "runlight"
    assert info["language"] == "python"


def test_bad_queries_are_400s_with_a_reason() -> None:
    routes = runlight().routes({"token": None})
    for path in ("/runlight/api/stats?period=forever", "/runlight/api/stats?filter=nope", "/runlight/api/stats?filter=page:like:x", "/runlight/api/breakdown?dimension=shoe_size"):
        response = routes.handle(req(path))
        assert response.status == 400, path
        assert body(response)["error"]


def test_the_dashboard_page_loads_its_hashed_assets_under_a_strict_csp() -> None:
    hash_ = assets.DASHBOARD_HASH
    locales = assets.LOCALES_HASH
    routes = runlight().routes({"token": "secret", "basePath": "/admin/runlight"})
    page = routes.handle(req("/admin/runlight/"))
    assert page.status == 200, "the shell holds no data, so it loads signed out"
    assert "script-src 'self'" in (page.headers.get("content-security-policy") or "")
    html = page.text()
    assert f"/admin/runlight/assets/app.{hash_}.js" in html
    assert 'data-base="/admin/runlight"' in html
    js = routes.handle(req(f"/admin/runlight/assets/app.{hash_}.js"))
    assert js.status == 200
    assert "immutable" in (js.headers.get("cache-control") or "")
    assert routes.handle(req(f"/admin/runlight/assets/app.{hash_}.css")).status == 200
    assert routes.handle(req("/admin/runlight/assets/app.old.js")).status == 404
    assert f"/admin/runlight/assets/locale.fr.{locales}.json" in html, "the page lists its languages"
    french = routes.handle(req(f"/admin/runlight/assets/locale.fr.{locales}.json"))
    assert french.status == 200
    assert body(french)["filter.button"] == "Filtrer"
    assert routes.handle(req(f"/admin/runlight/assets/locale.xx.{locales}.json")).status == 404
    assert routes.handle(req("/admin/runlight/api/stats")).status == 401, "the data stays behind the token"


def test_a_sites_name_and_timezone_can_be_changed_and_survive_a_restart() -> None:
    store = Stores.sqlite(":memory:")
    first = runlight({"store": store, "site": {"name": "From code", "timezone": "UTC"}})
    routes = first.routes({"token": None})

    def patch(given, type_="application/json"):
        return routes.handle(req("/runlight/api/sites/default", "PATCH", {"content-type": type_}, _js.dumps(given)))

    assert patch({"name": "Jon's site", "timezone": "America/Toronto"}).status == 200
    assert patch({"timezone": "Mars/Olympus"}).status == 400
    assert patch({"name": ""}).status == 400
    assert patch({"name": "x"}, "text/plain").status == 415
    assert routes.handle(req("/runlight/api/sites/nope", "PATCH", {"content-type": "application/json"}, "{}")).status == 404
    listed = body(routes.handle(req("/runlight/api/sites")))
    assert listed["sites"][0]["name"] == "Jon's site"
    assert listed["sites"][0]["lastSeen"] is None

    # Code still says "From code"; the dashboard's change wins after a restart.
    again = runlight({"store": store, "site": {"name": "From code", "timezone": "UTC"}})
    again.init()
    assert again.site("default")["name"] == "Jon's site"
    assert again.site("default")["timezone"] == "America/Toronto"


def test_a_share_reads_one_sites_reports_and_nothing_else_until_it_is_deleted() -> None:
    rl = runlight(
        {
            "sites": [
                {"id": "a", "name": "Site A", "hostnames": ["a.com"], "timezone": "UTC"},
                {"id": "b", "name": "Site B", "hostnames": ["b.com"], "timezone": "UTC"},
            ]
        }
    )
    routes = rl.routes({"token": "secret"})

    assert routes.handle(req("/runlight/api/shares?site=a", "POST", {"content-type": "application/json"}, "{}")).status == 401
    made = routes.handle(owner("/runlight/api/shares?site=a", "POST", {"name": "Client"}))
    assert made.status == 201
    share = body(made)["share"]
    assert re.fullmatch(r"[a-f0-9]{32}", share["id"])
    assert share["path"] == f"/runlight/share/{share['id']}"

    page = routes.handle(req(share["path"]))
    assert page.status == 200
    assert f'data-share="{share["id"]}"' in page.text()
    assert page.headers.get("referrer-policy") == "no-referrer"

    as_ = {"x-runlight-share": share["id"]}
    assert routes.handle(req("/runlight/api/stats?site=b", "GET", as_)).status == 200
    assert body(routes.handle(req("/runlight/api/stats?site=b", "GET", as_)))["site"] == "a", "a share is pinned to its own site whatever is asked"
    sites = body(routes.handle(req("/runlight/api/sites", "GET", as_)))
    assert [[s["id"], s["hostnames"]] for s in sites["sites"]] == [["a", []]]
    assert routes.handle(req("/runlight/api/links?site=a", "GET", as_)).status == 401, "links need the token"
    assert routes.handle(req("/runlight/api/shares?site=a", "GET", as_)).status == 401, "a share cannot list shares"
    assert routes.handle(req("/runlight/api/stats", "GET", {"x-runlight-share": "0" * 32})).status == 404

    renamed = routes.handle(owner(f"/runlight/api/shares/{share['id']}?site=a", "PATCH", {"name": "Board"}))
    assert body(renamed)["share"]["name"] == "Board"
    assert routes.handle(owner(f"/runlight/api/shares/{share['id']}?site=b", "DELETE")).status == 404, "only from its own site"
    assert routes.handle(owner(f"/runlight/api/shares/{share['id']}?site=a", "DELETE")).status == 200
    assert routes.handle(req("/runlight/api/stats", "GET", as_)).status == 404
    assert routes.handle(req(share["path"])).status == 404


def test_the_dashboard_inside_a_cms_opens_one_framed_page_once_whose_session_reads_one_site() -> None:
    rl = runlight(
        {
            "sites": [
                {"id": "a", "name": "Site A", "hostnames": ["a.com"], "timezone": "UTC"},
                {"id": "b", "name": "Site B", "hostnames": ["b.com"], "timezone": "UTC"},
            ]
        }
    )
    routes = rl.routes({"token": "secret"})
    assert routes.handle(owner("/runlight/api/tokens", "POST", {"name": "CMS", "scope": "embed"})).status == 400, "an embed key is for one site"
    made = body(routes.handle(owner("/runlight/api/tokens", "POST", {"name": "CMS", "site": "a", "scope": "embed"})))
    assert made["token"]["scope"] == "embed"

    def mint(origin: str):
        return routes.handle(owner("/runlight/api/embed", "POST", {"origin": origin}, made["secret"]))

    assert mint("https://b.com").status == 400, "only an origin on the site's own domains"
    assert mint("https://www.a.com/admin").status == 400, "an origin, not a page"
    reader = body(routes.handle(owner("/runlight/api/tokens", "POST", {"name": "Script", "site": "a"})))["secret"]
    assert routes.handle(owner("/runlight/api/embed", "POST", {"origin": "https://a.com"}, reader)).status == 403, "only an embed key gets tickets"
    assert routes.handle(owner("/runlight/api/embed", "POST", {"origin": "https://a.com"})).status == 401, "and the owner's token is not one"
    assert routes.handle(owner("/runlight/api/stats?site=a", "GET", None, made["secret"])).status == 403, "an embed key reads nothing itself"
    minted = mint("https://www.a.com")
    assert minted.status == 201
    answer = body(minted)
    ticket, path = answer["ticket"], answer["path"]
    assert answer["site"] == "a"
    assert path == f"/runlight/embed?ticket={ticket}"
    assert made["token"]["id"] not in ticket, "a ticket never names its token"

    page = routes.handle(req(path))
    assert page.status == 200
    assert (page.headers.get("content-security-policy") or "").endswith("frame-ancestors https://www.a.com")
    assert page.headers.get("x-frame-options") is None
    assert page.headers.get("referrer-policy") == "no-referrer"
    found = re.search(r'data-embed="([^"]+)"', page.text())
    assert found
    session = found.group(1)
    assert re.fullmatch(r"\d+\.[a-f0-9]{24}\.[a-f0-9]{64}", session)
    again = routes.handle(req(path))
    assert again.status == 410, "a ticket works once"
    assert (again.headers.get("content-security-policy") or "").endswith("frame-ancestors https://www.a.com"), "a used ticket still says so inside its frame"
    assert routes.handle(req(path[:-1] + ("0" if path[-1] != "0" else "1"))).status == 404, "a ticket this install never signed"

    as_ = {"x-runlight-embed": session}
    assert body(routes.handle(req("/runlight/api/stats?site=b", "GET", as_)))["site"] == "a", "pinned to its token's site whatever is asked"
    assert routes.handle(req("/runlight/api/links?site=a", "GET", {**as_, "authorization": "Bearer secret"})).status == 403, "nothing a share cannot read, even beside the owner's token"
    assert routes.handle(req("/runlight/")).headers.get("x-frame-options") == "DENY", "every other page still refuses to be framed"

    rl.now = lambda: _js.number(session.split(".")[0]) + 1
    assert body(routes.handle(req("/runlight/api/stats", "GET", as_)))["code"] == "embed_expired", "a session lasts an hour"
    del rl.now

    assert routes.handle(owner(f"/runlight/api/tokens/{made['token']['id']}", "DELETE")).status == 200
    assert routes.handle(req("/runlight/api/stats", "GET", as_)).status == 401, "deleting the token ends its sessions at once"


def test_a_cms_plugin_reports_ai_agent_fetches_with_its_own_key_which_reads_nothing() -> None:
    rl = runlight({"site": {"hostnames": ["blog.example.com"]}})
    routes = rl.routes({"token": "secret", "observeKey": "agents"})

    def send(key, given):
        return routes.handle(owner("/runlight/api/observe", "POST", given, key))

    gpt = "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; ChatGPT-User/1.0; +https://openai.com/bot"
    assert send("wrong", {"url": "https://blog.example.com/post", "userAgent": gpt}).status == 401
    assert send("agents", {"url": "not a url", "userAgent": gpt}).status == 400
    assert send("agents", {"url": "https://blog.example.com/post", "userAgent": gpt}).status == 204
    assert send("agents", {"url": "https://blog.example.com/style.css", "userAgent": gpt}).status == 204, "assets are ignored, quietly"
    assert send("agents", {"url": "https://elsewhere.example/post", "userAgent": gpt}).status == 204, "other sites are ignored, quietly"
    assert routes.handle(owner("/runlight/api/stats", "GET", None, "agents")).status == 401, "the observe key reads nothing"
    rows = body(routes.handle(owner("/runlight/api/breakdown?period=today&dimension=ai_page")))
    assert [r["value"] for r in rows["rows"]] == ["/post"]


def test_a_gone_share_link_says_so_in_the_visitors_language_and_a_read_tokens_write_is_refused_with_a_code() -> None:
    rl = runlight({"sites": [{"id": "blog", "hostnames": ["blog.example.com"]}]})
    routes = rl.routes({"token": "secret"})
    gone = routes.handle(req("/runlight/share/" + "a" * 32, "GET", {"accept-language": "fr-CA,fr;q=0.9,en;q=0.8"}))
    assert gone.status == 404
    assert (gone.headers.get("content-type") or "").startswith("text/html")
    page = gone.text()
    assert '<html lang="fr">' in page
    assert "Ce lien de partage ne fonctionne plus" in page
    assert "This share link no longer works" in routes.handle(req("/runlight/share/" + "a" * 32)).text()

    read = body(routes.handle(owner("/runlight/api/tokens", "POST", {"name": "Script"})))["secret"]
    write = routes.handle(owner("/runlight/api/goals?site=blog", "POST", {"name": "X", "kind": "event", "match": "X"}, read))
    assert write.status == 403
    assert body(write)["code"] == "token_read_only"


def test_goal_funnel_site_and_assistant_refusals_carry_their_own_codes_and_params() -> None:
    rl = runlight({"managedSites": True})
    routes = rl.routes({"token": "secret"})

    def send(method, path, given):
        answer = body(routes.handle(owner(f"/runlight{path}", method, given)))
        return {"code": answer.get("code"), "params": answer.get("params")}

    assert send("POST", "/api/sites", {"name": "Blog", "hostnames": "nope"}) == {"code": "site_domain_invalid", "params": {"host": "nope"}}
    send("POST", "/api/sites", {"name": "Blog", "hostnames": "blog.example.com"})
    assert send("POST", "/api/sites", {"name": "Again", "hostnames": "blog.example.com"}) == {"code": "site_domain_taken", "params": {"host": "blog.example.com", "site": "Blog"}}
    send("POST", "/api/goals?site=blog.example.com", {"name": "Signup", "kind": "event", "match": "Signup"})
    assert send("POST", "/api/goals?site=blog.example.com", {"name": "signup", "kind": "event", "match": "x"}) == {"code": "goal_exists", "params": {"name": "signup"}}
    assert send("POST", "/api/funnels?site=blog.example.com", {"name": "F", "steps": [{"kind": "page", "match": "/"}]}) == {"code": "funnel_short", "params": {}}
    assert send("PUT", "/api/assistant", {"provider": "nope"}) == {"code": "assistant_provider", "params": {}}


# The routes' own helpers.


def test_cookies_are_read_by_name_with_equals_signs_kept_in_their_values() -> None:
    request = req("/", "GET", {"cookie": "a=1; runlight_token=x=y=z ;  other=2"})
    assert read_cookie(request, "runlight_token") == "x=y=z"
    assert read_cookie(request, "other") == "2"
    assert read_cookie(request, "missing") == ""
    assert read_cookie(req("/"), "a") == ""
    assert cookie_value("secret") == hashlib.sha256(b"runlight-cookie:secret").hexdigest()


def test_bearer_tokens_are_read_whatever_the_schemes_case() -> None:
    assert bearer(req("/", "GET", {"authorization": "Bearer abc"})) == "abc"
    assert bearer(req("/", "GET", {"authorization": "bEaReR   abc  "})) == "abc"
    assert bearer(req("/", "GET", {"authorization": "Basic abc"})) == ""
    assert bearer(req("/")) == ""


@pytest.mark.parametrize(
    ("type_", "want"),
    [
        ("application/json", True),
        ("Application/JSON; charset=utf-8", True),
        (" application/json ", True),
        ("text/plain; application/json", False),
        ("application/json-patch+json", False),
        ("text/plain;charset=UTF-8", False),
    ],
)
def test_only_a_json_media_type_counts_as_json(type_: str, want: bool) -> None:
    assert is_json(req("/", "POST", {"content-type": type_}, "{}")) is want


def test_a_request_with_no_type_is_not_json() -> None:
    assert is_json(req("/", "POST")) is False


def test_writes_must_be_json_unless_a_bearer_token_is_sent() -> None:
    routes = runlight({"sites": [{"id": "blog", "hostnames": ["blog.example.com"]}]}).routes({"token": None})
    # A form from another page cannot send JSON, so a cookie or an open install never lets it write.
    for method, path in (("POST", "/runlight/api/goals?site=blog"), ("PUT", "/runlight/api/mail"), ("PATCH", "/runlight/api/sites/blog")):
        answer = routes.handle(req(path, method, {"content-type": "application/x-www-form-urlencoded"}, "name=x"))
        assert answer.status == 415, f"{method} {path}"
        assert body(answer) == {"error": "Send JSON", "code": "send_json"}
    assert routes.handle(req("/runlight/api/check", "POST")).status == 415, "even a write with no body"
    assert routes.handle(req("/runlight/api/check", "POST", {"authorization": "Bearer x"})).status == 200, "a bearer token is never sent by a browser on its own"
    assert routes.handle(req("/runlight/api/goals/nope?site=blog", "DELETE")).status == 404, "a DELETE carries no body to check"


def test_errors_are_json_with_their_code_and_never_sniffed() -> None:
    answer = coded("Unknown site", "unknown_site", 404)
    assert answer.text() == '{"error":"Unknown site","code":"unknown_site"}'
    assert answer.headers.get("x-content-type-options") == "nosniff"
    assert coded("x", "y", 400, {}).text() == '{"error":"x","code":"y","params":{}}', "empty params are an object"
    assert coded("No icon", "icon_none", 404, None, {"cache-control": "private, max-age=3600"}).headers.get("cache-control") == "private, max-age=3600"


def test_an_error_inside_a_route_is_an_internal_error_that_says_nothing_more() -> None:
    routes = runlight({"sites": [{"id": "blog", "hostnames": ["blog.example.com"]}]}).routes({"token": None})
    with contextlib.redirect_stderr(io.StringIO()):
        # A broken escape in a path makes decodeURIComponent throw, as it does in TypeScript.
        answer = routes.handle(req("/runlight/api/goals/%E0%A4%A?site=blog", "DELETE"))
    assert answer.status == 500
    assert body(answer) == {"error": "Internal error", "code": "internal"}


def test_the_dashboard_shell_escapes_what_it_is_given() -> None:
    html = dashboard('/a"b', "share<", "/out?x=1&y=2", True, True, "/in")
    assert 'data-base="/a&#34;b"' in html
    assert 'data-share="share&#60;"' in html
    assert 'data-sign-out="/out?x=1&#38;y=2"' in html
    assert 'data-sign-in="/in" data-geo-credit="" data-accounts=""' in html
    assert "data-share" not in dashboard("/runlight")
