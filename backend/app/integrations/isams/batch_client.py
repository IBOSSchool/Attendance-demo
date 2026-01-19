"""
Batch API client placeholder.

Phase 1 focus:
- Wire credentials from env (Client ID/Secret)
- Keep request building minimal until we confirm the exact Batch endpoints used in your iSAMS instance
"""

import base64
from app.core.config import settings

class IsamsBatchClient:
    def __init__(self) -> None:
        self.host = settings.isams_host
        self.client_id = settings.isams_batch_client_id
        self.client_secret = settings.isams_batch_client_secret
        self.timeout = getattr(settings, "isams_timeout_seconds", 30)
        self.verify_ssl = getattr(settings, "isams_verify_ssl", True)

    def basic_auth_header(self) -> str:
        """
        Many iSAMS Batch integrations use Client ID + Client Secret as credentials.
        This method prepares an HTTP Basic Authorization header value.
        Adjust if your iSAMS Batch gateway expects a different auth mechanism.
        """
        raw = f"{self.client_id}:{self.client_secret}".encode("utf-8")
        return "Basic " + base64.b64encode(raw).decode("ascii")

    async def ping(self) -> dict:
        # Placeholder: we only confirm that env wiring is correct.
        return {
            "ok": True,
            "host": self.host,
            "client_id_set": bool(self.client_id),
            "client_secret_set": bool(self.client_secret),
        }
