from fastapi import APIRouter
from app.core.config import settings
from app.integrations.isams.batch_client import IsamsBatchClient

router = APIRouter(prefix="/isams", tags=["isams"])

@router.get("/smoke")
async def smoke():
    """
    Phase 1 smoke test:
    - Confirm env variables are loaded
    - Confirm Batch client wiring is OK
    """
    client = IsamsBatchClient()
    batch_ping = await client.ping()

    return {
        "isams_host": settings.isams_host,
        "batch": batch_ping,
        "rest": {
            "rest_client_id_set": bool(getattr(settings, "isams_rest_client_id", "")),
            "token_url_set": bool(getattr(settings, "isams_token_url", "")),
            "rest_base_set": bool(getattr(settings, "isams_rest_api_base_url", "")),
        },
    }
