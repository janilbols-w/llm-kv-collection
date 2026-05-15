#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
PORTS_DEFAULT="12358,12359"
REMOTE_PORTS_DEFAULT="7379,50051,9980,9003"
KILL_TIMEOUT="${KILL_TIMEOUT:-8}"
DRY_RUN=0
PORTS="${PORTS:-${PORTS_DEFAULT}}"
REMOTE_PORTS="${REMOTE_PORTS:-${REMOTE_PORTS_DEFAULT}}"
INCLUDE_REMOTE_BACKENDS=1

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KV_OFFLOAD_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
REDIS_OUTPUT_ROOT_DEFAULT="${KV_OFFLOAD_ROOT}/outputs/redis_remote_server"
MOONCAKE_OUTPUT_ROOT_DEFAULT="${KV_OFFLOAD_ROOT}/outputs/mooncake_remote_server"
REDIS_OUTPUT_ROOT="${REDIS_OUTPUT_ROOT:-${REDIS_OUTPUT_ROOT_DEFAULT}}"
MOONCAKE_OUTPUT_ROOT="${MOONCAKE_OUTPUT_ROOT:-${MOONCAKE_OUTPUT_ROOT_DEFAULT}}"

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Clean up residual test processes, including:
  - vLLM-related (vllm serve, VLLM::EngineCore, resource_tracker)
  - Redis remote backend
  - Mooncake remote backend

By default, it also attempts remote-backend cleanup through PID files,
process patterns, and optional remote backend ports.

Options:
  --ports p1,p2,...   Ports to target (default: ${PORTS_DEFAULT})
  --remote-ports p1,p2,...
                      Remote backend ports to inspect when enabled
                      (default: ${REMOTE_PORTS_DEFAULT})
  --no-remote-backends
                      Disable redis/mooncake cleanup logic
  --dry-run           Print targets without killing
  --timeout seconds   Wait time before SIGKILL (default: ${KILL_TIMEOUT})
  -h, --help          Show this help

Examples:
  ${SCRIPT_NAME}
  ${SCRIPT_NAME} --ports 12358,12359,12360
  ${SCRIPT_NAME} --remote-ports 7379,50051
  ${SCRIPT_NAME} --no-remote-backends
  ${SCRIPT_NAME} --dry-run
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ports)
      PORTS="$2"
      shift 2
      ;;
    --remote-ports)
      REMOTE_PORTS="$2"
      shift 2
      ;;
    --no-remote-backends)
      INCLUDE_REMOTE_BACKENDS=0
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --timeout)
      KILL_TIMEOUT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

log() {
  echo "[$(date +"%F %T")] $*"
}

trim() {
  local s="$1"
  s="${s#${s%%[![:space:]]*}}"
  s="${s%${s##*[![:space:]]}}"
  printf '%s' "$s"
}

collect_port_pids() {
  local port="$1"

  if command -v lsof >/dev/null 2>&1; then
    lsof -t -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null || true
    return
  fi

  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null \
      | awk -v p=":${port}" '$4 ~ p {print $NF}' \
      | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' \
      || true
    return
  fi

  log "WARN: neither lsof nor ss found; skip port PID detection for ${port}."
}

collect_pattern_pids() {
  local pattern="$1"
  pgrep -f "$pattern" 2>/dev/null || true
}

collect_pidfile_pids() {
  local file_glob="$1"
  local pid_file
  shopt -s nullglob
  for pid_file in ${file_glob}; do
    [[ -f "${pid_file}" ]] || continue
    cat "${pid_file}" 2>/dev/null || true
  done
  shopt -u nullglob
}

pid_cmdline() {
  local pid="$1"
  ps -p "${pid}" -o cmd= 2>/dev/null || true
}

is_remote_backend_pid() {
  local pid="$1"
  local cmd
  cmd="$(pid_cmdline "${pid}")"
  [[ -n "${cmd}" ]] || return 1
  if [[ "${cmd}" == *"redis-server"* ]]; then
    return 0
  fi
  if [[ "${cmd}" == *"mooncake_master"* ]]; then
    return 0
  fi
  return 1
}

all_pids_tmp="$(mktemp)"
trap 'rm -f "${all_pids_tmp}"' EXIT

collect_pattern_pids "[v]llm serve" >>"${all_pids_tmp}"
collect_pattern_pids "VLLM::EngineCore" >>"${all_pids_tmp}"
collect_pattern_pids "multiprocessing\.resource_tracker" >>"${all_pids_tmp}"

if [[ "${INCLUDE_REMOTE_BACKENDS}" == "1" ]]; then
  collect_pattern_pids "[r]edis-server" >>"${all_pids_tmp}"
  collect_pattern_pids "[m]ooncake_master" >>"${all_pids_tmp}"
  collect_pidfile_pids "${REDIS_OUTPUT_ROOT}/redis_*.pid" >>"${all_pids_tmp}"
  collect_pidfile_pids "${MOONCAKE_OUTPUT_ROOT}/mooncake_master_*.pid" >>"${all_pids_tmp}"
fi

IFS=',' read -r -a port_list <<<"${PORTS}"
for raw_port in "${port_list[@]}"; do
  port="$(trim "${raw_port}")"
  [[ -z "${port}" ]] && continue
  collect_port_pids "${port}" >>"${all_pids_tmp}"
done

if [[ "${INCLUDE_REMOTE_BACKENDS}" == "1" ]]; then
  IFS=',' read -r -a remote_port_list <<<"${REMOTE_PORTS}"
  for raw_port in "${remote_port_list[@]}"; do
    port="$(trim "${raw_port}")"
    [[ -z "${port}" ]] && continue
    while IFS= read -r pid; do
      [[ -n "${pid}" ]] || continue
      if is_remote_backend_pid "${pid}"; then
        echo "${pid}" >>"${all_pids_tmp}"
      fi
    done < <(collect_port_pids "${port}")
  done
fi

mapfile -t target_pids < <(sort -u "${all_pids_tmp}" | awk 'NF > 0')

if [[ ${#target_pids[@]} -eq 0 ]]; then
  log "No residual target process found (vLLM/Redis/Mooncake)."
  exit 0
fi

log "Target PID list: ${target_pids[*]}"
ps -fp "${target_pids[@]}" || true

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log "Dry run enabled. No process killed."
  exit 0
fi

log "Sending SIGTERM to target processes..."
kill "${target_pids[@]}" >/dev/null 2>&1 || true

deadline=$((SECONDS + KILL_TIMEOUT))
while (( SECONDS < deadline )); do
  alive=()
  for pid in "${target_pids[@]}"; do
    if kill -0 "${pid}" >/dev/null 2>&1; then
      alive+=("${pid}")
    fi
  done

  if [[ ${#alive[@]} -eq 0 ]]; then
    log "All target processes exited after SIGTERM."
    exit 0
  fi

  sleep 1
done

alive=()
for pid in "${target_pids[@]}"; do
  if kill -0 "${pid}" >/dev/null 2>&1; then
    alive+=("${pid}")
  fi
done

if [[ ${#alive[@]} -gt 0 ]]; then
  log "Sending SIGKILL to remaining PIDs: ${alive[*]}"
  kill -9 "${alive[@]}" >/dev/null 2>&1 || true
fi

log "Cleanup done."
