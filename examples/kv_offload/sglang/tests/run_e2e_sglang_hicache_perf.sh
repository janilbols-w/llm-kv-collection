#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SGLANG_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
KV_OFFLOAD_ROOT="$(cd -- "${SGLANG_ROOT}/.." && pwd)"

RUN_SGLANG_SERVICE="${RUN_SGLANG_SERVICE:-${SGLANG_ROOT}/scripts/run_sglang_service.sh}"
RUN_EVALSCOPE_PERF="${RUN_EVALSCOPE_PERF:-${KV_OFFLOAD_ROOT}/vllm/scripts/run_evalscope_perf_random_case.sh}"

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-12358}"
BASE_URL="${BASE_URL:-http://${HOST}:${PORT}}"
MODELS_URL="${MODELS_URL:-${BASE_URL}/v1/models}"
CHAT_URL="${CHAT_URL:-${BASE_URL}/v1/chat/completions}"

STARTUP_TIMEOUT_SECS="${STARTUP_TIMEOUT_SECS:-300}"
REQUEST_TIMEOUT_SECS="${REQUEST_TIMEOUT_SECS:-900}"

MODEL_PATH="${MODEL_PATH:-/data_ssd1/hz_home/deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B}"
MODEL_NAME="${MODEL_NAME:-mymodel}"
TP="${TP:-1}"
PAGE_SIZE="${PAGE_SIZE:-64}"
MEM_FRACTION_STATIC="${MEM_FRACTION_STATIC:-0.8}"

PERF_FIXED_PROMPT_LENGTH="${PERF_FIXED_PROMPT_LENGTH:-4096}"
PERF_PARALLEL="${PERF_PARALLEL:-1}"
TARGET_NUMBER="${TARGET_NUMBER:-1}"
TARGET_MAX_TOKENS="${TARGET_MAX_TOKENS:-512}"
PERF_FIXED_DATASET="${PERF_FIXED_DATASET:-1}"
PERF_FIXED_DATASET_REGENERATE="${PERF_FIXED_DATASET_REGENERATE:-0}"
PERF_FIXED_DATASET_DIR="${PERF_FIXED_DATASET_DIR:-${KV_OFFLOAD_ROOT}/vllm/data/custom_gen}"

E2E_OUTPUT_ROOT="${E2E_OUTPUT_ROOT:-${SGLANG_ROOT}/outputs/e2e_sglang_hicache_perf}"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${E2E_OUTPUT_ROOT}/${RUN_TS}"
CHECKS_LOG="${RUN_DIR}/checks.log"
REPORT_JSON="${RUN_DIR}/report.json"
RESULTS_CSV="${RUN_DIR}/metrics.csv"

CASE1_DIR="${RUN_DIR}/case1_cold_start"
CASE2_DIR="${RUN_DIR}/case2_cache_hit"
CASE3_DIR="${RUN_DIR}/case3_cold_start"
CASE4_DIR="${RUN_DIR}/case4_cache_hit"

SERVICE_PID=""
mkdir -p "${RUN_DIR}" "${CASE1_DIR}" "${CASE2_DIR}" "${CASE3_DIR}" "${CASE4_DIR}" "${PERF_FIXED_DATASET_DIR}"

log() {
  local msg="$*"
  echo "[$(date +'%F %T')] ${msg}" | tee -a "${CHECKS_LOG}"
}

cleanup() {
  local ec=$?
  stop_service || true
  log "Scenario finished with exit code ${ec}"
  log "Run dir: ${RUN_DIR}"
}
trap cleanup EXIT

stop_service() {
  if [[ -n "${SERVICE_PID}" ]] && kill -0 "${SERVICE_PID}" >/dev/null 2>&1; then
    kill "${SERVICE_PID}" >/dev/null 2>&1 || true
    pkill -P "${SERVICE_PID}" >/dev/null 2>&1 || true
    wait "${SERVICE_PID}" >/dev/null 2>&1 || true
  fi
  SERVICE_PID=""
}

wait_for_service() {
  local timeout="$1"
  local start_ts
  start_ts="$(date +%s)"

  while true; do
    if curl -fsS --max-time 3 "${MODELS_URL}" >/dev/null 2>&1; then
      return 0
    fi

    if [[ -n "${SERVICE_PID}" ]] && ! kill -0 "${SERVICE_PID}" >/dev/null 2>&1; then
      return 1
    fi

    if (( $(date +%s) - start_ts >= timeout )); then
      return 1
    fi

    sleep 2
  done
}

