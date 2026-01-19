#!/usr/bin/env bash
set -euo pipefail

# Usage:
# START_DATE=2026-01-17 END_DATE=2026-01-17 bash scripts/phase3_pull_registration.sh
# Output XML will be saved to ./exports/registration_<start>_<end>.xml

if [ -f ".env" ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

APP_PORT="${APP_PORT:-18090}"
HEALTH_URL="http://127.0.0.1:${APP_PORT}/health"

echo "==> Health check: ${HEALTH_URL}"
curl -fsS "${HEALTH_URL}" >/dev/null
echo "OK: API is healthy."

CID="$(docker ps -q --filter "name=attendance-demo-api" | head -n 1)"
if [ -z "${CID}" ]; then
  CID="$(docker ps --filter "label=com.docker.compose.service=api" --format "{{.ID}}" | head -n 1 || true)"
fi
if [ -z "${CID}" ]; then
  echo "ERROR: API container not found."
  docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Ports}}"
  exit 1
fi

START_DATE="${START_DATE:-$(date +%F)}"
END_DATE="${END_DATE:-$(date +%F)}"

mkdir -p exports
OUT_FILE="exports/registration_${START_DATE}_${END_DATE}.xml"

echo "==> Pulling Registration XML for ${START_DATE}..${END_DATE}"
echo "==> Output: ${OUT_FILE}"

docker exec -i "${CID}" python - <<'PY' "${START_DATE}" "${END_DATE}" > "${OUT_FILE}"
import os, sys, ssl, urllib.request, urllib.error
import xml.etree.ElementTree as ET

start_date = sys.argv[1]
end_date = sys.argv[2]

def norm_host(h: str) -> str:
    h = (h or "").strip().replace("https://","").replace("http://","")
    return h.strip("/")

host = norm_host(os.getenv("ISAMS_HOST", ""))
api_key = (os.getenv("ISAMS_BATCH_API_KEY") or os.getenv("ISAMS_BATCH_CLIENT_ID") or "").strip()
verify_ssl = (os.getenv("ISAMS_VERIFY_SSL","true").lower() in ("1","true","yes","y"))

if not host:
    raise SystemExit("ERROR: ISAMS_HOST is empty")
if not api_key:
    raise SystemExit("ERROR: ISAMS_BATCH_API_KEY (or ISAMS_BATCH_CLIENT_ID) is empty")

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

req = urllib.request.Request(endpoint, data=xml_body, headers={"Content-Type":"application/xml"}, method="POST")

try:
    with urllib.request.urlopen(req, timeout=30, context=ctx) as r:
        raw = r.read()  # keep bytes!
except urllib.error.HTTPError as e:
    raw = e.read() if hasattr(e, "read") else b""
    # print error body to stdout so you can see it in the xml file
    sys.stdout.buffer.write(raw)
    raise SystemExit(f"HTTPError {e.code}: saved error XML to output")

# Write raw bytes directly to stdout (redirected to file)
sys.stdout.buffer.write(raw)
PY

echo "==> Saved. Now counting nodes..."
python - <<'PY' "${OUT_FILE}"
import sys, xml.etree.ElementTree as ET
path = sys.argv[1]
raw = open(path, "rb").read()
root = ET.fromstring(raw)  # bytes-aware
rows = root.findall(".//RegistrationStatus")
print("ROWS_FOUND =", len(rows))
# Print a tiny sample of attributes if present
if rows:
    print("SAMPLE_ATTRS =", dict(list(rows[0].attrib.items())[:12]))
PY
