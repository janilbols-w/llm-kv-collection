#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KV_OFFLOAD_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

RUN_LMCACHE_OFFLOAD="${RUN_LMCACHE_OFFLOAD:-${KV_OFFLOAD_ROOT}/scripts/run_lmcache_offload.sh}"
RUN_EVALSCOPE_PERF="${RUN_EVALSCOPE_PERF:-${KV_OFFLOAD_ROOT}/scripts/run_evalscope_perf_random_case.sh}"
RUN_REDIS_REMOTE_SERVER="${RUN_REDIS_REMOTE_SERVER:-${KV_OFFLOAD_ROOT}/scripts/run_redis_remote_server.sh}"
RUN_MOONCAKE_REMOTE_SERVER="${RUN_MOONCAKE_REMOTE_SERVER:-${KV_OFFLOAD_ROOT}/scripts/run_mooncake_remote_server.sh}"
RUN_CLEANUP_VLLM_RESIDUAL="${RUN_CLEANUP_VLLM_RESIDUAL:-${KV_OFFLOAD_ROOT}/scripts/cleanup_vllm_residual.sh}"
SLEEP_WAKE_CLI="${SLEEP_WAKE_CLI:-${KV_OFFLOAD_ROOT}/scripts/vllm_sleep_wake_cli.py}"

HOST_A="${HOST_A:-127.0.0.1}"
PORT_A="${PORT_A:-12358}"
BASE_URL_A="http://${HOST_A}:${PORT_A}"
SERVED_NAME_A="${SERVED_NAME_A:-mymodel-a}"
LMCACHE_CONFIG_FILE_A="${LMCACHE_CONFIG_FILE_A:-}"
GPU_A="${GPU_A:-}"

HOST_B="${HOST_B:-127.0.0.1}"
PORT_B="${PORT_B:-12359}"
BASE_URL_B="http://${HOST_B}:${PORT_B}"
SERVED_NAME_B="${SERVED_NAME_B:-mymodel-b}"
LMCACHE_CONFIG_FILE_B="${LMCACHE_CONFIG_FILE_B:-}"
GPU_B="${GPU_B:-}"

# Startup mode.
# 1: script starts A/B locally (single-node default)
# 0: use externally started A/B instances (multi-node manual deployment)
START_INSTANCES="${START_INSTANCES:-1}"

AUTO_SELECT_IDLE_GPUS="${AUTO_SELECT_IDLE_GPUS:-1}"
IDLE_GPU_MEMORY_THRESHOLD_MIB="${IDLE_GPU_MEMORY_THRESHOLD_MIB:-512}"

STARTUP_TIMEOUT_SECS="${STARTUP_TIMEOUT_SECS:-300}"
SLEEP_WAKE_TIMEOUT_SECS="${SLEEP_WAKE_TIMEOUT_SECS:-120}"
SLEEP_LEVEL="${SLEEP_LEVEL:-1}"
SLEEP_MODE="${SLEEP_MODE:-wait}"
WAKE_TAGS="${WAKE_TAGS:-weights kv_cache}"

PERF_PARALLEL="${PERF_PARALLEL:-1}"
PERF_NUMBER="${PERF_NUMBER:-20}"
PERF_REPEAT="${PERF_REPEAT:-1}"
PERF_FIXED_DATASET="${PERF_FIXED_DATASET:-1}"
PERF_FIXED_DATASET_REGENERATE="${PERF_FIXED_DATASET_REGENERATE:-0}"
PERF_FIXED_DATASET_DIR="${PERF_FIXED_DATASET_DIR:-${KV_OFFLOAD_ROOT}/data/custom_gen}"
# Multi-turn dataset controls (forwarded to run_evalscope_perf_random_case.sh).
PERF_MULTI_TURN="${PERF_MULTI_TURN:-0}"
PERF_MIN_TURNS="${PERF_MIN_TURNS:-2}"
PERF_MAX_TURNS="${PERF_MAX_TURNS:-10}"
PERF_FIXED_TURNS="${PERF_FIXED_TURNS:-}"
PERF_FIXED_TURN_LENGTH="${PERF_FIXED_TURN_LENGTH:-}"

