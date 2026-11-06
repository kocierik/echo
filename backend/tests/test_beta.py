"""The website's beta form: each address is mailed to BETA_NOTIFY_EMAIL; nothing is kept, so a
failed mail is a failed request the visitor sees."""

import smtplib

import pytest

from app.core.config import settings
from app.routers import beta


@pytest.fixture
def mailed(monkeypatch):
    sent: list[str] = []
    monkeypatch.setattr(settings, "smtp_host", "smtp.example.com")
    monkeypatch.setattr(beta, "_send", sent.append)
    return sent


async def test_an_address_is_mailed(client, mailed):
    response = await client.post("/api/beta", json={"email": " Anna@Example.com "})

    assert response.status_code == 202
    assert mailed == ["anna@example.com"]


async def test_not_an_address_or_a_header_trick_is_refused(client, mailed):
    for email in ("anna", "a@b", "anna@example.com\r\nBcc: x@example.com"):
        assert (await client.post("/api/beta", json={"email": email})).status_code == 422
    assert mailed == []


async def test_no_mail_server_or_a_failed_mail_says_so(client, mailed, monkeypatch):
    monkeypatch.setattr(settings, "smtp_host", "")
    closed = await client.post("/api/beta", json={"email": "anna@example.com"})

    def refuse(_address):
        raise smtplib.SMTPException("down")

    monkeypatch.setattr(settings, "smtp_host", "smtp.example.com")
    monkeypatch.setattr(beta, "_send", refuse)
    failed = await client.post("/api/beta", json={"email": "anna@example.com"})

    assert (closed.status_code, failed.status_code) == (503, 503)


def test_the_message_goes_to_the_notify_address(monkeypatch):
    sent = []

    class _Smtp:
        def __init__(self, host, port, timeout):
            assert (host, port) == ("smtp.example.com", 465)

        def __enter__(self):
            return self

        def __exit__(self, *_):
            return False

        def login(self, user, password):
            pass

        def send_message(self, message):
            sent.append(message)

    monkeypatch.setattr(settings, "smtp_host", "smtp.example.com")
    monkeypatch.setattr(settings, "smtp_user", "echo@example.com")
    monkeypatch.setattr(beta.smtplib, "SMTP_SSL", _Smtp)

    beta._send("anna@example.com")

    assert sent[0]["To"] == settings.beta_notify_email == "erik@man.ovh"
    assert sent[0]["Reply-To"] == "anna@example.com"
    assert "anna@example.com" in sent[0].get_content()
