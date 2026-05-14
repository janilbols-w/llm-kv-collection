#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KV_OFFLOAD_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

RUN_LMCACHE_OFFLOAD_INSTANCE="${RUN_LMCACHE_OFFLOAD_INSTANCE:-${SCRIPT_DIR}/run_lmcache_offload_instance.sh}"

HOST_A="${HOST_A:-127.0.0.1}"
PORT_A="${PORT_A:-12358}"
SERVED_NAME_A="${SERVED_NAME_A:-mymodel-a}"
LMCACHE_CONFIG_FILE_A="${LMCACHE_CONFIG_FILE_A:-${KV_OFFLOAD_ROOT}/config/redis/lmcahce.instance_a.yaml}"
LMCACHE_INSTANCE_NAME_A="${LMCACHE_INSTANCE_NAME_A:-}"
GPU_A="${GPU_A:-}"

HOST_B="${HOST_B:-127.0.0.1}"
PORT_B="${PORT_B:-12359}"
SERVED_NAME_B="${SERVED_NAME_B:-mymodel-b}"
LMCACHE_CONFIG_FILE_B="${LMCACHE_CONFIG_FILE_B:-${KV_OFFLOAD_ROOT}/config/redis/lmcahce.instance_b.yaml}"
LMCACHE_INSTANCE_NAME_B="${LMCACHE_INSTANCE_NAME_B:-}"
GPU_B="${GPU_B:-}"

AUTO_SELECT_IDLE_GPUS="${AUTO_SELECT_IDLE_GPUS:-1}"
IDLE_GPU_MEMORY_THRESHOLD_MIB="${IDLE_GPU_MEMORY_THRESHOLD_MIB:-512}"

STARTUP_TIMEOUT_SECS="${STARTUP_TIMEOUT_SECS:-300}"

OUTPUT_ROOT="${OUTPUT_ROOT:-${KV_OFFLOAD_ROOT}/outputs/multi_lmcache}"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${OUTPUT_ROOT}/${RUN_TS}"
CHECKS_LOG="${RUN_DIR}/checks.log"
SERVER_A_LOG="${RUN_DIR}/server_a.log"
SERVER_B_LOG="${RUN_DIR}/server_b.log"

PID_A=""
PID_B=""

mkdir -p "${RUN_DIR}"

log() {
  local msg="$*"
  echo "[$(date +'%F %T')] ${msg}" | tee -a "${CHECKS_LOG}"
}

cleanup() {
  local ec=$?
  for pid in "${PID_A}" "${PID_B}"; do
    if [[ -n "${pid}" ]] && kill -0 "${pid}" >/dev/null 2>&1; then
      kill "${pid}" >/dev/null 2>&1 || true
      pkill -P "${pid}" >/dev/null 2>&1 || true
      wait "${pid}" >/dev/null 2>&1 || true
    fi
  done
  log "Exiting with code ${ec}"
  log "Run dir: ${RUN_DIR}"
}
trap cleanup EXIT

require_file() {
  local f="$1"
  if [[ ! -f "${f}" ]]; then
    echo "[ERROR] Required file not found: ${f}" >&2
    exit 1
  fi
}

require_cmd() {
  local c="$1"
  if ! command -v "${c}" >/dev/null 2>&1; then
    echo "[ERROR] Required command not found: ${c}" >&2
    exit 1
  fi
}

list_idle_gpus() {
  nvidia-smi --query-gpu=index,memory.used --format=csv,noheader,nounits \
    | awk -F',' -v t="${IDLE_GPU_MEMORY_THRESHOLD_MIB}" '{
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1);
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2);
        if (($2 + 0) <= t) print $1;
      }'
}