# Enforce shared remote backend by default for cross-instance reuse validation.
REQUIRE_REMOTE_BACKEND="${REQUIRE_REMOTE_BACKEND:-1}"
# Remote backend selection: redis | mooncake.
# Mismatch with config remote_url fails fast.
REMOTE_BACKEND_TYPE="${REMOTE_BACKEND_TYPE:-redis}" # mooncake, redis
# Auto manage selected remote backend lifecycle.
AUTO_MANAGE_REMOTE_BACKEND="${AUTO_MANAGE_REMOTE_BACKEND:-1}"
# Run residual cleanup script on exit.
AUTO_CLEANUP_VLLM_RESIDUAL="${AUTO_CLEANUP_VLLM_RESIDUAL:-1}"

OUTPUT_ROOT="${OUTPUT_ROOT:-${KV_OFFLOAD_ROOT}/outputs/e2e_lmcache_cross_instance}"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${OUTPUT_ROOT}/${RUN_TS}"
EVAL_OUTPUT_ROOT="${RUN_DIR}/evalscope"
RESULTS_CSV="${RUN_DIR}/metrics.csv"
CHECKS_LOG="${RUN_DIR}/checks.log"
SERVER_A_LOG="${RUN_DIR}/server_a.log"
SERVER_B_LOG="${RUN_DIR}/server_b.log"

PID_A=""
PID_B=""
REMOTE_BACKEND_ENDPOINT=""
REMOTE_BACKEND_STARTED_BY_E2E="0"

mkdir -p "${RUN_DIR}" "${EVAL_OUTPUT_ROOT}" "${PERF_FIXED_DATASET_DIR}"

log() {
  local msg="$*"
  echo "[$(date +'%F %T')] ${msg}" | tee -a "${CHECKS_LOG}"
}

