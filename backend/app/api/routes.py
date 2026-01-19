from fastapi import APIRouter

router = APIRouter()

@router.get("/classes")
async def list_classes():
    # Phase 0: placeholder. Will be backed by Teaching Sets / Timetable in Phase 1.
    return {"items": [], "note": "Phase 0 placeholder. iSAMS integration will be added in Phase 1."}
