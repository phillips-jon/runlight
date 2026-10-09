"""Ports mail.test.ts, and replays tests/fixtures/outbound.json: every service sends the TypeScript SDK's exact
requests."""

from __future__ import annotations

import base64
import re
import socket
import time
from datetime import datetime, timezone

import pytest
from support import fixtures
from support.fake_fetcher import FakeFetcher
from support.smtp_server import SmtpServer

from runlight import _js
from runlight.http import FetchError, Response, SearchParams
from runlight.mail import SERVICES, MailError, mime, seal, send, service_message, sign_v4, smtp_send, unseal

MESSAGE = {
    "to": "jon@example.com",
    "from": "reports@example.com",
    "fromName": "Runlight",
    "subject": "Hello",
    "html": "<p>Hi</p>",
    "text": "Hi",
    "headers": {"List-Unsubscribe": "<https://x/u>"},
}


def fixture():
    return fixtures.load("outbound")


def capture(status: int = 200) -> FakeFetcher:
    return FakeFetcher(lambda url, init: Response("{}" if status == 200 else "nope", status))


def uuids():
    """A UUID stand-in that counts from 1, as the fixture script's does."""
    n = 0

    def next_uuid() -> str:
        nonlocal n
        n += 1
        return f"00000000-0000-4000-8000-{n:012d}"

    return next_uuid


def failure(error: MailError) -> dict:
    return {"message": error.message, "code": error.code, "params": error.params}


def test_sealed_keys_open_only_with_the_same_secret():
    sealed = seal('{"apiKey":"re_123"}', "server secret")
    assert sealed.startswith("v1:") and "re_123" not in sealed
    assert unseal(sealed, "server secret") == '{"apiKey":"re_123"}'
    assert unseal(sealed, "another secret") is None
    assert unseal(seal("x", None), None) == "x", "with no secret the value is kept as typed"
    assert unseal("v1:AAAA:AAAA", "server secret") is None, "damaged"
    assert unseal("v2:a:b", "server secret") is None
    assert unseal(sealed, None) is None


def test_keys_sealed_by_typescript_open_here():
    for case in fixture()["sealed"]:
        assert unseal(case["sealed"], case["secret"]) == case["value"]
        assert unseal(case["sealed"], f"{case['secret']}!") is None
        assert unseal(seal(case["value"], case["secret"]), case["secret"]) == case["value"]


def test_sig_v4_matches_aws_published_example():
    # https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html (the IAM ListUsers example)
    headers = sign_v4({
        "method": "GET",
        "url": "https://iam.amazonaws.com/?Action=ListUsers&Version=2010-05-08",
        "body": "",
        "region": "us-east-1",
        "service": "iam",
        "accessKeyId": "AKIDEXAMPLE",
        "secretAccessKey": "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        "now": int(datetime(2015, 8, 30, 12, 36, tzinfo=timezone.utc).timestamp()) * 1000,
        "headers": {"content-type": "application/x-www-form-urlencoded; charset=utf-8"},
    })  # fmt: skip
    assert headers["authorization"] == (
        "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/iam/aws4_request, SignedHeaders=content-type;host;x-amz-date, "
        "Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7"
    )


def test_sig_v4_matches_typescript():
    for case in fixture()["signatures"]:
        signed = sign_v4(case["input"])
        assert signed == case["headers"], case["input"]["url"]
        assert list(signed) == list(case["headers"]), "in the same order"


def test_each_service_gets_the_request_it_documents():
    calls = capture()
    send({"service": "resend", "apiKey": "re_1"}, MESSAGE, calls)
    assert calls.requests[0]["url"] == "https://api.resend.com/emails"
    assert calls.requests[0]["headers"]["authorization"] == "Bearer re_1"
    assert _js.loads(calls.requests[0]["body"])["to"] == ["jon@example.com"]
    assert _js.loads(calls.requests[0]["body"])["from"] == "Runlight <reports@example.com>"

    calls = capture()
    send({"service": "postmark", "serverToken": "pm"}, MESSAGE, calls)
    assert calls.requests[0]["headers"]["x-postmark-server-token"] == "pm"
    assert _js.loads(calls.requests[0]["body"])["MessageStream"] == "outbound"

    calls = capture()
    send({"service": "mailgun", "apiKey": "key", "domain": "mg.example.com", "region": "eu"}, MESSAGE, calls)
    assert calls.requests[0]["url"] == "https://api.eu.mailgun.net/v3/mg.example.com/messages"
    assert calls.requests[0]["headers"]["authorization"] == "Basic " + base64.b64encode(b"api:key").decode()
    assert SearchParams(calls.requests[0]["body"]).get("h:List-Unsubscribe") == "<https://x/u>"

    calls = capture()
    send({"service": "ses", "region": "eu-west-1", "accessKeyId": "AKID", "secretAccessKey": "secret"}, MESSAGE, calls)
    assert calls.requests[0]["url"] == "https://email.eu-west-1.amazonaws.com/v2/email/outbound-emails"
    assert re.match(r"AWS4-HMAC-SHA256 Credential=AKID/\d{8}/eu-west-1/ses/aws4_request", calls.requests[0]["headers"]["authorization"])

    calls = capture()
    send({"service": "webhook", "url": "https://hooks.example.com/mail", "secret": "s"}, MESSAGE, calls)
    assert re.fullmatch(r"sha256=[a-f0-9]{64}", calls.requests[0]["headers"]["x-runlight-signature"])

    refused = capture(401)
    with pytest.raises(MailError, match="api.sendgrid.com answered 401"):
        send({"service": "sendgrid", "apiKey": "bad"}, MESSAGE, refused)
    with pytest.raises(MailError, match="must use https"):
        send({"service": "webhook", "url": "http://example.com/x"}, MESSAGE, refused)
    with pytest.raises(MailError, match="Enter the api key"):
        send({"service": "resend"}, MESSAGE, refused)