start_sglang_service() {
  local mode="$1"
  local server_log="$2"
  stop_service
  (
    MODE="${mode}" \
    MODEL_PATH="${MODEL_PATH}" \
    SERVED_MODEL_NAME="${MODEL_NAME}" \
    HOST="0.0.0.0" \
    PORT="${PORT}" \
    TP="${TP}" \
    PAGE_SIZE="${PAGE_SIZE}" \
    MEM_FRACTION_STATIC="${MEM_FRACTION_STATIC}" \
    bash "${RUN_SGLANG_SERVICE}"
  ) >"${server_log}" 2>&1 &
  SERVICE_PID=$!
}

run_evalscope_case() {
  local case_outputs="$1"
  local run_log="$2"
  mkdir -p "${case_outputs}"

  (
    OUTPUTS_DIR="${case_outputs}" \
    URL="${CHAT_URL}" \
    MODEL="${MODEL_NAME}" \
    PARALLEL="${PERF_PARALLEL}" \
    NUMBER="${TARGET_NUMBER}" \
    REPEAT="1" \
    MULTI_TURN="1" \
    FIXED_DATASET="${PERF_FIXED_DATASET}" \
    FIXED_DATASET_DIR="${PERF_FIXED_DATASET_DIR}" \
    FIXED_DATASET_REGENERATE="${PERF_FIXED_DATASET_REGENERATE}" \
    FIXED_PROMPT_LENGTH="${PERF_FIXED_PROMPT_LENGTH}" \
    MIN_PROMPT_LENGTH="${PERF_FIXED_PROMPT_LENGTH}" \
    MAX_PROMPT_LENGTH="${PERF_FIXED_PROMPT_LENGTH}" \
    MIN_TOKENS="${TARGET_MAX_TOKENS}" \
    MAX_TOKENS="${TARGET_MAX_TOKENS}" \
    TOTAL_TIMEOUT="${REQUEST_TIMEOUT_SECS}" \
    bash "${RUN_EVALSCOPE_PERF}"
  ) >"${run_log}" 2>&1
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

print(
    f"{label},{row[4]},{row[5]},{row[6]},{row[7]},{row[8]},{row[9]}",
    end="",
)
PY
}

append_group_metrics() {
  local label="$1"
  local group_dir="$2"
  local summary_file

  summary_file="$(find "${group_dir}/evalscope" -type f -name 'performance_summary.txt' | sort | tail -n 1)"
  if [[ -z "${summary_file}" ]]; then
    echo "${label},NA,NA,NA,NA,NA,NA" >>"${RESULTS_CSV}"
    log "[${label}] metrics summary not found; wrote NA row"
    return 0
  fi

  local metric_row
  metric_row="$(extract_metrics_from_summary "${label}" "${summary_file}")"
  echo "${metric_row}" >>"${RESULTS_CSV}"
  log "[${label}] metrics: ${metric_row}"
}

run_case() {
  local mode="$1"
  local case_name="$2"
  local case_dir="$3"
  local eval_log="${case_dir}/evalscope.log"
  local status_file="${case_dir}/status.txt"

  log "[${case_name}] running mode=${mode}"
  local t0
  t0="$(date +%s)"
  if ! run_evalscope_case "${case_dir}/evalscope" "${eval_log}"; then
    local t1
    t1="$(date +%s)"
    echo "status=fail" >"${status_file}"
    echo "reason=evalscope_failed" >>"${status_file}"
    echo "mode=${mode}" >>"${status_file}"
    log "[${case_name}] fail evalscope"
    echo "duration_secs=$((t1 - t0))" >>"${status_file}"
    return 1
  fi

  local t1
  t1="$(date +%s)"
  local duration=$((t1 - t0))

  {
    echo "status=pass"
    echo "duration_secs=${duration}"
    echo "mode=${mode}"
  } >"${status_file}"

  log "[${case_name}] pass duration=${duration}s"
  return 0
}

write_startup_failed_status() {
  local mode="$1"
  local case_dir="$2"
  local status_file="${case_dir}/status.txt"
  {
    echo "status=fail"
    echo "reason=startup_failed"
    echo "mode=${mode}"
  } >"${status_file}"
}