log_effective_inputs() {
  log "Effective input parameters:"
  log "  START_INSTANCES=${START_INSTANCES} AUTO_SELECT_IDLE_GPUS=${AUTO_SELECT_IDLE_GPUS} IDLE_GPU_MEMORY_THRESHOLD_MIB=${IDLE_GPU_MEMORY_THRESHOLD_MIB}"
  log "  HOST_A=${HOST_A} PORT_A=${PORT_A} SERVED_NAME_A=${SERVED_NAME_A} GPU_A=${GPU_A:-<auto>}"
  log "  HOST_B=${HOST_B} PORT_B=${PORT_B} SERVED_NAME_B=${SERVED_NAME_B} GPU_B=${GPU_B:-<auto>}"
  log "  LMCACHE_CONFIG_FILE_A=${LMCACHE_CONFIG_FILE_A}"
  log "  LMCACHE_CONFIG_FILE_B=${LMCACHE_CONFIG_FILE_B}"
  log "  REMOTE_BACKEND_TYPE=${REMOTE_BACKEND_TYPE} AUTO_MANAGE_REMOTE_BACKEND=${AUTO_MANAGE_REMOTE_BACKEND} REQUIRE_REMOTE_BACKEND=${REQUIRE_REMOTE_BACKEND}"
  log "  STARTUP_TIMEOUT_SECS=${STARTUP_TIMEOUT_SECS} SLEEP_WAKE_TIMEOUT_SECS=${SLEEP_WAKE_TIMEOUT_SECS}"
  log "  SLEEP_LEVEL=${SLEEP_LEVEL} SLEEP_MODE=${SLEEP_MODE} WAKE_TAGS='${WAKE_TAGS}'"
  log "  PERF_PARALLEL=${PERF_PARALLEL} PERF_NUMBER=${PERF_NUMBER} PERF_REPEAT=${PERF_REPEAT}"
  log "  PERF_FIXED_DATASET=${PERF_FIXED_DATASET} PERF_FIXED_DATASET_REGENERATE=${PERF_FIXED_DATASET_REGENERATE} PERF_FIXED_DATASET_DIR=${PERF_FIXED_DATASET_DIR}"
  log "  PERF_MULTI_TURN=${PERF_MULTI_TURN} PERF_MIN_TURNS=${PERF_MIN_TURNS} PERF_MAX_TURNS=${PERF_MAX_TURNS} PERF_FIXED_TURNS=${PERF_FIXED_TURNS:-<auto>} PERF_FIXED_TURN_LENGTH=${PERF_FIXED_TURN_LENGTH:-<auto>}"
  log "  OUTPUT_ROOT=${OUTPUT_ROOT} RUN_DIR=${RUN_DIR}"
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

  if [[ "${REMOTE_BACKEND_STARTED_BY_E2E}" == "1" ]]; then
    local backend_host backend_port
    backend_host="${REMOTE_BACKEND_ENDPOINT%%:*}"
    backend_port="${REMOTE_BACKEND_ENDPOINT##*:}"

    if [[ "${REMOTE_BACKEND_TYPE}" == "redis" ]]; then
      log "Stopping Redis remote backend ${backend_host}:${backend_port}"
      if ! REDIS_HOST="${backend_host}" REDIS_PORT="${backend_port}" bash "${RUN_REDIS_REMOTE_SERVER}" stop >/dev/null 2>&1; then
        log "[WARN] Failed to stop Redis backend cleanly (${backend_host}:${backend_port})"
      fi
    elif [[ "${REMOTE_BACKEND_TYPE}" == "mooncake" ]]; then
      log "Stopping Mooncake remote backend ${backend_host}:${backend_port}"
      if ! MOONCAKE_HOST="${backend_host}" MOONCAKE_MASTER_PORT="${backend_port}" bash "${RUN_MOONCAKE_REMOTE_SERVER}" stop >/dev/null 2>&1; then
        log "[WARN] Failed to stop Mooncake backend cleanly (${backend_host}:${backend_port})"
      fi
    else
      log "[WARN] Unknown backend type during cleanup: REMOTE_BACKEND_TYPE='${REMOTE_BACKEND_TYPE}'"
    fi
  fi

  if [[ "${START_INSTANCES}" == "1" && "${AUTO_CLEANUP_VLLM_RESIDUAL}" == "1" ]]; then
    local cleanup_ports
    cleanup_ports="${PORT_A},${PORT_B}"
    log "Running residual vLLM cleanup for ports: ${cleanup_ports}"
    if ! bash "${RUN_CLEANUP_VLLM_RESIDUAL}" --ports "${cleanup_ports}" >/dev/null 2>&1; then
      log "[WARN] cleanup_vllm_residual failed: ${RUN_CLEANUP_VLLM_RESIDUAL} --ports ${cleanup_ports}"
    fi
  fi

  log "E2E finished with exit code ${ec}"
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

resolve_lmcache_config_files() {
  local config_subdir
  case "${REMOTE_BACKEND_TYPE}" in
    redis)
      config_subdir="redis"
      ;;
    mooncake)
      config_subdir="mooncacke"
      ;;
    *)
      echo "[ERROR] Invalid REMOTE_BACKEND_TYPE='${REMOTE_BACKEND_TYPE}', expected: redis|mooncake" >&2
      exit 1
      ;;
  esac

  if [[ -z "${LMCACHE_CONFIG_FILE_A}" ]]; then
    LMCACHE_CONFIG_FILE_A="${KV_OFFLOAD_ROOT}/config/${config_subdir}/lmcahce.instance_a.yaml"
  fi

  if [[ -z "${LMCACHE_CONFIG_FILE_B}" ]]; then
    LMCACHE_CONFIG_FILE_B="${KV_OFFLOAD_ROOT}/config/${config_subdir}/lmcahce.instance_b.yaml"
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

get_remote_url_from_cfg() {
  local cfg="$1"
  python3 - "$cfg" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="ignore").splitlines()
for line in text:
    s = line.strip()
    if not s.startswith("remote_url:"):
        continue
    value = s.split(":", 1)[1].strip()
    if value.startswith('"') and value.endswith('"') and len(value) >= 2:
        value = value[1:-1]
    if value.startswith("'") and value.endswith("'") and len(value) >= 2:
        value = value[1:-1]
    print(value)
    break
else:
    print("")
PY
}

