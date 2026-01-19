#!/usr/bin/env bash
set -euo pipefail

FILE="${1:-exports/registration_2025-01-1_2026-01-1.xml}"

if [[ ! -f "$FILE" ]]; then
  echo "ERROR: File not found: $FILE"
  exit 1
fi

python - <<'PY' "$FILE"
import sys
import xml.etree.ElementTree as ET
from collections import Counter

path = sys.argv[1]
raw = open(path, "rb").read()

root = ET.fromstring(raw)  # bytes-aware (handles UTF-16 too)

def local(tag: str) -> str:
    return tag.split("}", 1)[-1] if "}" in tag else tag

# Tag stats
cnt = Counter(local(e.tag) for e in root.iter())
print("root_tag =", local(root.tag))
print("file_bytes =", len(raw))
print("\nTop tags:", cnt.most_common(25))

# Find rows namespace-safe
rows = root.findall(".//{*}RegistrationStatus")
print("\nRegistrationStatus rows =", len(rows))

# Sample: attributes + child tags for first few rows
for i, r in enumerate(rows[:3], start=1):
    print(f"\n--- ROW {i} ---")
    print("attrib_keys =", list(r.attrib.keys()))
    # child elements (first level)
    children = list(r)
    print("child_tags =", [local(c.tag) for c in children[:20]])
    # print small sample of child text
    for c in children[:20]:
        t = (c.text or "").strip()
        if t:
            print(f"  {local(c.tag)} = {t[:80]}")
PY
