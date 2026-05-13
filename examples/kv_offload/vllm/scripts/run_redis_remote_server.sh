#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_ROOT="${OUTPUT_ROOT:-${SCRIPT_DIR}/outputs/redis_remote_server}"

REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-7379}"
REDIS_DATA_DIR="${REDIS_DATA_DIR:-${OUTPUT_ROOT}/data}"
REDIS_LOG_FILE="${REDIS_LOG_FILE:-${OUTPUT_ROOT}/redis_${REDIS_PORT}.log}"
REDIS_PID_FILE="${REDIS_PID_FILE:-${OUTPUT_ROOT}/redis_${REDIS_PORT}.pid}"

MODE="${1:-start}"

log() {
  echo "[$(date +'%F %T')] $*"
}

is_listening() {
  if command -v python3 >/dev/null 2>&1; then
    python3 - "${REDIS_HOST}" "${REDIS_PORT}" <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(0.5)
try:
    s.connect((host, port))
except OSError:
    sys.exit(1)
finally:
    s.close()
sys.exit(0)
PY
    return $?
  fi

  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${REDIS_PORT}$"
    return $?
  fi

  if command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${REDIS_PORT}$"
    return $?
  fi

  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"${REDIS_PORT}" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi

  return 1
}

wait_until_listen() {
  local timeout_secs="${1:-10}"
  local start_ts
  start_ts="$(date +%s)"

  while true; do
    if is_listening; then
      return 0
    fi

    if (( $(date +%s) - start_ts >= timeout_secs )); then
      return 1
    fi
    sleep 1
  done
}

start_redis() {
  mkdir -p "${OUTPUT_ROOT}" "${REDIS_DATA_DIR}"

  if is_listening; then
    log "Redis port ${REDIS_PORT} is already listening."
    log "Reuse existing backend: resp://${REDIS_HOST}:${REDIS_PORT}"
    return 0
  fi

  if ! command -v redis-server >/dev/null 2>&1; then
    echo "[ERROR] redis-server not found." >&2
    echo "Install redis or run with docker, for example:" >&2
    echo "  docker run -d --name lmcache-redis -p ${REDIS_PORT}:6379 redis:7" >&2
    exit 1
  fi

  log "Starting redis-server on ${REDIS_HOST}:${REDIS_PORT}"
  redis-server \
    --bind "${REDIS_HOST}" \
    --port "${REDIS_PORT}" \
    --save "" \
    --appendonly no \
    --dir "${REDIS_DATA_DIR}" \
    --daemonize yes \
    --pidfile "${REDIS_PID_FILE}" \
    --logfile "${REDIS_LOG_FILE}"

  if ! wait_until_listen 10; then
    echo "[ERROR] Redis did not start successfully on port ${REDIS_PORT}." >&2
    echo "Check log: ${REDIS_LOG_FILE}" >&2
    exit 1
  fi

  log "Redis remote backend is ready: resp://${REDIS_HOST}:${REDIS_PORT}"
  log "PID file: ${REDIS_PID_FILE}"
  log "Log file: ${REDIS_LOG_FILE}"
}

stop_redis() {
  if [[ -f "${REDIS_PID_FILE}" ]]; then
    local pid
    pid="$(cat "${REDIS_PID_FILE}" || true)"
    if [[ -n "${pid}" ]] && kill -0 "${pid}" >/dev/null 2>&1; then
      log "Stopping redis pid=${pid}"
      kill "${pid}" >/dev/null 2>&1 || true
    fi

    rm -f "${REDIS_PID_FILE}"
  fi

  if is_listening; then
    if command -v redis-cli >/dev/null 2>&1; then
      log "Port ${REDIS_PORT} still listening; trying redis-cli shutdown"
      redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" shutdown nosave >/dev/null 2>&1 || true
    fi
  fi

  if is_listening; then
    echo "[WARN] Port ${REDIS_PORT} is still in use." >&2
    echo "      It may be managed by another process (not this script)." >&2
    exit 1
  fi

  log "Redis backend stopped on port ${REDIS_PORT}."
}

status_redis() {
  if is_listening; then
    log "Redis backend is listening on ${REDIS_HOST}:${REDIS_PORT}."
    if [[ -f "${REDIS_PID_FILE}" ]]; then
      log "PID file: ${REDIS_PID_FILE}"
    fi
    exit 0
  fi

  log "Redis backend is not listening on port ${REDIS_PORT}."
  exit 1
}

case "${MODE}" in
  start)
    start_redis
    ;;
  stop)
    stop_redis
    ;;
  status)
    status_redis
    ;;
  *)
    echo "Usage: $0 {start|stop|status}" >&2
    exit 2
    ;;
esac