validate_remote_backend() {
  local remote_a remote_b
  remote_a="$(get_remote_url_from_cfg "${LMCACHE_CONFIG_FILE_A}")"
  remote_b="$(get_remote_url_from_cfg "${LMCACHE_CONFIG_FILE_B}")"

  log "Config A remote_url='${remote_a}'"
  log "Config B remote_url='${remote_b}'"

  if [[ "${REQUIRE_REMOTE_BACKEND}" != "1" ]]; then
    return 0
  fi

  if [[ -z "${remote_a}" || -z "${remote_b}" || "${remote_a}" == "null" || "${remote_b}" == "null" ]]; then
    echo "[ERROR] Cross-instance reuse requires shared remote_url in both configs." >&2
    echo "        Set remote_url (e.g. resp://127.0.0.1:7379) in:" >&2
    echo "        ${LMCACHE_CONFIG_FILE_A}" >&2
    echo "        ${LMCACHE_CONFIG_FILE_B}" >&2
    exit 1
  fi

  if [[ "${remote_a}" != "${remote_b}" ]]; then
    echo "[ERROR] Config A/B remote_url mismatch for cross-instance reuse." >&2
    echo "        A: ${remote_a}" >&2
    echo "        B: ${remote_b}" >&2
    exit 1
  fi

  # Enforce backend type policy at config validation stage (independent of
  # AUTO_MANAGE_REMOTE_BACKEND). If REMOTE_BACKEND_TYPE is explicit
  # (redis/mooncake), remote_url must match it.
  if ! resolve_remote_backend_target "${REMOTE_BACKEND_TYPE}" "${remote_a}" >/dev/null; then
    echo "[ERROR] REMOTE_BACKEND_TYPE and config remote_url are inconsistent." >&2
    echo "        REMOTE_BACKEND_TYPE=${REMOTE_BACKEND_TYPE}" >&2
    echo "        remote_url=${remote_a}" >&2
    exit 1
  fi

  echo "${remote_a}"
}

parse_resp_remote_url() {
  local url="$1"
  python3 - "$url" <<'PY'
import sys
from urllib.parse import urlparse

u = urlparse(sys.argv[1])
if u.scheme != "resp" or not u.hostname:
    print("", end="")
    sys.exit(0)

port = u.port or 6379
print(f"{u.hostname}:{port}", end="")
PY
}

parse_mooncakestore_remote_url() {
  local url="$1"
  python3 - "$url" <<'PY'
import sys
from urllib.parse import urlparse

u = urlparse(sys.argv[1])
if u.scheme != "mooncakestore" or not u.hostname:
    print("", end="")
    sys.exit(0)

port = u.port or 50051
print(f"{u.hostname}:{port}", end="")
PY
}

resolve_remote_backend_target() {
  local forced_type="$1"
  local remote_url="$2"

  local redis_host_port mooncake_host_port
  redis_host_port="$(parse_resp_remote_url "${remote_url}")"
  mooncake_host_port="$(parse_mooncakestore_remote_url "${remote_url}")"

  case "${forced_type}" in
    redis)
      if [[ -z "${redis_host_port}" ]]; then
        echo "[ERROR] REMOTE_BACKEND_TYPE=redis requires remote_url with resp:// scheme, got '${remote_url}'" >&2
        return 1
      fi
      echo "redis:${redis_host_port}"
      return 0
      ;;
    mooncake)
      if [[ -z "${mooncake_host_port}" ]]; then
        echo "[ERROR] REMOTE_BACKEND_TYPE=mooncake requires remote_url with mooncakestore:// scheme, got '${remote_url}'" >&2
        return 1
      fi
      echo "mooncake:${mooncake_host_port}"
      return 0
      ;;
    *)
      echo "[ERROR] Invalid REMOTE_BACKEND_TYPE='${forced_type}', expected: redis|mooncake" >&2
      return 1
      ;;
  esac
}

