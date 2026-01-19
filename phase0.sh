#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${1:-isams-attendance-platform}"

detect_compose() {
  if command -v docker >/dev/null 2>&1; then
    if docker compose version >/dev/null 2>&1; then
      echo "docker compose"
      return
    fi
    if command -v docker-compose >/dev/null 2>&1; then
      echo "docker-compose"
      return
    fi
  fi

  if command -v podman >/dev/null 2>&1; then
    if podman compose version >/dev/null 2>&1; then
      echo "podman compose"
      return
    fi
  fi

  echo ""
}

COMPOSE_CMD="$(detect_compose)"

echo "== Phase 0 bootstrap =="
echo "Project dir: ${PROJECT_DIR}"

if [ -z "${COMPOSE_CMD}" ]; then
  echo "ERROR: docker compose / docker-compose / podman compose not found."
  echo "Install Docker (recommended) or Podman, then re-run."
  exit 1
fi

mkdir -p "${PROJECT_DIR}"/{backend/app/{api,core,integrations/isams},docs,scripts}
cd "${PROJECT_DIR}"

# -------------------------
# TODO.md (English)
# -------------------------
cat > TODO.md <<'EOF'
# iSAMS Attendance & Parent Notification Platform

## Goal
Build an admin platform that:
- Pulls attendance/register data from iSAMS (read + write where allowed)
- Identifies absentees (daily + date-range filters)
- Notifies parents/guardians via SMS/email
- Tracks delivery status + audit logs
- Provides an admin panel for operations

## What “My Classes” Means (Data Model)
- Teaching Sets / Teaching Groups (who teaches what)
- Timetable Events (what happens today/this week)
- Register Sessions + Attendance Marks (present/absent/late + codes)

---

# Epic 0 — Access, Infrastructure, and Project Bootstrap (Phase 0)

## Deliverables
- Batch API Key(s): Development + Production
- REST API access: Client credentials + required scopes/permissions
- Access to Developer Portal / API Explorer for testing
- Repository scaffold: backend + db + cache + worker-ready structure
- Docker Compose stack for local dev (Postgres + Redis + API)
- `.env.example` + Phase 0 checklist docs

## Admin Checklist
- [ ] Confirm API Services Manager is enabled in iSAMS Control Panel
- [ ] Create Batch API Key (Dev): Control Panel → API Services Manager → Manage Batch API Keys → Create Batch API Key
- [ ] Create Batch API Key (Prod) once MVP is ready
- [ ] Obtain/enable REST API credentials (Client ID/Secret) + required access to Student Registers endpoints
- [ ] Confirm iSAMS host/domain (often *.isams.cloud)
- [ ] Decide notification channel(s): SMS/email provider used by your platform vs internal iSAMS comms
- [ ] Security baseline: no secrets in git; use env vars / secret manager; enable audit logging
EOF

# -------------------------
# Phase 0 checklist doc
# -------------------------
cat > docs/PHASE0_CHECKLIST.md <<'EOF'
# Phase 0 Checklist (Admin)

## 1) Batch API Key
In iSAMS:
Control Panel → API Services Manager → Manage Batch API Keys → Create Batch API Key

- Create one Development key for testing
- Create one Production key when MVP is ready

## 2) REST API Access
You typically need:
- ISAMS_HOST (your school domain/host)
- REST Client ID / Secret
- Permissions/scopes required for Student Registers endpoints (read/write)

Note: In some deployments, REST credentials are issued via support/ticket flow.

## 3) Developer Portal / API Explorer
Use it to test endpoints, inspect payloads, and generate code snippets.

## 4) Notification Strategy
Recommended:
- Send SMS/email from your platform (full control + audit + anti-spam)
Alternative:
- Use internal iSAMS comms (depends on school policy)
EOF

# -------------------------
# env template
# -------------------------
cat > .env.example <<'EOF'
# --- iSAMS ---
ISAMS_HOST=your-school.isams.cloud
ISAMS_BATCH_API_KEY=__SET_ME__
ISAMS_REST_CLIENT_ID=__SET_ME__
ISAMS_REST_CLIENT_SECRET=__SET_ME__

