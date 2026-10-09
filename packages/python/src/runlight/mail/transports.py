"""Sends mail through the service a site picked.

A message is a dict shaped as TS's Message: `to`, `from`, `fromName` (optional), `subject`, `html`, `text`, and
`headers` (optional extra headers, such as List-Unsubscribe). A config is `service` plus its fields, every value
a string, as typed in the dashboard.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import re
from typing import Any

from .. import _js
from ..http import Fetcher, FetchError, SearchParams, Url, UrllibFetcher


class MailError(Exception):
    """A mail problem to show the person setting it up. `code` and `params` let the dashboard say it in
    its own language; a service's own words, which only it can give, travel in `params.detail`."""

    def __init__(self, message: str, code: str = "mail_failed", params: dict[str, str] | None = None) -> None:
        super().__init__(message)
        self.message = message
        self.code = code
        self.params = {"detail": message} if params is None else params


# Every service Runlight can send through, and what each needs.
SERVICES: list[dict[str, Any]] = [
    {"id": "ses", "name": "Amazon SES", "fields": [
        {"name": "region", "label": "Region", "placeholder": "us-east-1"},
        {"name": "accessKeyId", "label": "Access key ID"},
        {"name": "secretAccessKey", "label": "Secret access key", "secret": True},
    ]},
    {"id": "resend", "name": "Resend", "fields": [{"name": "apiKey", "label": "API key", "secret": True, "placeholder": "re_..."}]},
    {"id": "postmark", "name": "Postmark", "fields": [
        {"name": "serverToken", "label": "Server API token", "secret": True},
        {"name": "stream", "label": "Message stream", "optional": True, "placeholder": "outbound"},
    ]},
    {"id": "sendgrid", "name": "SendGrid", "fields": [{"name": "apiKey", "label": "API key", "secret": True, "placeholder": "SG...."}]},
    {"id": "mailgun", "name": "Mailgun", "fields": [
        {"name": "domain", "label": "Sending domain", "placeholder": "mg.example.com"},
        {"name": "apiKey", "label": "API key", "secret": True},
        {"name": "region", "label": "Region", "options": ["us", "eu"]},
    ]},
    {"id": "brevo", "name": "Brevo", "fields": [{"name": "apiKey", "label": "API key", "secret": True, "placeholder": "xkeysib-..."}]},
    {"id": "mailjet", "name": "Mailjet", "fields": [
        {"name": "apiKey", "label": "API key"},
        {"name": "secretKey", "label": "Secret key", "secret": True},
    ]},
    {"id": "mailersend", "name": "MailerSend", "fields": [{"name": "apiKey", "label": "API token", "secret": True, "placeholder": "mlsn...."}]},
    {"id": "sparkpost", "name": "SparkPost", "fields": [
        {"name": "apiKey", "label": "API key", "secret": True},
        {"name": "region", "label": "Region", "options": ["us", "eu"]},
    ]},
    {"id": "smtp", "name": "SMTP", "fields": [
        {"name": "host", "label": "Host", "placeholder": "smtp.example.com"},
        {"name": "port", "label": "Port", "placeholder": "587"},
        {"name": "security", "label": "Security", "options": ["starttls", "tls", "none"]},
        {"name": "username", "label": "Username", "optional": True},
        {"name": "password", "label": "Password", "secret": True, "optional": True},
    ]},
    {"id": "webhook", "name": "Webhook", "fields": [
        {"name": "url", "label": "URL", "placeholder": "https://example.com/hooks/mail"},
        {"name": "secret", "label": "Signing secret", "secret": True, "optional": True},
    ]},
]  # fmt: skip


_NOT_IN_NAME = re.compile('["\\\\\r\n]')


def address(m: dict[str, Any]) -> str:
    name = m.get("fromName")
    return f"{_NOT_IN_NAME.sub('', name)} <{m['from']}>" if name else m["from"]


_XML_MESSAGE = re.compile(r"<Message>([^<]{1,200})</Message>")