is_port_listening() {
  local host="$1"
  local port="$2"

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$host" "$port" <<'PY'
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

start_remote_backend_if_needed() {
  local remote_url="$1"
  local backend_target backend_kind endpoint

  if [[ "${AUTO_MANAGE_REMOTE_BACKEND}" != "1" ]]; then
    log "AUTO_MANAGE_REMOTE_BACKEND=0, skip backend lifecycle management"
    return 0
  fi

  backend_target="$(resolve_remote_backend_target "${REMOTE_BACKEND_TYPE}" "${remote_url}")" || exit 1
  backend_kind="${backend_target%%:*}"
  endpoint="${backend_target#*:}"

  REMOTE_BACKEND_ENDPOINT="${endpoint}"

  local backend_host backend_port
  backend_host="${endpoint%%:*}"
  backend_port="${endpoint##*:}"

  if [[ "${REMOTE_BACKEND_TYPE}" == "redis" ]]; then
    require_file "${RUN_REDIS_REMOTE_SERVER}"

    if is_port_listening "${backend_host}" "${backend_port}"; then
      log "Redis backend already listening on ${backend_host}:${backend_port}; reusing existing service"
      return 0
    fi

    log "Starting Redis remote backend on ${backend_host}:${backend_port}"
    REDIS_HOST="${backend_host}" REDIS_PORT="${backend_port}" bash "${RUN_REDIS_REMOTE_SERVER}" start >/dev/null

    if ! is_port_listening "${backend_host}" "${backend_port}"; then
      log "[ERROR] Redis backend failed to start on ${backend_host}:${backend_port}"
      exit 1
    fi

    REMOTE_BACKEND_STARTED_BY_E2E="1"
    log "Redis backend is ready on ${backend_host}:${backend_port}"
    return 0
  fi

  require_file "${RUN_MOONCAKE_REMOTE_SERVER}"

  if is_port_listening "${backend_host}" "${backend_port}"; then
    log "Mooncake backend already listening on ${backend_host}:${backend_port}; reusing existing service"
    return 0
  fi

  log "Starting Mooncake remote backend on ${backend_host}:${backend_port}"
  MOONCAKE_HOST="${backend_host}" MOONCAKE_MASTER_PORT="${backend_port}" bash "${RUN_MOONCAKE_REMOTE_SERVER}" start >/dev/null

  if ! is_port_listening "${backend_host}" "${backend_port}"; then
    log "[ERROR] Mooncake backend failed to start on ${backend_host}:${backend_port}"
    exit 1
  fi

  REMOTE_BACKEND_STARTED_BY_E2E="1"
  log "Mooncake backend is ready on ${backend_host}:${backend_port}"
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

extract_metrics_from_summary() {
  local label="$1"
  local summary_file="$2"
  python3 - "$label" "$summary_file" <<'PY'
import sys

label = sys.argv[1]
path = sys.argv[2]

row = None
with open(path, "r", encoding="utf-8", errors="ignore") as f:
    for line in f:
        if "│" not in line:
            continue
        parts = [p.strip() for p in line.split("│")[1:-1]]
        if len(parts) < 12:
            continue
        if parts[0].isdigit() and parts[2].isdigit():
            row = parts
            break

if row is None:
    print(f"{label},NA,NA,NA,NA,NA,NA", end="")
    sys.exit(0)

avg_lat_s = row[4]
p99_lat_s = row[5]
avg_ttft_ms = row[6]
p99_ttft_ms = row[7]
avg_tpot_ms = row[8]
p99_tpot_ms = row[9]

print(
    f"{label},{avg_lat_s},{p99_lat_s},{avg_ttft_ms},{p99_ttft_ms},{avg_tpot_ms},{p99_tpot_ms}",
    end="",
)
PY
}

run_perf_case() {
  local label="$1"
  local target_base_url="$2"
  local target_model="$3"
  local case_dir="${RUN_DIR}/${label}"
  local eval_outputs="${EVAL_OUTPUT_ROOT}/${label}"
  local run_log="${case_dir}/evalscope.log"

  mkdir -p "${case_dir}" "${eval_outputs}"

  log "Running perf case: ${label} -> ${target_base_url} (model=${target_model})"

  (
    MODEL="${target_model}" \
    OUTPUTS_DIR="${eval_outputs}" \
    URL="${target_base_url}/v1/chat/completions" \
    PARALLEL="${PERF_PARALLEL}" \
    NUMBER="${PERF_NUMBER}" \
    REPEAT="${PERF_REPEAT}" \
    MULTI_TURN="${PERF_MULTI_TURN}" \
    MIN_TURNS="${PERF_MIN_TURNS}" \
    MAX_TURNS="${PERF_MAX_TURNS}" \
    FIXED_DATASET="${PERF_FIXED_DATASET}" \
    FIXED_DATASET_DIR="${PERF_FIXED_DATASET_DIR}" \
    FIXED_DATASET_REGENERATE="${PERF_FIXED_DATASET_REGENERATE}" \
    FIXED_TURNS="${PERF_FIXED_TURNS}" \
    FIXED_TURN_LENGTH="${PERF_FIXED_TURN_LENGTH}" \
    bash "${RUN_EVALSCOPE_PERF}"
  ) >"${run_log}" 2>&1

  local summary_file
  summary_file="$(find "${eval_outputs}" -type f -name 'performance_summary.txt' | sort | tail -n 1)"
  if [[ -z "${summary_file}" ]]; then
    log "[ERROR] Could not find performance_summary.txt for ${label}; see ${run_log}"
    return 1
  fi

  cp "${summary_file}" "${case_dir}/performance_summary.txt"

  local metric_row
  metric_row="$(extract_metrics_from_summary "${label}" "${summary_file}")"
  echo "${metric_row}" >> "${RESULTS_CSV}"
  log "${label} metrics: ${metric_row}"
}

trigger_sleep_wake_instance() {
  local instance_label="$1"
  local target_base_url="$2"
  local target_pid="$3"
  local out_dir="${RUN_DIR}/sleep_wake_${instance_label}"

  mkdir -p "${out_dir}"

  log "[${instance_label}] Triggering sleep(level=${SLEEP_LEVEL}, mode=${SLEEP_MODE})"
  python3 "${SLEEP_WAKE_CLI}" \
    --base-url "${target_base_url}" \
    sleep \
    --level "${SLEEP_LEVEL}" \
    --mode "${SLEEP_MODE}" \
    >"${out_dir}/sleep_response.json" 2>&1

  log "[${instance_label}] Triggering wake(tags=${WAKE_TAGS})"
  local wake_args=()
  local tag
  for tag in ${WAKE_TAGS}; do
    wake_args+=(--tag "${tag}")
  done
  python3 "${SLEEP_WAKE_CLI}" \
    --base-url "${target_base_url}" \
    wake "${wake_args[@]}" \
    >"${out_dir}/wake_response.json" 2>&1

  log "[${instance_label}] Waiting for service readiness after wake"
  if ! wait_for_url "${target_base_url}/v1/models" "${SLEEP_WAKE_TIMEOUT_SECS}" "${target_pid}"; then
    log "[ERROR] ${instance_label} failed to become ready after sleep/wake"
    return 1
  fi
}

start_instances() {
  log "Starting instance A at ${BASE_URL_A} (GPU ${GPU_A})"
  (
    CUDA_VISIBLE_DEVICES="${GPU_A}" \
    HOST="${HOST_A}" \
    PORT="${PORT_A}" \
    SERVED_NAME="${SERVED_NAME_A}" \
    LMCACHE_CONFIG_FILE="${LMCACHE_CONFIG_FILE_A}" \
    bash "${RUN_LMCACHE_OFFLOAD}"
  ) >"${SERVER_A_LOG}" 2>&1 &
  PID_A=$!

  log "Starting instance B at ${BASE_URL_B} (GPU ${GPU_B})"
  (
    CUDA_VISIBLE_DEVICES="${GPU_B}" \
    HOST="${HOST_B}" \
    PORT="${PORT_B}" \
    SERVED_NAME="${SERVED_NAME_B}" \
    LMCACHE_CONFIG_FILE="${LMCACHE_CONFIG_FILE_B}" \
    bash "${RUN_LMCACHE_OFFLOAD}"
  ) >"${SERVER_B_LOG}" 2>&1 &
  PID_B=$!

  log "Waiting for A readiness"
  if ! wait_for_url "${BASE_URL_A}/v1/models" "${STARTUP_TIMEOUT_SECS}" "${PID_A}"; then
    log "[ERROR] A failed to become ready. See ${SERVER_A_LOG}"
    exit 1
  fi

  log "Waiting for B readiness"
  if ! wait_for_url "${BASE_URL_B}/v1/models" "${STARTUP_TIMEOUT_SECS}" "${PID_B}"; then
    log "[ERROR] B failed to become ready. See ${SERVER_B_LOG}"
    exit 1
  fi

  log "Both instances are ready"
}

main() {
  resolve_lmcache_config_files

  if [[ "${START_INSTANCES}" == "1" ]]; then
    require_file "${RUN_LMCACHE_OFFLOAD}"
  fi
  require_file "${RUN_EVALSCOPE_PERF}"
  require_file "${SLEEP_WAKE_CLI}"
  require_file "${LMCACHE_CONFIG_FILE_A}"
  require_file "${LMCACHE_CONFIG_FILE_B}"
  if [[ "${START_INSTANCES}" == "1" && "${AUTO_CLEANUP_VLLM_RESIDUAL}" == "1" ]]; then
    require_file "${RUN_CLEANUP_VLLM_RESIDUAL}"
  fi
  require_cmd curl
  require_cmd python3
  if [[ "${START_INSTANCES}" == "1" && "${AUTO_SELECT_IDLE_GPUS}" == "1" ]]; then
    require_cmd nvidia-smi
  fi

  if [[ "${START_INSTANCES}" == "1" ]]; then
    assign_idle_gpus
  fi

  validate_remote_backend

  local shared_remote_url
  shared_remote_url="$(get_remote_url_from_cfg "${LMCACHE_CONFIG_FILE_A}")"

  log_effective_inputs

  echo "label,avg_lat_s,p99_lat_s,avg_ttft_ms,p99_ttft_ms,avg_tpot_ms,p99_tpot_ms" > "${RESULTS_CSV}"

  log "E2E run dir: ${RUN_DIR}"
  log "Shared fixed dataset dir: ${PERF_FIXED_DATASET_DIR}"
  log "Start instances mode: ${START_INSTANCES}"
  log "Dataset preprocess: length_unit=token"
  log "Dataset mode: multi_turn=${PERF_MULTI_TURN}, min_turns=${PERF_MIN_TURNS}, max_turns=${PERF_MAX_TURNS}, fixed_turns=${PERF_FIXED_TURNS:-auto}, fixed_turn_length=${PERF_FIXED_TURN_LENGTH:-auto}"
  if [[ "${START_INSTANCES}" == "1" ]]; then
    log "GPU assignment: A=${GPU_A}, B=${GPU_B}, auto_select=${AUTO_SELECT_IDLE_GPUS}, idle_threshold=${IDLE_GPU_MEMORY_THRESHOLD_MIB}MiB"
  fi
  start_remote_backend_if_needed "${shared_remote_url}"
  if [[ "${START_INSTANCES}" == "1" ]]; then
    start_instances
  else
    log "Using externally started instances; checking readiness"
    if ! wait_for_url "${BASE_URL_A}/v1/models" "${STARTUP_TIMEOUT_SECS}" ""; then
      log "[ERROR] External instance A not ready: ${BASE_URL_A}"
      exit 1
    fi
    if ! wait_for_url "${BASE_URL_B}/v1/models" "${STARTUP_TIMEOUT_SECS}" ""; then
      log "[ERROR] External instance B not ready: ${BASE_URL_B}"
      exit 1
    fi
    log "External A/B readiness check passed"
  fi

  # 1) Warm shared remote cache on A.
  run_perf_case "case1_a_warm_seed" "${BASE_URL_A}" "${SERVED_NAME_A}"

  # 2) Verify same-instance warm behavior on A.
  run_perf_case "case2_a_after_a_warm" "${BASE_URL_A}" "${SERVED_NAME_A}"

  # 3) Verify cross-instance reuse on B.
  run_perf_case "case3_b_after_a_warm" "${BASE_URL_B}" "${SERVED_NAME_B}"

  # 4) Verify same-instance warm behavior on B.
  run_perf_case "case4_b_after_b_test" "${BASE_URL_B}" "${SERVED_NAME_B}"

  # 5) Sleep/wake both instances, then evaluate A and B again.
  trigger_sleep_wake_instance "a" "${BASE_URL_A}" "${PID_A}"
  trigger_sleep_wake_instance "b" "${BASE_URL_B}" "${PID_B}"

  # 6) Post sleep/wake perf on A and B.
  run_perf_case "case5_a_after_ab_sleep_wake" "${BASE_URL_A}" "${SERVED_NAME_A}"
  run_perf_case "case6_b_after_ab_sleep_wake" "${BASE_URL_B}" "${SERVED_NAME_B}"

  log "All perf runs finished"
  log "Metrics CSV: ${RESULTS_CSV}"
  log "Server A log: ${SERVER_A_LOG}"
  log "Server B log: ${SERVER_B_LOG}"
}

main "$@"
