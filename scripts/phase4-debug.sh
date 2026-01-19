#!/usr/bin/env bash
set -euo pipefail

if [ -f ".env" ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

APP_PORT="${APP_PORT:-18090}"
curl -fsS "http://127.0.0.1:${APP_PORT}/health" >/dev/null

CID="$(docker ps -q --filter "name=attendance-demo-api" | head -n 1)"
if [ -z "${CID}" ]; then
  echo "ERROR: API container not found."
  exit 1
fi

echo "==> Using container: ${CID}"

docker exec -i "${CID}" python - <<'PY'
import os, ssl, urllib.request, urllib.error
import xml.etree.ElementTree as ET

def norm_host(h: str) -> str:
    h = (h or "").strip().replace("https://","").replace("http://","")
    return h.strip("/")

HOST = norm_host(os.getenv("ISAMS_HOST",""))
VERIFY_SSL = os.getenv("ISAMS_VERIFY_SSL","true").lower() in ("1","true","yes","y")

KEY_REG = (os.getenv("ISAMS_REG_API_KEY") or "").strip()
KEY_PUP = (os.getenv("ISAMS_PUPIL_API_KEY") or "").strip()
KEY_CON = (os.getenv("ISAMS_CONTACTS_API_KEY") or "").strip()

def ep(key: str) -> str:
    return f"https://{HOST}/api/batch/1.0/xml.ashx?apiKey={key}"

ctx = ssl.create_default_context()
if not VERIFY_SSL:
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

def post(url: str, xml: str):
    data = xml.encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type","application/xml")
    try:
        with urllib.request.urlopen(req, timeout=40, context=ctx) as r:
            return True, r.status, r.read(), r.headers.get("Content-Type","")
    except urllib.error.HTTPError as e:
        return False, e.code, e.read(), e.headers.get("Content-Type","")
    except Exception as e:
        return False, None, str(e).encode("utf-8", errors="ignore"), ""

def parse_msg(raw: bytes):
    # responses are often utf-16
    txt = raw.decode("utf-16", errors="ignore") if b"encoding=\"utf-16\"" in raw[:120] else raw.decode("utf-8", errors="ignore")
    try:
        root = ET.fromstring(txt)
        mid = (root.findtext(".//MessageId") or "").strip()
        title = (root.findtext(".//Title") or "").strip()
        desc = (root.findtext(".//Description") or "").strip()
        return mid, title, desc
    except Exception:
        return "", "", ""

def run(label: str, key: str, method: str):
    if not key:
        print(f"[{label}] SKIP (no key)")
        return
    url = ep(key)
    body = f"<Filters><MethodsToRun><Method>{method}</Method></MethodsToRun></Filters>"
    ok, status, raw, ctype = post(url, body)
    mid, title, desc = parse_msg(raw)
    sample = raw[:160].decode("utf-8", errors="ignore").replace("\n"," ").replace("\r"," ")
    print(f"- {label}: ok={ok} status={status} content_type={ctype}")
    print(f"  method={method}")
    print(f"  messageId={mid} title={title}")
    if desc:
        print(f"  description={desc[:180]}")
    print(f"  sample='{sample}'\n")

print("HOST =", HOST)
print("VERIFY_SSL =", VERIFY_SSL)
print()

run("registration_codes", KEY_REG, "Registration_GetRegistrationCodes")
run("pupils_current",      KEY_PUP, "PupilManager_GetCurrentPupils")
run("pupils_current_alt",  KEY_PUP, "PupilManager_GetCurrentStudents")
run("contacts_filtered",   KEY_CON, "PupilManager_GetContactsFiltered")
run("contacts",            KEY_CON, "PupilManager_GetContacts")
PY
