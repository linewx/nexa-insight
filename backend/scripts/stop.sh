#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

RUN_DIR="$PWD/backend/data/run"

stop_pid() {
  local pid_file="$1"
  local marker="$2"
  if [[ -f "$pid_file" ]]; then
    local pid
    pid="$(cat "$pid_file")"
    if kill -0 "$pid" 2>/dev/null && ps -p "$pid" -o command= | grep -F "$marker" >/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$pid_file"
  fi
}

stop_pid "$RUN_DIR/api.pid" "nexa_insight_api.app:app"
stop_pid "$RUN_DIR/worker.pid" "nexa_insight_api.worker"
echo "Nexa backend stopped"
