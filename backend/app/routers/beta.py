"""The website's beta form (site/index.html): each address is mailed to BETA_NOTIFY_EMAIL over
SMTP. Nothing is stored, so a mail that fails is an error the visitor sees and can retry."""

import asyncio
import logging
import smtplib
from email.message import EmailMessage

from fastapi import APIRouter, HTTPException, Request, status
from pydantic import BaseModel, Field

from app.core.config import settings
from app.core.rate_limit import limiter
from app.services.passwords import normalize_email

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/beta", tags=["beta"])

NOT_OPEN = "The beta list is not open yet."


class BetaIn(BaseModel):
    # No whitespace anywhere: the address goes into a Reply-To header
    email: str = Field(max_length=320, pattern=r"^\s*[^@\s]+@[^@\s]+\.[^@\s]+\s*$")


def _send(address: str) -> None:
    message = EmailMessage()
    message["Subject"] = f"Echo beta: {address}"
    message["From"] = settings.smtp_from or settings.smtp_user
    message["To"] = settings.beta_notify_email
    message["Reply-To"] = address
    message.set_content(f"{address} asked to join the Echo beta from echo.man.ovh.\n")
    if settings.smtp_port == 465:
        server = smtplib.SMTP_SSL(settings.smtp_host, settings.smtp_port, timeout=15)
    else:
        server = smtplib.SMTP(settings.smtp_host, settings.smtp_port, timeout=15)
    with server:
        if settings.smtp_port != 465:
            server.starttls()
        if settings.smtp_user:
            server.login(settings.smtp_user, settings.smtp_password)
        server.send_message(message)


@router.post("", status_code=status.HTTP_202_ACCEPTED)
@limiter.limit("5/minute")
async def join(request: Request, body: BetaIn):
    if not settings.smtp_host:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=NOT_OPEN)
    try:
        await asyncio.to_thread(_send, normalize_email(body.email))
    except (smtplib.SMTPException, OSError) as exc:
        logger.warning("Beta mail not sent: %s", exc)
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=NOT_OPEN)
    return {}