def service_message(reply: str) -> str:
    """The error a mail service explains itself with, from its JSON or XML reply,
    and never the raw body: a reply is shown to the dashboard, so an address
    that is not a mail service must not be able to put its page there."""
    ok, parsed = _js.try_loads(reply)
    # JSON.parse fails, or reading a field of null does, and either way the XML form is tried.
    if not ok or parsed is None:
        found = _XML_MESSAGE.search(reply)
        return _js.trim(found.group(1)) if found else ""

    def first(v: Any) -> str:
        if isinstance(v, str):
            return v
        if isinstance(v, list):
            return first(v[0] if v else None)
        if isinstance(v, dict):
            return first(v.get("message"))
        return ""

    if not isinstance(parsed, dict):
        return ""
    for name in ("message", "Message", "error", "errors", "ErrorMessage"):
        text = first(parsed.get(name))
        if text:
            # The first 200 UTF-16 units, as slice() counts them.
            return _js.cut(text, 200)
    return ""


def _post(fetcher: Fetcher, url: str, init: dict[str, Any], explains: bool = True) -> None:
    try:
        response = fetcher.fetch(url, {"method": "POST", "headers": init["headers"], "body": init["body"], "timeoutMs": 20_000})
    except FetchError as error:
        host = Url(url).host
        raise MailError(f"Could not reach {host}: {error}", "mail_unreachable", {"host": host, "detail": str(error)}) from None
    if response.ok:
        return
    try:
        text = response.text() if explains else ""
    except Exception:
        text = ""
    message = service_message(text) if explains else ""
    host = Url(url).host
    status = response.status
    raise MailError(
        f"{host} answered {status}{f': {message}' if message else ''}",
        "mail_refused",
        {"host": host, "detail": f"{status}{f' {message}' if message else ''}"},
    )


def _json(headers: dict[str, str] | None = None) -> dict[str, str]:
    return {"content-type": "application/json", **(headers or {})}


def _basic(user: str, password: str) -> str:
    # btoa() takes Latin-1 text only, and throws past U+00FF, as encode() raises here.
    return "Basic " + base64.b64encode(f"{user}:{password}".encode("latin-1")).decode("ascii")


def _hmac_hex(secret: str, body: str) -> str:
    return hmac.new(_js.encode(secret), _js.encode(body), hashlib.sha256).hexdigest()


def check_config(config: dict[str, Any]) -> None:
    """Checks a config has what its service needs, before anything is saved or sent."""
    service = next((s for s in SERVICES if s["id"] == config.get("service")), None)
    if service is None:
        raise MailError("Pick a mail service", "mail_service", {})
    for f in service["fields"]:
        value = config.get(f["name"])
        if not f.get("optional") and not (isinstance(value, str) and _js.trim(value)):
            raise MailError(f"Enter the {f['label'].lower()}", "mail_field", {"field": f["name"]})
        if f.get("options") and value and value not in f["options"]:
            options = ", ".join(f["options"])
            raise MailError(f"{f['label']} must be one of {options}", "mail_option", {"field": f["name"], "options": options})
    url = config.get("url") or ""
    if config["service"] == "webhook" and not re.match(r"https://", url) and not re.match(r"http://(localhost|127\.0\.0\.1)(:\d+)?(/|\Z)", url, re.ASCII):
        raise MailError("The webhook URL must use https", "mail_https", {})


