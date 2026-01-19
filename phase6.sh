#!/usr/bin/env bash
set -euo pipefail

# Load .env if exists
if [ -f ".env" ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

: "${ISAMS_HOST:?Set ISAMS_HOST مثل ibosportal.isamshosting.cloud}"
: "${ISAMS_CONTACTS_API_KEY:?Set ISAMS_CONTACTS_API_KEY}"

API_URL="https://${ISAMS_HOST}/api/batch/1.0/xml.ashx?apiKey=${ISAMS_CONTACTS_API_KEY}"
VERIFY_SSL="${ISAMS_VERIFY_SSL:-true}"

# Accept both ISAMS_* and plain names (to avoid the "contactOnly=true bash ..." trap)
CONTACT_TYPES="${ISAMS_CONTACT_TYPES:-${CONTACT_TYPES:-}}"
CONTACT_LOCATIONS="${ISAMS_CONTACT_LOCATIONS:-${CONTACT_LOCATIONS:-}}"

CONTACT_ONLY="${ISAMS_CONTACT_ONLY:-${CONTACT_ONLY:-${contactOnly:-1}}}"
STUDENT_HOME="${ISAMS_STUDENT_HOME:-${STUDENT_HOME:-${studentHome:-1}}}"
SYSTEM_STATUSES="${ISAMS_SYSTEM_STATUSES:-${SYSTEM_STATUSES:-Current}}"

CONTAINER_NAME="${ISAMS_CONTAINER_NAME:-attendance-demo-api-1}"

echo "==> Health check: http://127.0.0.1:18090/health"
curl -fsS "http://127.0.0.1:18090/health" >/dev/null || { echo "Health failed"; exit 1; }
echo "OK: API is healthy."
echo "==> Using API container: ${CONTAINER_NAME}"

docker exec -i \
  -e API_URL="${API_URL}" \
  -e VERIFY_SSL="${VERIFY_SSL}" \
  -e CONTACT_TYPES="${CONTACT_TYPES}" \
  -e CONTACT_LOCATIONS="${CONTACT_LOCATIONS}" \
  -e CONTACT_ONLY="${CONTACT_ONLY}" \
  -e STUDENT_HOME="${STUDENT_HOME}" \
  -e SYSTEM_STATUSES="${SYSTEM_STATUSES}" \
  -e ISAMS_HOST="${ISAMS_HOST}" \
  "${CONTAINER_NAME}" python - <<'PY'
import os, ssl, datetime, time
import urllib.request
import urllib.error
import xml.etree.ElementTree as ET

API_URL = os.environ["API_URL"]
VERIFY_SSL = os.environ.get("VERIFY_SSL","true").lower() == "true"

CONTACT_TYPES = os.environ.get("CONTACT_TYPES","").strip()
CONTACT_LOCATIONS = os.environ.get("CONTACT_LOCATIONS","").strip()
CONTACT_ONLY = os.environ.get("CONTACT_ONLY","1").strip()
STUDENT_HOME = os.environ.get("STUDENT_HOME","1").strip()
SYSTEM_STATUSES = os.environ.get("SYSTEM_STATUSES","Current").strip()

ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
out_dir = "/app/exports"
os.makedirs(out_dir, exist_ok=True)

def _ctx():
    if VERIFY_SSL:
        return ssl.create_default_context()
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx

def post_xml(xml_text: str, retries: int = 2):
    data = xml_text.encode("utf-8")
    req = urllib.request.Request(
        API_URL,
        data=data,
        method="POST",
        headers={
            # application/xml is usually friendlier than text/xml with proxies
            "Content-Type": "application/xml; charset=utf-8",
            "Accept": "application/xml",
            "Connection": "close",
        },
    )
    last_exc = None
    for attempt in range(retries + 1):
        try:
            with urllib.request.urlopen(req, context=_ctx(), timeout=45) as r:
                return r.status, dict(r.headers), r.read()
        except urllib.error.HTTPError as e:
            return e.code, dict(e.headers), e.read()
        except Exception as e:
            last_exc = e
            if attempt < retries:
                time.sleep(1.0 * (attempt + 1))
                continue
            return None, {}, (f"EXCEPTION: {type(last_exc).__name__}: {last_exc}").encode("utf-8","ignore")

def decode_body(b: bytes) -> str:
    if b.startswith(b"\xff\xfe") or b.startswith(b"\xfe\xff"):
        try:
            return b.decode("utf-16")
        except Exception:
            pass
    try:
        txt = b.decode("utf-8", errors="replace")
        if 'encoding="utf-16"' in txt or "encoding='utf-16'" in txt:
            try:
                return b.decode("utf-16")
            except Exception:
                return txt
        return txt
    except Exception:
        return b.decode("latin-1", errors="replace")

def parse_message(xml_txt: str):
    try:
        root = ET.fromstring(xml_txt)
    except Exception:
        return {}
    if root.tag.lower() == "message":
        return {ch.tag: (ch.text or "").strip() for ch in root}
    msg = root.find(".//Message")
    if msg is None:
        return {}
    return {ch.tag: (ch.text or "").strip() for ch in msg}

def save(name: str, body: bytes):
    path = f"{out_dir}/{name}_{ts}.xml"
    with open(path, "wb") as f:
        f.write(body)
    return path

# ---------- XML builders (FIXED BODY) ----------

def build_xml_filters_as_filters(method: str, filters: dict) -> str:
    """
    Standard-ish: <MethodsToRun><Method>...</Method></MethodsToRun>
    plus filters as <Filter Name="x">y</Filter>
    """
    lines = ["<iSAMS>", "  <Filters>"]
    lines.append("    <MethodsToRun>")
    lines.append(f"      <Method>{method}</Method>")
    lines.append("    </MethodsToRun>")
    for k, v in filters.items():
        if v is None or str(v).strip() == "":
            continue
        lines.append(f'    <Filter Name="{k}">{v}</Filter>')
    lines += ["  </Filters>", "</iSAMS>"]
    return "\n".join(lines)

def build_xml_filters_as_contacts_node(method: str, filters: dict) -> str:
    """
    Alternative: put required POST filters under <Contacts> node
    because iSAMS UI shows Node=<Contacts> for contacts datasets.
    """
    lines = ["<iSAMS>", "  <Filters>"]
    lines.append("    <MethodsToRun>")
    lines.append(f"      <Method>{method}</Method>")
    lines.append("    </MethodsToRun>")
    lines.append("    <Contacts>")
    for k, v in filters.items():
        if v is None or str(v).strip() == "":
            continue
        lines.append(f"      <{k}>{v}</{k}>")
    lines.append("    </Contacts>")
    lines += ["  </Filters>", "</iSAMS>"]
    return "\n".join(lines)

def run_try(method: str, filters: dict, label: str):
    builders = [
        ("filters", build_xml_filters_as_filters),
        ("contactsNode", build_xml_filters_as_contacts_node),
    ]
    for style_name, builder in builders:
        xml = builder(method, filters)
        status, headers, body = post_xml(xml)
        txt = decode_body(body)
        msg = parse_message(txt)
        mid = msg.get("MessageId","")
        title = msg.get("Title","")
        desc = msg.get("Description","") or msg.get("Desc","")
        out = save(f"contacts_{method}_{label}_{style_name}", body)
        ok = (status == 200)
        print(f"- method={method} {label} style={style_name} status={status} ok={ok} messageId={mid}")
        if title: print(f"  title={title}")
        if desc:  print(f"  desc ={desc[:220]}")
        print(f"  saved={out}")
        print(f"  sample={txt[:180].replace(chr(10),' ')}")
        if ok:
            return True
    return False

print("HOST =", os.environ.get("ISAMS_HOST"))
print("VERIFY_SSL =", VERIFY_SSL)
print("endpoint =", API_URL)
print("CONTACT_TYPES =", CONTACT_TYPES or "(empty)")
print("CONTACT_LOCATIONS =", CONTACT_LOCATIONS or "(empty)")
print("-----")

# Required POST filters (per iSAMS UI)
# We'll try both numeric booleans and true/false
base_num = {
    "contactOnly": CONTACT_ONLY,
    "studentHome": STUDENT_HOME,
    "systemStatusesToInclude": SYSTEM_STATUSES,
}
base_bool = {
    "contactOnly": "true",
    "studentHome": "true",
    "systemStatusesToInclude": SYSTEM_STATUSES,
}

def with_types_locations(d: dict):
    dd = dict(d)
    if CONTACT_TYPES:
        dd["contactTypes"] = CONTACT_TYPES
    if CONTACT_LOCATIONS:
        dd["contactLocations"] = CONTACT_LOCATIONS
    return dd

success = False

# Contacts (Filtered) requires POST filters
success |= run_try("PupilManager_GetContactsFiltered", with_types_locations(base_num), "num")
success |= run_try("PupilManager_GetContactsFiltered", with_types_locations(base_bool), "bool")

# Fallbacks
success |= run_try("PupilManager_GetContacts", with_types_locations(base_num), "num")
success |= run_try("PupilManager_GetContacts", with_types_locations(base_bool), "bool")

success |= run_try("ContactAdvanced_GetContacts", with_types_locations(base_num), "num")
success |= run_try("ContactAdvanced_GetContacts", with_types_locations(base_bool), "bool")

print("==> RESULT:")
if success:
    print("✅ Got at least one 200 response. Next: parse phones/emails and join with absentees.")
else:
    if not CONTACT_TYPES or not CONTACT_LOCATIONS:
        print("❌ Still no 200.")
        print("You MUST provide contactTypes and contactLocations (POST filters).")
        print("Run for example:")
        print('  ISAMS_CONTACT_TYPES="1,2" ISAMS_CONTACT_LOCATIONS="1,2" bash phase6.sh')
        print("If you don't know IDs, ask iSAMS admin for the mapping or brute-force small ranges.")
    else:
        print("❌ Still no 200 even with contactTypes/contactLocations.")
        print("Then likely: wrong method enabled for this key OR values not accepted (IDs mismatch).")
        print("Open the saved XML in /app/exports and send me the MessageId/Description.")
PY
