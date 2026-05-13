#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KV_OFFLOAD_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

RUN_LMCACHE_OFFLOAD="${RUN_LMCACHE_OFFLOAD:-${KV_OFFLOAD_ROOT}/scripts/run_lmcache_offload.sh}"
RUN_EVALSCOPE_PERF="${RUN_EVALSCOPE_PERF:-${KV_OFFLOAD_ROOT}/scripts/run_evalscope_perf_random_case.sh}"
SLEEP_WAKE_CLI="${SLEEP_WAKE_CLI:-${KV_OFFLOAD_ROOT}/scripts/vllm_sleep_wake_cli.py}"

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-12358}"
BASE_URL="${BASE_URL:-http://${HOST}:${PORT}}"
MODELS_URL="${MODELS_URL:-${BASE_URL}/v1/models}"

STARTUP_TIMEOUT_SECS="${STARTUP_TIMEOUT_SECS:-300}"
SLEEP_LEVEL="${SLEEP_LEVEL:-1}"
SLEEP_MODE="${SLEEP_MODE:-wait}"
WAKE_TAGS="${WAKE_TAGS:-weights kv_cache}"

# Perf defaults tuned for repeatability and observable TTFT deltas.
PERF_PARALLEL="${PERF_PARALLEL:-1}"
PERF_NUMBER="${PERF_NUMBER:-20}"
PERF_REPEAT="${PERF_REPEAT:-1}"
PERF_FIXED_DATASET="${PERF_FIXED_DATASET:-1}"
PERF_FIXED_DATASET_REGENERATE="${PERF_FIXED_DATASET_REGENERATE:-0}"

# Root output directory for this e2e run.
E2E_OUTPUT_ROOT="${E2E_OUTPUT_ROOT:-${KV_OFFLOAD_ROOT}/outputs/e2e_lmcache}"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${E2E_OUTPUT_ROOT}/${RUN_TS}"
EVAL_OUTPUT_ROOT="${RUN_DIR}/evalscope"
PERF_FIXED_DATASET_DIR="${PERF_FIXED_DATASET_DIR:-${KV_OFFLOAD_ROOT}/data/custom_gen}"
RESULTS_CSV="${RUN_DIR}/metrics.csv"
CHECKS_LOG="${RUN_DIR}/checks.log"
SERVER_LOG="${RUN_DIR}/server.log"

SERVER_PID=""

mkdir -p "${RUN_DIR}" "${EVAL_OUTPUT_ROOT}" "${PERF_FIXED_DATASET_DIR}"

log() {
  local msg="$*"
  echo "[$(date +'%F %T')] ${msg}" | tee -a "${CHECKS_LOG}"
}

cleanup() {
  local exit_code=$?
  if [[ -n "${SERVER_PID}" ]] && kill -0 "${SERVER_PID}" >/dev/null 2>&1; then
    log "Stopping server pid=${SERVER_PID}"
    kill "${SERVER_PID}" >/dev/null 2>&1 || true
    pkill -P "${SERVER_PID}" >/dev/null 2>&1 || true
    wait "${SERVER_PID}" >/dev/null 2>&1 || true
  fi
  log "E2E finished with exit code ${exit_code}"
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

wait_for_service() {
  local timeout="$1"
  local start_ts
  start_ts="$(date +%s)"

  while true; do
    if curl -fsS --max-time 3 "${MODELS_URL}" >/dev/null 2>&1; then
      return 0
    fi

    if [[ -n "${SERVER_PID}" ]] && ! kill -0 "${SERVER_PID}" >/dev/null 2>&1; then
      log "Server process exited early; see ${SERVER_LOG}"
      return 1
    fi

    local now_ts
    now_ts="$(date +%s)"
    if (( now_ts - start_ts >= timeout )); then
      log "Service did not become ready within ${timeout}s"
      return 1
    fi
    sleep 2
  done
}

extract_metrics_from_summary() {
  local label="$1"
  local summary_file="$2"
  python3 - "$label" "$summary_file" <<'PY'
import csv
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
  local case_dir="${RUN_DIR}/${label}"
  local eval_outputs="${EVAL_OUTPUT_ROOT}/${label}"
  local run_log="${case_dir}/evalscope.log"
  mkdir -p "${case_dir}" "${eval_outputs}"

  log "Running perf case: ${label}"

  # Keep seed and fixed dataset to make case1/case2/case3 comparable.
  (
    OUTPUTS_DIR="${eval_outputs}" \
    URL="${BASE_URL}/v1/chat/completions" \
    PARALLEL="${PERF_PARALLEL}" \
    NUMBER="${PERF_NUMBER}" \
    REPEAT="${PERF_REPEAT}" \
    FIXED_DATASET="${PERF_FIXED_DATASET}" \
    FIXED_DATASET_DIR="${PERF_FIXED_DATASET_DIR}" \
    FIXED_DATASET_REGENERATE="${PERF_FIXED_DATASET_REGENERATE}" \
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

trigger_sleep_wake() {
  log "Triggering sleep(level=${SLEEP_LEVEL}, mode=${SLEEP_MODE})"
  python3 "${SLEEP_WAKE_CLI}" --base-url "${BASE_URL}" sleep --level "${SLEEP_LEVEL}" --mode "${SLEEP_MODE}" \
    >"${RUN_DIR}/sleep_response.json" 2>&1

  log "Triggering wake(tags=${WAKE_TAGS})"
  local wake_args=()
  local tag
  for tag in ${WAKE_TAGS}; do
    wake_args+=(--tag "${tag}")
  done
  python3 "${SLEEP_WAKE_CLI}" --base-url "${BASE_URL}" wake "${wake_args[@]}" \
    >"${RUN_DIR}/wake_response.json" 2>&1

  # Ensure service is back after wake.
  wait_for_service 120
}

main() {
  require_file "${RUN_LMCACHE_OFFLOAD}"
  require_file "${RUN_EVALSCOPE_PERF}"
  require_file "${SLEEP_WAKE_CLI}"
  require_cmd curl
  require_cmd python3

  echo "label,avg_lat_s,p99_lat_s,avg_ttft_ms,p99_ttft_ms,avg_tpot_ms,p99_tpot_ms" > "${RESULTS_CSV}"

  log "E2E run dir: ${RUN_DIR}"
  log "Shared fixed dataset dir: ${PERF_FIXED_DATASET_DIR}"
  log "Starting LMCache offload service via ${RUN_LMCACHE_OFFLOAD}"

  (
    HOST="${HOST}" PORT="${PORT}" \
    bash "${RUN_LMCACHE_OFFLOAD}"
  ) >"${SERVER_LOG}" 2>&1 &
  SERVER_PID=$!
  log "Server pid=${SERVER_PID}, log=${SERVER_LOG}"

  log "Waiting for service readiness: ${MODELS_URL}"
  wait_for_service "${STARTUP_TIMEOUT_SECS}"
  log "Service is ready"

  run_perf_case "case1_cold_start"
  run_perf_case "case2_cache_hit"

  trigger_sleep_wake

  run_perf_case "case3_after_sleep_wake"

  log "All perf runs finished"
  log "Metrics CSV: ${RESULTS_CSV}"
  log "Server log: ${SERVER_LOG}"
}

main "$@"
