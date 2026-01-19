from fastapi import FastAPI
from app.api.routes import router
from app.core.config import settings

app = FastAPI(title="iSAMS Attendance Platform", version="0.1.0")

@app.get("/health")
async def health():
    return {"status": "ok", "env": settings.app_env}

app.include_router(router)

from app.api.isams_routes import router as isams_router
app.include_router(isams_router)
