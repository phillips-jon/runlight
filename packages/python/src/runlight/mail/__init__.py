"""Mail: the services Runlight sends through, SES's signature, SMTP, and the sealed keys they use."""

from .secret import seal, unseal
from .ses import ses_send, sign_v4
from .smtp import mime, smtp_send
from .transports import SERVICES, MailError, address, check_config, send, service_message

__all__ = [
    "SERVICES",
    "MailError",
    "address",
    "check_config",
    "mime",
    "seal",
    "send",
    "service_message",
    "ses_send",
    "sign_v4",
    "smtp_send",
    "unseal",
]
