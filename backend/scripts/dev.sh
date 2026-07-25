#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export PYTHONPATH=backend/src
PYTHON="${PYTHON:-$PWD/backend/.venv/bin/python}"
UVICORN="${UVICORN:-$PWD/backend/.venv/bin/uvicorn}"

if [[ ! -x "$PYTHON" || ! -x "$UVICORN" ]]; then
  echo "Missing backend virtual environment. Create it with: python3 -m venv backend/.venv" >&2
  exit 1
fi

"$UVICORN" nexa_insight_api.app:app --host 0.0.0.0 --port 8000 &
API_PID=$!
"$PYTHON" -m nexa_insight_api.worker &
WORKER_PID=$!
trap 'kill $API_PID $WORKER_PID 2>/dev/null || true' EXIT
wait
