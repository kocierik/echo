"""The one rate limiter of the API: budgets per API key, else per client IP.

Behind Cloudflare Tunnel every request reaches the API from the same address, so an IP
budget would be shared by every client. The key is a short SHA-256 prefix of the
X-API-Key header, so the raw key is never stored or logged by the limiter.
"""

import hashlib

from slowapi import Limiter
from slowapi.util import get_remote_address
from starlette.requests import Request

API_KEY_HEADER = "X-API-Key"


def rate_limit_key(request: Request) -> str:
    """`key:<sha256(X-API-Key)[:16]>` when the header is present, else the client IP."""
    api_key = request.headers.get(API_KEY_HEADER)
    if api_key:
        return "key:" + hashlib.sha256(api_key.encode()).hexdigest()[:16]
    return get_remote_address(request)


limiter = Limiter(key_func=rate_limit_key)
