#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KV_OFFLOAD_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_ROOT="${OUTPUT_ROOT:-${KV_OFFLOAD_ROOT}/outputs/mooncake_remote_server}"

MOONCAKE_HOST="${MOONCAKE_HOST:-127.0.0.1}"
MOONCAKE_MASTER_PORT="${MOONCAKE_MASTER_PORT:-50051}"
MOONCAKE_HTTP_METADATA_HOST="${MOONCAKE_HTTP_METADATA_HOST:-0.0.0.0}"
MOONCAKE_HTTP_METADATA_PORT="${MOONCAKE_HTTP_METADATA_PORT:-9980}"
MOONCAKE_METRICS_PORT="${MOONCAKE_METRICS_PORT:-9003}"

MOONCAKE_MASTER_BIN="${MOONCAKE_MASTER_BIN:-mooncake_master}"
MOONCAKE_LOG_FILE="${MOONCAKE_LOG_FILE:-${OUTPUT_ROOT}/mooncake_master_${MOONCAKE_MASTER_PORT}.log}"
MOONCAKE_PID_FILE="${MOONCAKE_PID_FILE:-${OUTPUT_ROOT}/mooncake_master_${MOONCAKE_MASTER_PORT}.pid}"

MODE="${1:-start}"
if [[ $# -gt 0 ]]; then
	shift
fi

log() {
	echo "[$(date +'%F %T')] $*"
}

is_listening() {
	local host="$1"
	local port="$2"

	if command -v python3 >/dev/null 2>&1; then
		python3 - "${host}" "${port}" <<'PY'
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
		ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"
		return $?
	fi

	if command -v netstat >/dev/null 2>&1; then
		netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"
		return $?
	fi

	if command -v lsof >/dev/null 2>&1; then
		lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
		return $?
	fi

	return 1
}

get_listening_pids() {
	local port="$1"

	if command -v lsof >/dev/null 2>&1; then
		lsof -nP -t -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null | sort -u
		return 0
	fi

	if command -v ss >/dev/null 2>&1; then
		ss -ltnp 2>/dev/null \
			| awk -v p=":${port}" '$4 ~ p {print $NF}' \
			| grep -oE 'pid=[0-9]+' \
			| cut -d= -f2 \
			| sort -u
		return 0
	fi

	if command -v fuser >/dev/null 2>&1; then
		fuser -n tcp "${port}" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u
		return 0
	fi

	return 1
}

collect_stop_candidates() {
	local port="$1"
	local pid_file="$2"

	{
		if [[ -f "${pid_file}" ]]; then
			cat "${pid_file}" 2>/dev/null || true
		fi
		get_listening_pids "${port}" 2>/dev/null || true
	} | grep -E '^[0-9]+$' | sort -u
}

signal_pids() {
	local sig="$1"
	shift
	local p
	for p in "$@"; do
		if [[ -n "${p}" ]] && kill -0 "${p}" >/dev/null 2>&1; then
			kill "-${sig}" "${p}" >/dev/null 2>&1 || true
		fi
	done
}

wait_until_listen() {
	local host="$1"
	local port="$2"
	local timeout_secs="${3:-10}"
	local start_ts
	start_ts="$(date +%s)"

	while true; do
		if is_listening "${host}" "${port}"; then
			return 0
		fi

		if (( $(date +%s) - start_ts >= timeout_secs )); then
			return 1
		fi
		sleep 1
	done
}

start_mooncake() {
	mkdir -p "${OUTPUT_ROOT}"

	if is_listening "${MOONCAKE_HOST}" "${MOONCAKE_MASTER_PORT}"; then
		log "Mooncake master port ${MOONCAKE_MASTER_PORT} is already listening."
		log "Reuse existing backend: mooncakestore://${MOONCAKE_HOST}:${MOONCAKE_MASTER_PORT}/"
		return 0
	fi

	if ! command -v "${MOONCAKE_MASTER_BIN}" >/dev/null 2>&1; then
		echo "[ERROR] ${MOONCAKE_MASTER_BIN} not found." >&2
		echo "Install Mooncake runtime in current environment, for example:" >&2
		echo "  pip install -U mooncake-transfer-engine" >&2
		exit 1
	fi

	log "Starting mooncake master on ${MOONCAKE_HOST}:${MOONCAKE_MASTER_PORT}"
	nohup "${MOONCAKE_MASTER_BIN}" \
		--rpc_address="${MOONCAKE_HOST}" \
		--rpc_port="${MOONCAKE_MASTER_PORT}" \
		--enable_http_metadata_server=1 \
		--http_metadata_server_host="${MOONCAKE_HTTP_METADATA_HOST}" \
		--http_metadata_server_port="${MOONCAKE_HTTP_METADATA_PORT}" \
		--metrics_port="${MOONCAKE_METRICS_PORT}" \
		"$@" >>"${MOONCAKE_LOG_FILE}" 2>&1 &

	local pid
	pid="$!"
	echo "${pid}" >"${MOONCAKE_PID_FILE}"

	if ! wait_until_listen "${MOONCAKE_HOST}" "${MOONCAKE_MASTER_PORT}" 20; then
		echo "[ERROR] Mooncake master did not start successfully on port ${MOONCAKE_MASTER_PORT}." >&2
		echo "Check log: ${MOONCAKE_LOG_FILE}" >&2
		exit 1
	fi

	# Prefer persisting the true listener pid (some versions may fork).
	local listen_pid
	listen_pid="$(get_listening_pids "${MOONCAKE_MASTER_PORT}" 2>/dev/null | head -n1 || true)"
	if [[ -n "${listen_pid}" ]]; then
		echo "${listen_pid}" >"${MOONCAKE_PID_FILE}"
	fi

	log "Mooncake remote backend is ready: mooncakestore://${MOONCAKE_HOST}:${MOONCAKE_MASTER_PORT}/"
	log "HTTP metadata endpoint: http://${MOONCAKE_HOST}:${MOONCAKE_HTTP_METADATA_PORT}/metadata"
	log "Metrics endpoint: http://${MOONCAKE_HOST}:${MOONCAKE_METRICS_PORT}/metrics"
	log "PID file: ${MOONCAKE_PID_FILE}"
	log "Log file: ${MOONCAKE_LOG_FILE}"
}

stop_mooncake() {
	local -a pids
	mapfile -t pids < <(collect_stop_candidates "${MOONCAKE_MASTER_PORT}" "${MOONCAKE_PID_FILE}")
	if (( ${#pids[@]} > 0 )); then
		log "Stopping mooncake master pids=${pids[*]}"
		signal_pids TERM "${pids[@]}"

		local i
		for i in 1 2 3 4 5 6 7 8 9 10; do
			if ! is_listening "${MOONCAKE_HOST}" "${MOONCAKE_MASTER_PORT}"; then
				break
			fi
			sleep 1
		done

		if is_listening "${MOONCAKE_HOST}" "${MOONCAKE_MASTER_PORT}"; then
			log "Mooncake master still listening after SIGTERM, sending SIGKILL."
			signal_pids KILL "${pids[@]}"
			sleep 1
		fi
	fi

	rm -f "${MOONCAKE_PID_FILE}"

	if is_listening "${MOONCAKE_HOST}" "${MOONCAKE_MASTER_PORT}"; then
		echo "[WARN] Mooncake master port ${MOONCAKE_MASTER_PORT} is still in use." >&2
		echo "      It may be managed by another process (not this script)." >&2
		exit 1
	fi

	log "Mooncake backend stopped on port ${MOONCAKE_MASTER_PORT}."
}

status_mooncake() {
	if is_listening "${MOONCAKE_HOST}" "${MOONCAKE_MASTER_PORT}"; then
		log "Mooncake backend is listening on ${MOONCAKE_HOST}:${MOONCAKE_MASTER_PORT}."
		log "Remote URL: mooncakestore://${MOONCAKE_HOST}:${MOONCAKE_MASTER_PORT}/"
		log "HTTP metadata endpoint: http://${MOONCAKE_HOST}:${MOONCAKE_HTTP_METADATA_PORT}/metadata"
		if [[ -f "${MOONCAKE_PID_FILE}" ]]; then
			log "PID file: ${MOONCAKE_PID_FILE}"
		fi
		exit 0
	fi

	log "Mooncake backend is not listening on port ${MOONCAKE_MASTER_PORT}."
	exit 1
}

case "${MODE}" in
	start)
		start_mooncake "$@"
		;;
	stop)
		stop_mooncake
		;;
	status)
		status_mooncake
		;;
	*)
		echo "Usage: $0 {start|stop|status} [extra mooncake_master flags...]" >&2
		exit 2
		;;
esac