assign_idle_gpus() {
  if [[ "${AUTO_SELECT_IDLE_GPUS}" != "1" ]]; then
    return 0
  fi

  local -a idle_gpus
  mapfile -t idle_gpus < <(list_idle_gpus)

  if [[ -z "${GPU_A}" ]]; then
    if [[ "${#idle_gpus[@]}" -lt 1 ]]; then
      echo "[ERROR] No idle GPU found (threshold=${IDLE_GPU_MEMORY_THRESHOLD_MIB} MiB)." >&2
      exit 1
    fi
    GPU_A="${idle_gpus[0]}"
  fi

  if [[ -z "${GPU_B}" ]]; then
    local g
    for g in "${idle_gpus[@]}"; do
      if [[ "${g}" != "${GPU_A}" ]]; then
        GPU_B="${g}"
        break
      fi
    done
    if [[ -z "${GPU_B}" ]]; then
      echo "[ERROR] Need 2 idle GPUs, but only one is available (selected GPU_A=${GPU_A})." >&2
      echo "        Free up another GPU or set GPU_A/GPU_B manually." >&2
      exit 1
    fi
  fi

  if [[ "${GPU_A}" == "${GPU_B}" ]]; then
    echo "[ERROR] GPU_A and GPU_B cannot be the same: ${GPU_A}" >&2
    exit 1
  fi
}

wait_for_url() {
  local url="$1"
  local timeout="$2"
  local pid="$3"
  local start_ts
  start_ts="$(date +%s)"

  while true; do
    if curl -fsS --max-time 3 "${url}" >/dev/null 2>&1; then
      return 0
    fi

    if [[ -n "${pid}" ]] && ! kill -0 "${pid}" >/dev/null 2>&1; then
      return 1
    fi

    local now_ts
    now_ts="$(date +%s)"
    if (( now_ts - start_ts >= timeout )); then
      return 1
    fi
    sleep 2
  done
}

main() {
  require_file "${RUN_LMCACHE_OFFLOAD_INSTANCE}"
  require_file "${LMCACHE_CONFIG_FILE_A}"
  require_file "${LMCACHE_CONFIG_FILE_B}"
  if [[ "${AUTO_SELECT_IDLE_GPUS}" == "1" ]]; then
    require_cmd nvidia-smi
  fi

  assign_idle_gpus
  log "GPU assignment: A=${GPU_A}, B=${GPU_B}, auto_select=${AUTO_SELECT_IDLE_GPUS}, idle_threshold=${IDLE_GPU_MEMORY_THRESHOLD_MIB}MiB"

  log "Starting instance A at ${HOST_A}:${PORT_A} (GPU ${GPU_A})"
  (
    GPU="${GPU_A}" \
    HOST="${HOST_A}" \
    PORT="${PORT_A}" \
    SERVED_NAME="${SERVED_NAME_A}" \
    LMCACHE_CONFIG_FILE="${LMCACHE_CONFIG_FILE_A}" \
    LMCACHE_INSTANCE_NAME="${LMCACHE_INSTANCE_NAME_A}" \
    bash "${RUN_LMCACHE_OFFLOAD_INSTANCE}"
  ) >"${SERVER_A_LOG}" 2>&1 &
  PID_A=$!

  log "Starting instance B at ${HOST_B}:${PORT_B} (GPU ${GPU_B})"
  (
    GPU="${GPU_B}" \
    HOST="${HOST_B}" \
    PORT="${PORT_B}" \
    SERVED_NAME="${SERVED_NAME_B}" \
    LMCACHE_CONFIG_FILE="${LMCACHE_CONFIG_FILE_B}" \
    LMCACHE_INSTANCE_NAME="${LMCACHE_INSTANCE_NAME_B}" \
    bash "${RUN_LMCACHE_OFFLOAD_INSTANCE}"
  ) >"${SERVER_B_LOG}" 2>&1 &
  PID_B=$!

  log "Waiting for A readiness"
  if ! wait_for_url "http://${HOST_A}:${PORT_A}/v1/models" "${STARTUP_TIMEOUT_SECS}" "${PID_A}"; then
    log "[ERROR] Instance A failed to become ready"
    log "See ${SERVER_A_LOG}"
    exit 1
  fi

  log "Waiting for B readiness"
  if ! wait_for_url "http://${HOST_B}:${PORT_B}/v1/models" "${STARTUP_TIMEOUT_SECS}" "${PID_B}"; then
    log "[ERROR] Instance B failed to become ready"
    log "See ${SERVER_B_LOG}"
    exit 1
  fi

  log "Both instances are ready"
  log "A: http://${HOST_A}:${PORT_A}/v1/models (pid=${PID_A})"
  log "B: http://${HOST_B}:${PORT_B}/v1/models (pid=${PID_B})"
  log "Press Ctrl+C to stop both instances"

  wait "${PID_A}" "${PID_B}"
}

main "$@"
