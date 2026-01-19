#!/usr/bin/env bash
set -euo pipefail

# Phase 4: Pull foundation datasets needed for absentees -> parents notifications

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

mkdir -p exports

echo "==> Using API container: ${CID}"
docker exec -i "${CID}" python - <<'PY'
import os, ssl, urllib.request, urllib.error
import xml.etree.ElementTree as ET
from collections import Counter

def norm_host(h: str) -> str:
    h = (h or "").strip().replace("https://","").replace("http://","")
    return h.strip("/")

HOST = norm_host(os.getenv("ISAMS_HOST", ""))
VERIFY_SSL = (os.getenv("ISAMS_VERIFY_SSL","true").lower() in ("1","true","yes","y"))

if not HOST:
    raise SystemExit("ERROR: ISAMS_HOST is empty")

def pick_key(*names: str) -> str:
    for n in names:
        v = (os.getenv(n) or "").strip()
        if v:
            return v
    return ""

KEY_REG      = pick_key("ISAMS_REG_API_KEY", "ISAMS_BATCH_API_KEY", "ISAMS_BATCH_CLIENT_ID")
KEY_PUPIL    = pick_key("ISAMS_PUPIL_API_KEY", "ISAMS_BATCH_API_KEY", "ISAMS_BATCH_CLIENT_ID")
KEY_CONTACTS = pick_key("ISAMS_CONTACTS_API_KEY", "ISAMS_BATCH_API_KEY", "ISAMS_BATCH_CLIENT_ID")
KEY_TEACHING = pick_key("ISAMS_TEACHING_API_KEY", "ISAMS_BATCH_API_KEY", "ISAMS_BATCH_CLIENT_ID")

def endpoint(api_key: str) -> str:
    return f"https://{HOST}/api/batch/1.0/xml.ashx?apiKey={api_key}"

ctx = ssl.create_default_context()
if not VERIFY_SSL:
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

def post(ep: str, xml: str):
    data = xml.encode("utf-8")
    req = urllib.request.Request(ep, data=data, method="POST")
    req.add_header("Content-Type","application/xml")
    try:
        with urllib.request.urlopen(req, timeout=45, context=ctx) as r:
            return True, r.status, (r.read() or b"")
    except urllib.error.HTTPError as e:
        return False, e.code, (e.read() or b"")
    except Exception as e:
        return False, None, str(e).encode("utf-8", errors="ignore")

def msg_id(raw: bytes) -> str:
    try:
        root = ET.fromstring(raw)  # bytes-aware
        mid = root.findtext(".//MessageId")
        return (mid or "").strip()
    except Exception:
        return ""

def local(tag: str) -> str:
    return tag.split("}",1)[-1] if "}" in tag else tag

def quick_stats(raw: bytes):
    try:
        root = ET.fromstring(raw)
        cnt = Counter(local(e.tag) for e in root.iter())
        return cnt.most_common(8)
    except Exception:
        return []

def save_bytes(path: str, raw: bytes):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(raw)

tasks = [
    # Registration codes (needed to decode Code=39 etc) — codes are customizable
    ("registration_codes", KEY_REG, [
        "<Filters><RegistrationManager><RegistrationCodes /></RegistrationManager></Filters>",
        "<Filters><MethodsToRun><Method>Registration_GetRegistrationCodes</Method></MethodsToRun></Filters>",
    ]),

    # Pupils
    ("pupils", KEY_PUPIL, [
        "<Filters><PupilManager><CurrentStudents /></PupilManager></Filters>",
        "<Filters><PupilManager><CurrentPupils /></PupilManager></Filters>",
        "<Filters><MethodsToRun><Method>PupilManager_GetCurrentStudents</Method></MethodsToRun></Filters>",
    ]),

    # Contacts
    ("contacts", KEY_CONTACTS, [
        "<Filters><PupilManager><Contacts /></PupilManager></Filters>",
        "<Filters><PupilManager><ContactsFiltered /></PupilManager></Filters>",
        "<Filters><MethodsToRun><Method>PupilManager_GetContacts</Method></MethodsToRun></Filters>",
    ]),

    # Teaching Sets / Forms (classes)
    ("teaching_sets", KEY_TEACHING, [
        "<Filters><TeachingManager><TeachingSets /></TeachingManager></Filters>",
        "<Filters><TeachingManager><TeachingForms /></TeachingManager></Filters>",
        "<Filters><TeachingManager><TeachingSetLists /></TeachingManager></Filters>",
    ]),
]

print("VERIFY_SSL =", VERIFY_SSL)
print("HOST       =", HOST)
print()

for name, key, payloads in tasks:
    if not key:
        print(f"[{name}] SKIP (no api key configured)")
        continue

    ep = endpoint(key)
    print(f"==> DATASET: {name}")
    print("endpoint =", ep)

    ok_any = False
    for i, xml in enumerate(payloads, start=1):
        ok, status, raw = post(ep, xml)
        mid = msg_id(raw)
        stats = quick_stats(raw)
        sample = raw[:180].decode("utf-8", errors="ignore").replace("\n"," ").replace("\r"," ")
        print(f"  - try#{i}: ok={ok} status={status} messageId={mid} top_tags={stats} sample='{sample}'")

        if ok and status == 200 and not ok_any:
            out = f"/app/exports/{name}.xml"
            save_bytes(out, raw)
            ok_any = True

    if ok_any:
        print(f"  -> SAVED: exports/{name}.xml (inside container)")
    else:
        print("  -> NO 200. If you see MethodsNotAllocatedToKeyException: enable this dataset in Batch Methods for that key.")
    print()
PY

echo "==> Copy exports from container to host (if needed)"
echo "   docker cp ${CID}:/app/exports ./exports_from_container"
