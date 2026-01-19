#!/usr/bin/env bash
set -euo pipefail

# Phase 5: Attendance engine (Batch) -> Postgres -> Absentees CSV
#
# Usage:
#   START_DATE=2026-01-15 END_DATE=2026-01-15 bash phase5.sh
#
# Output:
#   exports/absentees_<START_DATE>_<END_DATE>.csv

# Load .env if present
if [[ -f ".env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

START_DATE="${START_DATE:-}"
END_DATE="${END_DATE:-}"
if [[ -z "${START_DATE}" || -z "${END_DATE}" ]]; then
  echo "ERROR: Please set START_DATE and END_DATE (YYYY-MM-DD)."
  echo "Example: START_DATE=2026-01-15 END_DATE=2026-01-15 bash phase5.sh"
  exit 1
fi

APP_PORT="${APP_PORT:-18090}"
HEALTH_URL="http://127.0.0.1:${APP_PORT}/health"

echo "==> Health check: ${HEALTH_URL}"
curl -fsS "${HEALTH_URL}" >/dev/null
echo "OK: API is healthy."

echo "==> Phase 5.1: Refresh registration_codes (phase4.sh)"
bash ./phase4.sh >/dev/null

echo "==> Phase 5.2: Export registration statuses for ${START_DATE}..${END_DATE} (phase3.sh)"
START_DATE="${START_DATE}" END_DATE="${END_DATE}" bash ./phase3.sh >/dev/null

REG_FILE="exports/registration_${START_DATE}_${END_DATE}.xml"
if [[ ! -f "${REG_FILE}" ]]; then
  echo "ERROR: Missing ${REG_FILE}. phase3.sh did not produce it."
  exit 1
fi

CID="$(docker ps -q --filter "name=attendance-demo-api" | head -n 1)"
if [[ -z "${CID}" ]]; then
  CID="$(docker ps -q --filter "name=attendance-demo-api-1" | head -n 1 || true)"
fi
if [[ -z "${CID}" ]]; then
  echo "ERROR: API container not found."
  docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Ports}}"
  exit 1
fi

echo "==> Using API container: ${CID}"

echo "==> Copy registration XML into container exports/"
docker exec -i "${CID}" sh -lc "mkdir -p /app/exports" >/dev/null
docker cp "${REG_FILE}" "${CID}:/app/exports/$(basename "${REG_FILE}")" >/dev/null

echo "==> Phase 5.3: Import into Postgres + generate absentees CSV"
docker exec -i \
  -e START_DATE="${START_DATE}" \
  -e END_DATE="${END_DATE}" \
  "${CID}" python - <<'PY'
import os, csv
import xml.etree.ElementTree as ET
from datetime import datetime

START_DATE = os.environ["START_DATE"]
END_DATE = os.environ["END_DATE"]

EXPORTS_DIR = "/app/exports"
reg_path = os.path.join(EXPORTS_DIR, f"registration_{START_DATE}_{END_DATE}.xml")
codes_path = os.path.join(EXPORTS_DIR, "registration_codes.xml")
out_csv = os.path.join(EXPORTS_DIR, f"absentees_{START_DATE}_{END_DATE}.csv")

if not os.path.exists(reg_path):
    raise SystemExit(f"Missing file: {reg_path}")
if not os.path.exists(codes_path):
    raise SystemExit(f"Missing file: {codes_path} (run phase4.sh successfully)")

def parse_xml_bytes(path: str):
    raw = open(path, "rb").read()
    return ET.fromstring(raw)

def to_bool01(x: str) -> bool:
    return (x or "").strip() == "1"

def to_int(x: str):
    x = (x or "").strip()
    return int(x) if x.isdigit() else None

def to_dt(x: str):
    x = (x or "").strip()
    return datetime.fromisoformat(x) if x else None

# --- Load registration codes ---
codes_root = parse_xml_bytes(codes_path)
code_map = {}  # id(int) -> meta
for rc in codes_root.findall(".//RegistrationCode"):
    code_id = to_int(rc.attrib.get("Id",""))
    code_txt = (rc.findtext("Code") or "").strip()
    name = (rc.findtext("Name") or "").strip()
    absence = to_bool01(rc.findtext("Absence") or "0")
    active = to_bool01(rc.findtext("Active") or "0")
    code_map[code_id] = {
        "id": code_id,
        "code": code_txt,
        "name": name,
        "absence": absence,
        "active": active,
    }

# --- Load registration statuses ---
reg_root = parse_xml_bytes(reg_path)
rows = []
for r in reg_root.findall(".//RegistrationStatus"):
    rid = to_int(r.attrib.get("Id",""))
    pupil_id = (r.findtext("PupilId") or "").strip()
    registered = to_bool01(r.findtext("Registered") or "0")
    dt = to_dt(r.findtext("RegistrationDateTime") or "")
    period_id = to_int(r.findtext("PeriodId") or "")
    late = to_bool01(r.findtext("Late") or "0")
    minutes_late = to_int(r.findtext("MinutesLate") or "")
    code_val = (r.findtext("Code") or "").strip()
    code_id = to_int(code_val)  # in your data it's numeric (e.g. 39)

    cm = code_map.get(code_id)
    is_absence_code = bool(cm and cm.get("absence"))
    is_absent = is_absence_code or (not registered)

    rows.append({
        "id": rid,
        "pupil_id": pupil_id,
        "dt": dt,
        "period_id": period_id,
        "registered": registered,
        "code_id": code_id,
        "code_name": (cm.get("name") if cm else ""),
        "is_absence_code": is_absence_code,
        "is_absent": is_absent,
        "late": late,
        "minutes_late": minutes_late or 0,
    })

