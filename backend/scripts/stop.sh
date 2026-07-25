#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

RUN_DIR="$PWD/backend/data/run"

stop_pid() {
  local pid_file="$1"
  if [[ -f "$pid_file" ]]; then
    local pid
    pid="$(cat "$pid_file")"
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$pid_file"
  fi
}

stop_pid "$RUN_DIR/api.pid"
stop_pid "$RUN_DIR/worker.pid"
echo "Nexa backend stopped"
