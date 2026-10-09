"""Amazon SES (API v2) with a hand-rolled Signature Version 4, so there is no
AWS SDK to install. https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html
"""

from __future__ import annotations

import hashlib
import hmac
import re
import time
from datetime import datetime, timezone
from typing import Any

from .. import _js
from ..http import Fetcher, FetchError, Url, UrllibFetcher
from .transports import MailError, service_message


def _sha256(text: str) -> str:
    return hashlib.sha256(_js.encode(text)).hexdigest()


def _hmac(key: bytes, text: str) -> bytes:
    return hmac.new(key, _js.encode(text), hashlib.sha256).digest()


def _path_part(part: str) -> str:
    decoded = _js.decode_uri_component(part)
    if decoded is None:
        # decodeURIComponent throws a URIError here in TypeScript.
        raise ValueError("URI malformed")
    return _js.encode_uri_component(decoded)


def sign_v4(input: dict[str, Any]) -> dict[str, str]:  # noqa: A002
    """Signs a request; public for its test against AWS's published example. `input` has method, url (text or a
    Url), body, region, service, accessKeyId, secretAccessKey, now (milliseconds), and headers."""
    url = input["url"] if isinstance(input["url"], Url) else Url(input["url"])
    moment = datetime.fromtimestamp(input["now"] // 1000, tz=timezone.utc)
    amz_date = moment.strftime("%Y%m%dT%H%M%SZ")
    day = amz_date[:8]
    payload_hash = _sha256(input["body"])
    headers: dict[str, str] = {**input["headers"], "host": url.host, "x-amz-date": amz_date}
    names = sorted((h.lower() for h in headers), key=_js.order_key)
    lower = {k.lower(): _js.SPACES.sub(" ", _js.trim(v)) for k, v in headers.items()}
    # A stable sort on the name alone, as Array.prototype.sort is.
    pairs = sorted(url.search_params.items(), key=lambda pair: _js.order_key(pair[0]))
    canonical = "\n".join([
        input["method"],
        "/".join(_path_part(p) for p in url.pathname.split("/")) or "/",
        "&".join(f"{_js.encode_uri_component(k)}={_js.encode_uri_component(v)}" for k, v in pairs),
        "".join(f"{n}:{lower[n]}\n" for n in names),
        ";".join(names),
        payload_hash,
    ])  # fmt: skip
    scope = f"{day}/{input['region']}/{input['service']}/aws4_request"
    to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope, _sha256(canonical)])
    key = _hmac(_js.encode(f"AWS4{input['secretAccessKey']}"), day)
    key = _hmac(key, input["region"])
    key = _hmac(key, input["service"])
    key = _hmac(key, "aws4_request")
    signature = _hmac(key, to_sign).hex()
    return {
        **headers,
        "authorization": f"AWS4-HMAC-SHA256 Credential={input['accessKeyId']}/{scope}, SignedHeaders={';'.join(names)}, Signature={signature}",
    }


_REGION = re.compile(r"[a-z]{2}(-[a-z]+)+-[0-9]\Z")


def ses_send(config: dict[str, Any], m: dict[str, Any], from_: str, fetcher: Fetcher | None = None, now: int | None = None) -> None:
    """Sends through SES. `now` is in milliseconds; the clock when None."""
    region = _js.trim(config["region"])
    if not _REGION.match(region):
        raise MailError("That is not an AWS region, like us-east-1", "mail_region", {})
    url = Url(f"https://email.{region}.amazonaws.com/v2/email/outbound-emails")
    body = _js.dumps({
        "FromEmailAddress": from_,
        "Destination": {"ToAddresses": [m["to"]]},
        "Content": {
            "Simple": {
                "Subject": {"Data": m["subject"], "Charset": "UTF-8"},
                "Body": {"Html": {"Data": m["html"], "Charset": "UTF-8"}, "Text": {"Data": m["text"], "Charset": "UTF-8"}},
                "Headers": [{"Name": k, "Value": v} for k, v in (m.get("headers") or {}).items()],
            },
        },
    })  # fmt: skip
    headers = sign_v4({
        "method": "POST",
        "url": url,
        "body": body,
        "region": region,
        "service": "ses",
        "accessKeyId": _js.trim(config["accessKeyId"]),
        "secretAccessKey": _js.trim(config["secretAccessKey"]),
        "now": int(time.time() * 1000) if now is None else now,
        "headers": {"content-type": "application/json"},
    })  # fmt: skip
    del headers["host"]
    try:
        response = (fetcher or UrllibFetcher()).fetch(url.href, {"method": "POST", "headers": headers, "body": body, "timeoutMs": 20_000})
    except FetchError as error:
        raise MailError(f"Could not reach Amazon SES: {error}", "mail_unreachable", {"host": "Amazon SES", "detail": str(error)}) from None
    if not response.ok:
        try:
            text = response.text()
        except Exception:
            text = ""
        message = service_message(text)
        status = response.status
        raise MailError(
            f"Amazon SES answered {status}{f': {message}' if message else ''}",
            "mail_refused",
            {"host": "Amazon SES", "detail": f"{status}{f' {message}' if message else ''}"},
        )