write_report() {
  python3 - "${CASE1_DIR}/status.txt" "${CASE2_DIR}/status.txt" "${CASE3_DIR}/status.txt" "${CASE4_DIR}/status.txt" "${REPORT_JSON}" <<'PY'
import json
import sys
from pathlib import Path

def parse_status(path: str):
    out = {}
    p = Path(path)
    if not p.exists():
        return {"status": "missing"}
    for line in p.read_text(encoding="utf-8", errors="ignore").splitlines():
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip()
    if "status" not in out:
        out["status"] = "unknown"
    return out

report = {
  "case1_cold_start": parse_status(sys.argv[1]),
  "case2_cache_hit": parse_status(sys.argv[2]),
  "case3_cold_start": parse_status(sys.argv[3]),
  "case4_cache_hit": parse_status(sys.argv[4]),
}
Path(sys.argv[5]).write_text(json.dumps(report, indent=2, ensure_ascii=True), encoding="utf-8")
print(json.dumps(report, ensure_ascii=True))
PY
}

main() {
  if ! command -v curl >/dev/null 2>&1; then
    echo "[ERROR] curl not found" >&2
    exit 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "[ERROR] python3 not found" >&2
    exit 1
  fi

  if [[ ! -f "${RUN_SGLANG_SERVICE}" ]]; then
    echo "[ERROR] missing script: ${RUN_SGLANG_SERVICE}" >&2
    exit 1
  fi
  if [[ ! -f "${RUN_EVALSCOPE_PERF}" ]]; then
    echo "[ERROR] missing script: ${RUN_EVALSCOPE_PERF}" >&2
    exit 1
  fi

  log "Run dir: ${RUN_DIR}"
  echo "label,avg_lat_s,p99_lat_s,avg_ttft_ms,p99_ttft_ms,avg_tpot_ms,p99_tpot_ms" >"${RESULTS_CSV}"

  local overall_rc=0

  log "[gpu_only] startup"
  start_sglang_service "gpu_only" "${CASE1_DIR}/server.log"
  if ! wait_for_service "${STARTUP_TIMEOUT_SECS}"; then
    overall_rc=1
    write_startup_failed_status "gpu_only" "${CASE1_DIR}"
    write_startup_failed_status "gpu_only" "${CASE2_DIR}"
    log "[gpu_only] fail startup; mark case1/case2 failed"
  else
    if ! run_case "gpu_only" "Case1(cold_start)" "${CASE1_DIR}"; then
      overall_rc=1
    fi

    if ! run_case "gpu_only" "Case2(cache_hit)" "${CASE2_DIR}"; then
      overall_rc=1
    fi
  fi
  stop_service

  log "[hicache_l1_l2] startup"
  start_sglang_service "hicache_l1_l2" "${CASE3_DIR}/server.log"
  if ! wait_for_service "${STARTUP_TIMEOUT_SECS}"; then
    overall_rc=1
    write_startup_failed_status "hicache_l1_l2" "${CASE3_DIR}"
    write_startup_failed_status "hicache_l1_l2" "${CASE4_DIR}"
    log "[hicache_l1_l2] fail startup; mark case3/case4 failed"
  else
    if ! run_case "hicache_l1_l2" "Case3(cold_start)" "${CASE3_DIR}"; then
      overall_rc=1
    fi

    if ! run_case "hicache_l1_l2" "Case4(cache_hit)" "${CASE4_DIR}"; then
      overall_rc=1
    fi
  fi
  stop_service

  append_group_metrics "case1_cold_start" "${CASE1_DIR}"
  append_group_metrics "case2_cache_hit" "${CASE2_DIR}"
  append_group_metrics "case3_cold_start" "${CASE3_DIR}"
  append_group_metrics "case4_cache_hit" "${CASE4_DIR}"

  write_report >>"${CHECKS_LOG}" 2>&1 || true
  log "Report: ${REPORT_JSON}"
  log "Metrics CSV: ${RESULTS_CSV}"

  if (( overall_rc != 0 )); then
    echo "[ERROR] One or more groups failed. See ${CHECKS_LOG} and ${REPORT_JSON}" >&2
    exit 1
  fi

  log "All groups passed"
}

main "$@"
