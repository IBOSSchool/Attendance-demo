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
