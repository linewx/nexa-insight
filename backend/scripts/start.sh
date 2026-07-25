#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

export PYTHONPATH=backend/src
PYTHON="${PYTHON:-$PWD/backend/.venv/bin/python}"
UVICORN="${UVICORN:-$PWD/backend/.venv/bin/uvicorn}"
LOG_DIR="$PWD/backend/data/logs"
RUN_DIR="$PWD/backend/data/run"
API_PID_FILE="$RUN_DIR/api.pid"
WORKER_PID_FILE="$RUN_DIR/worker.pid"

mkdir -p "$LOG_DIR" "$RUN_DIR"

if [[ ! -x "$PYTHON" || ! -x "$UVICORN" ]]; then
  echo "Missing backend virtual environment. Create it with: python3 -m venv backend/.venv" >&2
  exit 1
fi

is_running() {
  local pid_file="$1"
  [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null
}

if ! is_running "$API_PID_FILE"; then
  nohup "$UVICORN" nexa_insight_api.app:app --host 0.0.0.0 --port 8000 \
    > "$LOG_DIR/api.log" 2>&1 < /dev/null &
  echo $! > "$API_PID_FILE"
fi

if ! is_running "$WORKER_PID_FILE"; then
  nohup "$PYTHON" -m nexa_insight_api.worker \
    > "$LOG_DIR/worker.log" 2>&1 < /dev/null &
  echo $! > "$WORKER_PID_FILE"
fi

for _ in {1..30}; do
  if curl -fsS --max-time 1 http://127.0.0.1:8000/api/health >/dev/null; then
    echo "Nexa backend running on http://0.0.0.0:8000"
    echo "API pid: $(cat "$API_PID_FILE")"
    echo "Worker pid: $(cat "$WORKER_PID_FILE")"
    exit 0
  fi
  sleep 1
done

echo "Nexa backend did not become healthy. See $LOG_DIR/api.log and $LOG_DIR/worker.log" >&2
exit 1
