#!/usr/bin/env bash
set -euo pipefail

# Phase 1 bootstrap:
# - Env validation helpers
# - Align config with ISAMS_BATCH_CLIENT_ID/SECRET
# - Add /isams/smoke endpoint
# - Keep code/comments in English

need_files=("docker-compose.yml" "backend/app/main.py" "backend/app/core/config.py" "backend/app/integrations/isams/batch_client.py")
for f in "${need_files[@]}"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: Run from project root. Missing: $f"
    exit 1
  fi
done

mkdir -p scripts backend/app/api

# -----------------------------
# 1) Env checker (Batch-first)
# -----------------------------
cat > scripts/phase1_env_check.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ ! -f ".env" ]; then
  echo "ERROR: .env not found. Create it with: cp .env.example .env"
  exit 1
fi

set -a
source .env
set +a

echo "== Phase 1 Env Check =="

missing=0

req_vars=("ISAMS_HOST" "ISAMS_BATCH_CLIENT_ID" "ISAMS_BATCH_CLIENT_SECRET")
for v in "${req_vars[@]}"; do
  if [ -z "${!v:-}" ] || [[ "${!v:-}" == "__SET_ME__"* ]]; then
    echo "MISSING: $v"
    missing=1
  else
    echo "OK:      $v"
  fi
done

echo
echo "REST (optional for now):"
opt_vars=("ISAMS_REST_CLIENT_ID" "ISAMS_REST_CLIENT_SECRET" "ISAMS_TOKEN_URL" "ISAMS_REST_API_BASE_URL")
for v in "${opt_vars[@]}"; do
  if [ -n "${!v:-}" ] && [[ "${!v:-}" != "__SET_ME__"* ]]; then
    echo "SET:     $v"
  else
    echo "EMPTY:   $v"
  fi
done

echo
echo "Notes:"
echo "- Batch keys are created in iSAMS Control Panel -> API Services Manager -> Manage Batch API Keys."
echo "- Cache expiry is often set to 1 hour to reduce sync delay (school policy dependent)."
echo "- REST is typically provisioned separately; leave it empty until you receive the details."

if [ "$missing" -eq 1 ]; then
  echo
  echo "ERROR: Required Batch variables are missing."
  exit 1
fi

echo
echo "OK: Phase 1 env is ready for Batch-only MVP."
EOF
chmod +x scripts/phase1_env_check.sh

# -----------------------------
# 2) Patch backend/app/core/config.py
#    Ensure it supports your env var names.
# -----------------------------
python - <<'PY'
from pathlib import Path
import re

p = Path("backend/app/core/config.py")
txt = p.read_text(encoding="utf-8")

# Only patch if the new fields are missing
if "isams_batch_client_id" not in txt:
    # Insert fields inside Settings class (best-effort)
    # Find the last existing iSAMS-related line and insert after it.
    m = re.search(r"(class Settings\(BaseSettings\):\n)([\s\S]*?)(\n\s*class Config:)", txt)
    if not m:
        raise SystemExit("Could not find Settings class block in config.py")

    head, body, tail = m.group(1), m.group(2), m.group(3)

    insert = """
    # Phase 1: Batch credentials (Batch-only MVP)
    isams_batch_client_id: str = ""
    isams_batch_client_secret: str = ""

    # Optional transport settings
    isams_timeout_seconds: int = 30
    isams_verify_ssl: bool = True
"""

    # If old scaffold had isams_batch_api_key, keep it but add new ones
    new_body = body + insert
    txt = txt[:m.start(1)] + head + new_body + tail + txt[m.end(3):]
    p.write_text(txt, encoding="utf-8")
PY

# -----------------------------
# 3) Patch backend/app/integrations/isams/batch_client.py
# -----------------------------
cat > backend/app/integrations/isams/batch_client.py <<'EOF'
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
EOF

# -----------------------------
# 4) Add /isams/smoke endpoint
# -----------------------------
cat > backend/app/api/isams_routes.py <<'EOF'
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
EOF

MAIN="backend/app/main.py"
if ! grep -q "isams_routes" "$MAIN"; then
  cat >> "$MAIN" <<'EOF'

from app.api.isams_routes import router as isams_router
app.include_router(isams_router)
EOF
fi

# -----------------------------
# 5) Runner script
# -----------------------------
cat > scripts/phase1_run.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

./scripts/phase1_env_check.sh
docker compose up -d --build
echo
echo "Health:"
curl -sS http://localhost:18090/health || true
echo
echo "iSAMS Smoke:"
curl -sS http://localhost:18090/isams/smoke || true
echo
EOF
chmod +x scripts/phase1_run.sh

echo "== Phase 1 bootstrap complete =="
echo "Next:"
echo "  1) ./scripts/phase1_env_check.sh"
echo "  2) ./scripts/phase1_run.sh"
