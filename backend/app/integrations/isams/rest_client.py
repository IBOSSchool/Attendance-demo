"""
REST API client placeholder.

Phase 0: scaffold only.
Next phases:
- implement authentication/token flow for your iSAMS REST API
- implement Student Registers read/write operations
"""
from app.core.config import settings

class IsamsRestClient:
    def __init__(self) -> None:
        self.base_url = f"https://{settings.isams_host}".rstrip("/")

    async def ping(self) -> dict:
        return {"ok": True, "mode": "rest", "host": settings.isams_host}