def test_every_service_sends_the_typescript_requests_exactly():
    now = fixture()["now"]
    for i, case in enumerate(fixture()["mail"]):
        answer = case["answer"]

        def reply(url, init, answer=answer):
            if answer == "unreachable":
                raise FetchError("fetch failed")
            return Response(answer["body"], answer["status"])

        fetcher = FakeFetcher(reply)
        error = None
        try:
            send(case["config"], case["message"], fetcher, now)
        except MailError as e:
            error = failure(e)
        label = f"case {i}: {_js.dumps(case['config'])}"
        assert fetcher.requests == case["requests"], label
        assert error == case["error"], label


def test_service_messages_match_typescript():
    for case in fixture()["replies"]:
        assert service_message(case["reply"]) == case["message"], case["reply"]


def test_mime_matches_typescript():
    for case in fixture()["mimes"]:
        assert mime(case["message"], case["from"], case["now"], uuids()) == case["mime"]
    raw = mime({**MESSAGE, "subject": "Café report"}, "Runlight <reports@example.com>")
    assert re.search(r"Subject: =\?UTF-8\?B\?", raw)
    assert re.search(r'boundary="rl-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"', raw)


@pytest.fixture
def server():
    started = SmtpServer()
    yield started
    started.stop()


def test_smtp_sends_the_typescript_conversation(server):
    for case in fixture()["smtp"]:
        error = None
        config = {**case["config"], "service": "smtp", "host": "127.0.0.1", "port": str(server.port)}
        try:
            smtp_send(config, case["message"], case["from"], 60_000, fixture()["now"], uuids())
        except MailError as e:
            error = failure(e)
        assert error == case["error"]
        assert (server.conversation() or {}).get("received") == case["received"]


def test_smtp_starttls_refused_is_an_error_and_a_plain_relay_takes_the_message(server):
    config = {"service": "smtp", "host": "127.0.0.1", "port": str(server.port)}
    with pytest.raises(MailError, match="does not offer STARTTLS"):
        smtp_send({**config, "security": "starttls"}, MESSAGE, "reports@example.com")
    server.conversation()
    smtp_send({**config, "security": "none", "username": "jon", "password": "pw"}, {**MESSAGE, "text": ".starts with a dot"}, "Runlight <reports@example.com>")
    received = server.conversation()["received"]
    seen = []
    in_data = False
    data = ""
    for line in received.split("\r\n"):
        if in_data:
            if line == ".":
                in_data = False
            else:
                data += f"{line}\n"
            continue
        if line:
            seen.append(line.split(" ")[0])
        in_data = line == "DATA"
    assert seen == ["EHLO", "AUTH", "MAIL", "RCPT", "DATA", "QUIT"]
    assert re.search("Subject: Hello", data)
    assert re.search("List-Unsubscribe: <https://x/u>", data)
    assert re.search("multipart/alternative", data)


def test_smtp_through_transports_sends_too(server):
    send({"service": "smtp", "host": "127.0.0.1", "port": str(server.port), "security": "none"}, MESSAGE)
    assert "From: Runlight <reports@example.com>\r\n" in server.conversation()["received"]


def test_smtp_server_that_trickles_is_cut_off_at_the_deadline():
    server = SmtpServer("trickle")
    try:
        started = time.monotonic()
        with pytest.raises(MailError) as caught:
            smtp_send({"service": "smtp", "host": "127.0.0.1", "port": str(server.port), "security": "none"}, MESSAGE, "reports@example.com", 600)
        error = caught.value
        assert error.code == "mail_slow", error.message
        assert error.params == {"host": f"127.0.0.1:{server.port}"}
        assert error.message == f"SMTP: 127.0.0.1:{server.port} took longer than 1 s"
        assert time.monotonic() - started < 2, "the send gives up at its deadline"
        assert (server.conversation(2) or {}).get("closed"), "the connection is closed"
    finally:
        server.stop()


def test_smtp_that_cannot_connect_says_so():
    # A port that was free a moment ago.
    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()
    with pytest.raises(MailError) as caught:
        smtp_send({"service": "smtp", "host": "127.0.0.1", "port": str(port), "security": "none"}, MESSAGE, "reports@example.com")
    error = caught.value
    assert error.code == "mail_unreachable"
    assert error.params["host"] == f"127.0.0.1:{port}"
    assert error.message.startswith(f"SMTP: could not connect to 127.0.0.1:{port}: ")
    assert error.params["detail"] == f"connect ECONNREFUSED 127.0.0.1:{port}", "Node's words"


def test_errors_carry_codes_and_params():
    error = MailError("Something")
    assert error.code == "mail_failed"
    assert error.params == {"detail": "Something"}
    assert SERVICES[0]["id"] == "ses"