# --- App ---
APP_ENV=dev
APP_PORT=8080

# --- Database ---
POSTGRES_DB=isams_platform
POSTGRES_USER=isams
POSTGRES_PASSWORD=isams
DATABASE_URL=postgresql+asyncpg://isams:isams@db:5432/isams_platform

# --- Redis ---
REDIS_URL=redis://redis:6379/0
EOF

# -------------------------
# Backend: FastAPI skeleton (English only)
# -------------------------
cat > backend/requirements.txt <<'EOF'
fastapi==0.115.0
uvicorn[standard]==0.30.6
httpx==0.27.2
pydantic-settings==2.5.2
python-dotenv==1.0.1
tenacity==9.0.0
structlog==24.4.0
EOF

cat > backend/Dockerfile <<'EOF'
FROM python:3.12-slim

WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY app /app/app

EXPOSE 8080
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
EOF

cat > backend/app/core/config.py <<'EOF'
from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    app_env: str = "dev"
    app_port: int = 8080

    isams_host: str = ""
    isams_batch_api_key: str = ""
    isams_rest_client_id: str = ""
    isams_rest_client_secret: str = ""

    class Config:
        env_file = ".env"
        case_sensitive = False

settings = Settings()
EOF

cat > backend/app/integrations/isams/batch_client.py <<'EOF'
"""
Batch API client placeholder.

Phase 0: scaffold only.
Next phases:
- implement Batch endpoints for your deployment
- parse responses and upsert into the database
"""
from app.core.config import settings

class IsamsBatchClient:
    def __init__(self) -> None:
        self.base_url = f"https://{settings.isams_host}".rstrip("/")
        self.api_key = settings.isams_batch_api_key

    async def ping(self) -> dict:
        # Replace with a real Batch endpoint once confirmed in your iSAMS instance
        return {"ok": True, "mode": "batch", "host": settings.isams_host}
EOF

cat > backend/app/integrations/isams/rest_client.py <<'EOF'
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
EOF

cat > backend/app/api/routes.py <<'EOF'
from fastapi import APIRouter

router = APIRouter()

@router.get("/classes")
async def list_classes():
    # Phase 0: placeholder. Will be backed by Teaching Sets / Timetable in Phase 1.
    return {"items": [], "note": "Phase 0 placeholder. iSAMS integration will be added in Phase 1."}
EOF

cat > backend/app/main.py <<'EOF'
from fastapi import FastAPI
from app.api.routes import router
from app.core.config import settings

app = FastAPI(title="iSAMS Attendance Platform", version="0.1.0")

@app.get("/health")
async def health():
    return {"status": "ok", "env": settings.app_env}

app.include_router(router)
EOF

# -------------------------
# Docker Compose stack
# -------------------------
cat > docker-compose.yml <<'EOF'
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_DB: ${POSTGRES_DB:-isams_platform}
      POSTGRES_USER: ${POSTGRES_USER:-isams}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-isams}
    ports:
      - "5432:5432"
    volumes:
      - db_data:/var/lib/postgresql/data

  redis:
    image: redis:7
    ports:
      - "6379:6379"

  api:
    build:
      context: ./backend
    env_file:
      - .env
    ports:
      - "${APP_PORT:-8080}:8080"
    depends_on:
      - db
      - redis

volumes:
  db_data:
EOF

cat > README.md <<'EOF'
# iSAMS Attendance Platform (Phase 0)

## Quick Start
1) Create env file:
   cp .env.example .env
   # then set ISAMS_HOST and keys

2) Start stack:
   docker compose up -d --build

3) Test:
   curl http://localhost:8080/health
   curl http://localhost:8080/classes

## Phase 0 checklist
See: docs/PHASE0_CHECKLIST.md
EOF

echo
echo "== Done =="
echo "Next:"
echo "1) cp .env.example .env"
echo "2) Fill ISAMS_HOST and keys"
echo "3) Run: ${COMPOSE_CMD} up -d --build"
echo "4) Test: curl http://localhost:8080/health"
