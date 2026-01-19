#!/usr/bin/env bash
set -euo pipefail

echo "==> Phase 2 (v5): Try entity-node attribute filters for Calendar_GetEvents"

API_HOST="${API_HOST:-127.0.0.1}"
API_PORT="${API_PORT:-18090}"

echo "==> Waiting for API health on http://${API_HOST}:${API_PORT}/health ..."
curl -fsS "http://${API_HOST}:${API_PORT}/health" >/dev/null
echo "OK: API is healthy."

CID="$(docker ps --format '{{.ID}}\t{{.Names}}' | awk '$2 ~ /api/ {print $1; exit}')"
if [[ -z "${CID}" ]]; then
  echo "ERROR: Could not find API container (name matching /api/)."
  exit 1
fi
echo "==> Using API container: ${CID}"

docker exec -i "${CID}" python - <<'PY'
import os, sys, datetime
import urllib.request
import urllib.error
import xml.etree.ElementTree as ET

def env(k, default=None):
    v = os.getenv(k, default)
    return v

host = env("ISAMS_HOST", "").strip()
api_key = env("ISAMS_BATCH_CLIENT_ID", "").strip()  # in your project this is the apiKey
verify_ssl = env("ISAMS_VERIFY_SSL", "true").lower() == "true"

if not host or not api_key:
    print("ERROR: Missing ISAMS_HOST or ISAMS_BATCH_CLIENT_ID in container env.")
    sys.exit(2)

# Normalize host
host = host.replace("https://", "").replace("http://", "").strip().strip("/")
base = f"https://{host}"
endpoint = f"{base}/api/batch/1.0/xml.ashx?apiKey={api_key}"

# Date window: today
today = datetime.date.today().isoformat()
start = os.getenv("ISAMS_TEST_START_DATE", today)
end   = os.getenv("ISAMS_TEST_END_DATE", today)

print("BATCH_ENDPOINT =", endpoint)
print("DATE_WINDOW   =", start, "to", end)
print("VERIFY_SSL    =", verify_ssl)
print()

# Helper to post XML
def post(xml_str: str):
    data = xml_str.encode("utf-8")
    req = urllib.request.Request(
        endpoint,
        data=data,
        headers={"Content-Type": "application/xml"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            body = r.read()
            return True, r.status, r.headers.get("Content-Type",""), body
    except urllib.error.HTTPError as e:
        body = e.read() if hasattr(e, "read") else b""
        return False, e.code, e.headers.get("Content-Type","") if e.headers else "", body
    except Exception as e:
        return False, None, "", (str(e).encode("utf-8"))

def parse_message_id(xml_bytes: bytes):
    try:
        root = ET.fromstring(xml_bytes.decode("utf-16", errors="ignore"))
        mid = root.findtext("MessageId") or ""
        return mid.strip()
    except Exception:
        try:
            root = ET.fromstring(xml_bytes.decode("utf-8", errors="ignore"))
            mid = root.findtext("MessageId") or ""
            return mid.strip()
        except Exception:
            return ""

variants = {
    # Pattern like RegistrationStatuses / RegistrationStatus StartDate='...' EndDate='...'
    "A_CalendarEvents_CalendarEvent_attrs_lower": f"""
<Filters>
  <MethodsToRun>
    <Method>Calendar_GetEvents</Method>
  </MethodsToRun>
  <CalendarEvents>
    <CalendarEvent startDate='{start}' endDate='{end}' />
  </CalendarEvents>
</Filters>
""",
    "B_CalendarEvents_CalendarEvent_attrs_upper": f"""
<Filters>
  <MethodsToRun>
    <Method>Calendar_GetEvents</Method>
  </MethodsToRun>
  <CalendarEvents>
    <CalendarEvent StartDate='{start}' EndDate='{end}' />
  </CalendarEvents>
</Filters>
""",
    "C_CalendarEvents_Event_attrs_lower": f"""
<Filters>
  <MethodsToRun>
    <Method>Calendar_GetEvents</Method>
  </MethodsToRun>
  <CalendarEvents>
    <Event startDate='{start}' endDate='{end}' />
  </CalendarEvents>
</Filters>
""",
    "D_CalendarEvents_Event_attrs_upper": f"""
<Filters>
  <MethodsToRun>
    <Method>Calendar_GetEvents</Method>
  </MethodsToRun>
  <CalendarEvents>
    <Event StartDate='{start}' EndDate='{end}' />
  </CalendarEvents>
</Filters>
""",
    # Alternative root node guesses
    "E_Events_Event_attrs_upper": f"""
<Filters>
  <MethodsToRun>
    <Method>Calendar_GetEvents</Method>
  </MethodsToRun>
  <Events>
    <Event StartDate='{start}' EndDate='{end}' />
  </Events>
</Filters>
""",
    "F_Calendar_CalendarEvent_attrs_upper": f"""
<Filters>
  <MethodsToRun>
    <Method>Calendar_GetEvents</Method>
  </MethodsToRun>
  <Calendar>
    <CalendarEvent StartDate='{start}' EndDate='{end}' />
  </Calendar>
</Filters>
""",
}

for name, xml_str in variants.items():
    ok, status, ctype, body = post(xml_str)
    mid = parse_message_id(body) if body else ""
    sample = body[:220].decode("utf-8", errors="ignore").replace("\n"," ").replace("\r"," ")
    print(f"- {name}: ok={ok} status={status} messageId={mid} content_type={ctype}")
    print(f"  body_sample='{sample}'\n")

print("==> If any variant returns ok=True (200) OR messageId changes away from FiltersRequiredException, we found the correct filter shape.")
PY