# --- Optional: upsert to Postgres ---
db_url = (os.getenv("DATABASE_URL") or "").strip()
did_db = False
db_err = None

def asyncpg_dsn(sqlalchemy_url: str) -> str:
    return sqlalchemy_url.replace("postgresql+asyncpg://", "postgresql://", 1)

async def run_db():
    import asyncpg

    dsn = asyncpg_dsn(db_url)
    conn = await asyncpg.connect(dsn)
    try:
        await conn.execute("""
        CREATE TABLE IF NOT EXISTS registration_codes (
          id      INTEGER PRIMARY KEY,
          code    TEXT,
          name    TEXT,
          absence BOOLEAN,
          active  BOOLEAN
        );
        """)
        await conn.execute("""
        CREATE TABLE IF NOT EXISTS registration_statuses (
          id             BIGINT PRIMARY KEY,
          pupil_id       TEXT NOT NULL,
          registration_dt TIMESTAMP NULL,
          period_id      INTEGER NULL,
          registered     BOOLEAN NOT NULL,
          code_id        INTEGER NULL,
          late           BOOLEAN NULL,
          minutes_late   INTEGER NULL
        );
        """)

        for c in code_map.values():
            if c["id"] is None:
                continue
            await conn.execute("""
            INSERT INTO registration_codes (id, code, name, absence, active)
            VALUES ($1,$2,$3,$4,$5)
            ON CONFLICT (id) DO UPDATE SET
              code=EXCLUDED.code,
              name=EXCLUDED.name,
              absence=EXCLUDED.absence,
              active=EXCLUDED.active
            """, c["id"], c["code"], c["name"], c["absence"], c["active"])

        for r in rows:
            if r["id"] is None:
                continue
            await conn.execute("""
            INSERT INTO registration_statuses
              (id, pupil_id, registration_dt, period_id, registered, code_id, late, minutes_late)
            VALUES
              ($1,$2,$3,$4,$5,$6,$7,$8)
            ON CONFLICT (id) DO UPDATE SET
              pupil_id=EXCLUDED.pupil_id,
              registration_dt=EXCLUDED.registration_dt,
              period_id=EXCLUDED.period_id,
              registered=EXCLUDED.registered,
              code_id=EXCLUDED.code_id,
              late=EXCLUDED.late,
              minutes_late=EXCLUDED.minutes_late
            """,
            r["id"], r["pupil_id"], r["dt"],
            r["period_id"],
            r["registered"],
            r["code_id"],
            r["late"],
            r["minutes_late"])
    finally:
        await conn.close()

if db_url:
    try:
        import asyncio
        asyncio.run(run_db())
        did_db = True
    except Exception as e:
        db_err = f"{type(e).__name__}: {e}"

# --- Build absentees summary (per pupil per day) ---
summary = {}
for r in rows:
    if not r["is_absent"]:
        continue
    if not r["pupil_id"] or not r["dt"]:
        continue
    day = r["dt"].date().isoformat()
    key = (day, r["pupil_id"])
    s = summary.setdefault(key, {"Date": day, "PupilId": r["pupil_id"], "AbsentPeriods": 0, "Codes": set()})
    s["AbsentPeriods"] += 1
    if r["code_name"]:
        s["Codes"].add(r["code_name"])

with open(out_csv, "w", newline="", encoding="utf-8") as f:
    w = csv.DictWriter(f, fieldnames=["Date","PupilId","AbsentPeriods","Codes"])
    w.writeheader()
    for (_d, _pid), s in sorted(summary.items()):
        w.writerow({
            "Date": s["Date"],
            "PupilId": s["PupilId"],
            "AbsentPeriods": s["AbsentPeriods"],
            "Codes": "; ".join(sorted(s["Codes"])) if s["Codes"] else ""
        })

print("==> Phase 5 result")
print("TOTAL_ROWS_IN_FILE =", len(rows))
print("ABSENT_PUPILS_DAYS =", len(summary))
print("CSV_OUT =", out_csv)
print("DB_UPSERT =", "OK" if did_db else f"SKIPPED/FAILED ({db_err})")
PY

echo "==> Copy absentees CSV from container to host exports/"
mkdir -p exports
docker cp "${CID}:/app/exports/absentees_${START_DATE}_${END_DATE}.csv" \
          "exports/absentees_${START_DATE}_${END_DATE}.csv" >/dev/null

echo "==> DONE: exports/absentees_${START_DATE}_${END_DATE}.csv"
