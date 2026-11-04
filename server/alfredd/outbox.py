"""Outbound-email approval gate.

The brain (alfred-brain, running unattended as root on this box) can only
create drafts via POST /outbox. Only the owner, acting through the app, can
approve one; approval and rejection are never exposed through the `alfred`
CLI used by the brain.

Code-enforced guardrail (not a security boundary; a root process on this
box could still curl 127.0.0.1 with a forged header, or read the token and
hit the public route itself; this only stops the brain's *normal* tool path,
which is a local, header-less curl against 10.66.66.1/127.0.0.1):

    POST /outbox/{id}/approve only succeeds if the request either carries
    `X-Alfred-Route: public` (set by the reverse proxy on the public mTLS
    route, per PROTOCOL.md's X-Helm-Route precedent) or arrives from a wg0
    client IP that is neither 127.0.0.1 nor 10.66.66.1 (i.e. not the box
    talking to itself). A local curl from alfred-brain satisfies neither and
    gets 403.

Sending uses Gmail SMTP (smtp.gmail.com:465) with the App Password from the
vault item "Google - Gmail App Password" (username/From: ennyolutogun@gmail.com,
fetched fresh via `bw-get` each send, never cached to disk). Per CLAUDE.md,
the From address is always ennyolutogun@gmail.com, never work@supercriticalbooks.com.
"""
import smtplib
import subprocess
from email.mime.application import MIMEApplication
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from pathlib import Path
from typing import Optional

from fastapi import HTTPException, Request

GMAIL_FROM = "ennyolutogun@gmail.com"
GMAIL_VAULT_ITEM = "Google - Gmail App Password"
SELF_IPS = {"127.0.0.1", "10.66.66.1", "::1"}


def check_approval_allowed(request: Request) -> None:
    """Raises 403 unless the request is on the public route or from a wg0
    client other than the box itself."""
    route = request.headers.get("x-alfred-route")
    if route == "public":
        return
    client_host = request.client.host if request.client else None
    if client_host and client_host not in SELF_IPS:
        return
    raise HTTPException(403, "outbox approval must come from the app (public route or a "
                              "remote wg0 client), not a local request")


def _gmail_app_password() -> str:
    try:
        out = subprocess.run(["bw-get", GMAIL_VAULT_ITEM], capture_output=True,
                              text=True, timeout=30, check=True)
    except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired) as e:
        raise RuntimeError(f"could not fetch Gmail app password from vault: {e}")
    pw = out.stdout.strip()
    if not pw:
        raise RuntimeError("vault returned an empty Gmail app password")
    return pw


def send_email(to: str, subject: str, body: str, attachments: Optional[list] = None) -> None:
    msg = MIMEMultipart()
    msg["From"] = GMAIL_FROM
    msg["To"] = to
    msg["Subject"] = subject
    msg.attach(MIMEText(body, "plain"))

    for path_str in attachments or []:
        p = Path(path_str)
        if not p.is_file():
            continue
        part = MIMEApplication(p.read_bytes(), Name=p.name)
        part["Content-Disposition"] = f'attachment; filename="{p.name}"'
        msg.attach(part)

    password = _gmail_app_password()
    with smtplib.SMTP_SSL("smtp.gmail.com", 465, timeout=30) as smtp:
        smtp.login(GMAIL_FROM, password)
        smtp.sendmail(GMAIL_FROM, [to], msg.as_string())
