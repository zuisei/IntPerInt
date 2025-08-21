#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

for name in llm20 deepseek67 diffusion api; do
  if [[ -f logs/${name}.pid ]]; then
    pid=$(cat logs/${name}.pid)
    if ps -p "$pid" > /dev/null 2>&1; then
      kill "$pid" || true
      wait "$pid" 2>/dev/null || true
      echo "Stopped $name ($pid)"
    fi
    rm -f logs/${name}.pid
  fi
done

echo "All services stopped."
