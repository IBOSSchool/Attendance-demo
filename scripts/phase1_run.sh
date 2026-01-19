#!/usr/bin/env bash
set -euo pipefail

./scripts/phase1_env_check.sh
docker compose up -d --build
echo
echo "Health:"
curl -sS http://localhost:8090/health || true
echo
echo "iSAMS Smoke:"
curl -sS http://localhost:8090/isams/smoke || true
echo