def send(config: dict[str, Any], m: dict[str, Any], fetcher: Fetcher | None = None, now: int | None = None) -> None:
    """Sends one message through the configured service. `now` (milliseconds) is for SES's signature; the clock
    when None."""
    check_config(config)
    fetcher = fetcher or UrllibFetcher()
    headers: dict[str, str] = m.get("headers") or {}
    named = bool(m.get("fromName"))
    service = config["service"]
    if service == "resend":
        return _post(fetcher, "https://api.resend.com/emails", {
            "headers": _json({"authorization": f"Bearer {config['apiKey']}"}),
            "body": _js.dumps({"from": address(m), "to": [m["to"]], "subject": m["subject"], "html": m["html"], "text": m["text"], "headers": headers}),
        })  # fmt: skip
    if service == "postmark":
        return _post(fetcher, "https://api.postmarkapp.com/email", {
            "headers": _json({"accept": "application/json", "x-postmark-server-token": config["serverToken"]}),
            "body": _js.dumps({
                "From": address(m), "To": m["to"], "Subject": m["subject"], "HtmlBody": m["html"], "TextBody": m["text"],
                "MessageStream": config.get("stream") or "outbound",
                "Headers": [{"Name": k, "Value": v} for k, v in headers.items()],
            }),
        })  # fmt: skip
    if service == "sendgrid":
        return _post(fetcher, "https://api.sendgrid.com/v3/mail/send", {
            "headers": _json({"authorization": f"Bearer {config['apiKey']}"}),
            "body": _js.dumps({
                "personalizations": [{"to": [{"email": m["to"]}]}],
                "from": {"email": m["from"], **({"name": m["fromName"]} if named else {})},
                "subject": m["subject"],
                "content": [{"type": "text/plain", "value": m["text"]}, {"type": "text/html", "value": m["html"]}],
                "headers": headers,
            }),
        })  # fmt: skip
    if service == "mailgun":
        form = SearchParams({"from": address(m), "to": m["to"], "subject": m["subject"], "html": m["html"], "text": m["text"]})
        for k, v in headers.items():
            form.set(f"h:{k}", v)
        host = "api.eu.mailgun.net" if config.get("region") == "eu" else "api.mailgun.net"
        return _post(fetcher, f"https://{host}/v3/{_js.encode_uri_component(config['domain'])}/messages", {
            "headers": {"authorization": _basic("api", config["apiKey"]), "content-type": "application/x-www-form-urlencoded"},
            "body": form.to_string(),
        })  # fmt: skip
    if service == "brevo":
        return _post(fetcher, "https://api.brevo.com/v3/smtp/email", {
            "headers": _json({"api-key": config["apiKey"], "accept": "application/json"}),
            "body": _js.dumps({
                "sender": {"email": m["from"], **({"name": m["fromName"]} if named else {})}, "to": [{"email": m["to"]}],
                "subject": m["subject"], "htmlContent": m["html"], "textContent": m["text"], "headers": headers,
            }),
        })  # fmt: skip
    if service == "mailjet":
        return _post(fetcher, "https://api.mailjet.com/v3.1/send", {
            "headers": _json({"authorization": _basic(config["apiKey"], config["secretKey"])}),
            "body": _js.dumps({
                "Messages": [{
                    "From": {"Email": m["from"], **({"Name": m["fromName"]} if named else {})}, "To": [{"Email": m["to"]}],
                    "Subject": m["subject"], "TextPart": m["text"], "HTMLPart": m["html"], "Headers": headers,
                }],
            }),
        })  # fmt: skip
    if service == "mailersend":
        return _post(fetcher, "https://api.mailersend.com/v1/email", {
            "headers": _json({"authorization": f"Bearer {config['apiKey']}"}),
            "body": _js.dumps({
                "from": {"email": m["from"], **({"name": m["fromName"]} if named else {})}, "to": [{"email": m["to"]}],
                "subject": m["subject"], "html": m["html"], "text": m["text"],
                **({"headers": [{"name": k, "value": v} for k, v in headers.items()]} if headers else {}),
            }),
        })  # fmt: skip
    if service == "sparkpost":
        host = "api.eu.sparkpost.com" if config.get("region") == "eu" else "api.sparkpost.com"
        return _post(fetcher, f"https://{host}/api/v1/transmissions", {
            "headers": _json({"authorization": config["apiKey"]}),
            "body": _js.dumps({
                "recipients": [{"address": {"email": m["to"]}}],
                "content": {
                    "from": {"email": m["from"], "name": m["fromName"]} if named else m["from"],
                    "subject": m["subject"], "html": m["html"], "text": m["text"], "headers": headers,
                },
            }),
        })  # fmt: skip
    if service == "ses":
        from .ses import ses_send

        return ses_send(config, m, address(m), fetcher, now)
    if service == "smtp":
        from .smtp import smtp_send

        return smtp_send(config, m, address(m))
    if service == "webhook":
        body = _js.dumps({
            "to": m["to"], "from": m["from"], "fromName": m.get("fromName") or "",
            "subject": m["subject"], "html": m["html"], "text": m["text"], "headers": headers,
        })  # fmt: skip
        signature = {"x-runlight-signature": f"sha256={_hmac_hex(config['secret'], body)}"} if config.get("secret") else {}
        # A webhook can be any address, so only its status comes back.
        return _post(fetcher, config["url"], {"headers": _json(signature), "body": body}, False)
    raise MailError(f'Unknown mail service "{service}"', "mail_service", {})
