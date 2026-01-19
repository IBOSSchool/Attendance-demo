#!/usr/bin/env bash
set -euo pipefail

# Phase 2 - Attendance probe via Registration_GetRegistrationStatus
# Uses apiKey-only (Batch API). No curl required inside the container.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
else
  echo "ERROR: .env not found at: $ENV_FILE"
  exit 1
fi

# Host health endpoint (your host port -> container 8080)
APP_PORT="${APP_PORT:-18090}"
HEALTH_URL="http://127.0.0.1:${APP_PORT}/health"

echo "==> Waiting for API health on ${HEALTH_URL} ..."
# Use host curl (Git Bash / Linux). If curl not available, just skip.
if command -v curl >/dev/null 2>&1; then
  curl -fsS "${HEALTH_URL}" >/dev/null
fi
echo "OK: API is healthy."

# Find API container (compose label first, then name fallback)
API_CID="$(docker ps --filter "label=com.docker.compose.service=api" --format "{{.ID}}" | head -n 1 || true)"
if [[ -z "${API_CID}" ]]; then
  API_CID="$(docker ps --filter "name=attendance-demo-api" --format "{{.ID}}" | head -n 1 || true)"
fi

if [[ -z "${API_CID}" ]]; then
  echo "ERROR: Could not find API container. Set a predictable container name or adjust the filters."
  docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Ports}}"
  exit 1
fi

echo "==> Using API container: ${API_CID}"

# Run request inside container using python (no curl needed)
docker exec -i "${API_CID}" python - <<'PY'
import os
import ssl
import urllib.request
import datetime
import xml.etree.ElementTree as ET

def norm_host(h: str) -> str:
    h = (h or "").strip()
    h = h.replace("https://", "").replace("http://", "")
    return h.rstrip("/")

host = norm_host(os.getenv("ISAMS_HOST", ""))
api_key = (os.getenv("ISAMS_BATCH_API_KEY") or os.getenv("ISAMS_BATCH_CLIENT_ID") or "").strip()

if not host:
    raise SystemExit("ERROR: ISAMS_HOST is empty in .env")
if not api_key:
    raise SystemExit("ERROR: ISAMS_BATCH_API_KEY (or ISAMS_BATCH_CLIENT_ID) is empty in .env")

verify_ssl = (os.getenv("ISAMS_VERIFY_SSL", "true").strip().lower() == "true")

today = datetime.date.today().isoformat()
start_date = os.getenv("START_DATE", today).strip()
end_date   = os.getenv("END_DATE", today).strip()

endpoint = f"https://{host}/api/batch/1.0/xml.ashx?apiKey={api_key}"

xml_body = f"""
<Filters>
  <MethodsToRun>
    <Method>Registration_GetRegistrationStatus</Method>
  </MethodsToRun>
  <RegistrationStatuses>
    <RegistrationStatus StartDate='{start_date}' EndDate='{end_date}' />
  </RegistrationStatuses>
</Filters>
""".strip().encode("utf-8")

ctx = ssl.create_default_context()
if not verify_ssl:
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

req = urllib.request.Request(
    endpoint,
    data=xml_body,
    headers={"Content-Type": "application/xml"}
)

print("BATCH_ENDPOINT =", endpoint)
print("DATE_WINDOW   =", f"{start_date} to {end_date}")
print("VERIFY_SSL    =", verify_ssl)
print("METHOD        = Registration_GetRegistrationStatus")
print("-----")

try:
    with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:
        status = resp.status
        content_type = resp.headers.get("Content-Type", "")
        raw = resp.read()
except urllib.error.HTTPError as e:
    status = e.code
    content_type = e.headers.get("Content-Type", "")
    raw = e.read() if e.fp else b""
except Exception as e:
    raise SystemExit(f"ERROR: {type(e).__name__}: {e}")

text = raw.decode("utf-8", errors="replace").strip()
print("HTTP_STATUS   =", status)
print("CONTENT_TYPE  =", content_type)

# Try to parse messageId if it's an error XML message
msg_id = None
try:
    root = ET.fromstring(text)
    mid = root.findtext(".//MessageId")
    if mid:
        msg_id = mid
except Exception:
    pass

if msg_id:
    print("MESSAGE_ID    =", msg_id)

if status == 200:
    # Count results
    try:
        root = ET.fromstring(text)
        rows = root.findall(".//RegistrationStatus")
        print("ROWS_FOUND    =", len(rows))
        # Print a tiny sample (first 1 row)
        if rows:
            r0 = rows[0].attrib
            print("SAMPLE_ATTRS  =", {k: r0.get(k) for k in list(r0.keys())[:8]})
    except Exception as e:
        print("WARN: Could not parse XML rows:", type(e).__name__, e)
else:
    print("BODY_SAMPLE   =", text[:500].replace("\n", " "))
    print("HINT          = If status=403 MethodsNotAllocatedToKeyException -> enable this method on the Batch API key in iSAMS.")
PY
