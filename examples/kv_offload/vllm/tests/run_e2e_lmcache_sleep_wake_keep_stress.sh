#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KV_OFFLOAD_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

RUN_LMCACHE_OFFLOAD="${RUN_LMCACHE_OFFLOAD:-${KV_OFFLOAD_ROOT}/scripts/run_lmcache_offload.sh}"
RUN_NAIVE_SERVICE="${RUN_NAIVE_SERVICE:-${KV_OFFLOAD_ROOT}/scripts/run_naive_service.sh}"
RUN_EVALSCOPE_PERF="${RUN_EVALSCOPE_PERF:-${KV_OFFLOAD_ROOT}/../benchmarks/evalscope/run_evalscope_perf_random_case.sh}"
RUN_CLEANUP_VLLM_RESIDUAL="${RUN_CLEANUP_VLLM_RESIDUAL:-${KV_OFFLOAD_ROOT}/scripts/cleanup_vllm_residual.sh}"
SLEEP_WAKE_CLI="${SLEEP_WAKE_CLI:-${KV_OFFLOAD_ROOT}/scripts/vllm_sleep_wake_cli.py}"

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-12358}"
BASE_URL="${BASE_URL:-http://${HOST}:${PORT}}"
MODELS_URL="${MODELS_URL:-${BASE_URL}/v1/models}"
CHAT_URL="${CHAT_URL:-${BASE_URL}/v1/chat/completions}"

STARTUP_TIMEOUT_SECS="${STARTUP_TIMEOUT_SECS:-300}"
AUTO_CLEANUP_VLLM_RESIDUAL="${AUTO_CLEANUP_VLLM_RESIDUAL:-1}"

# Sleep/wake stress tuning.
# Use interval-only control by default (no iteration cap).
SLEEP_LEVEL="${SLEEP_LEVEL:-1}"
SLEEP_MODE="${SLEEP_MODE:-keep}"
WAKE_TAGS="${WAKE_TAGS:-weights kv_cache}"
STORM_INTERVAL_SECS="${STORM_INTERVAL_SECS:-0.5}"
STORM_MAX_ITER="${STORM_MAX_ITER:-0}"
MIN_STORM_ITER="${MIN_STORM_ITER:-1}"
GROUP3_MIN_STORM_ITER="${GROUP3_MIN_STORM_ITER:-0}"

# Request workload.
MODEL_NAME="${MODEL_NAME:-mymodel}"
PERF_FIXED_PROMPT_LENGTH="${PERF_FIXED_PROMPT_LENGTH:-4096}"
PERF_PARALLEL="${PERF_PARALLEL:-1}"
PERF_FIXED_DATASET="${PERF_FIXED_DATASET:-1}"
PERF_FIXED_DATASET_REGENERATE="${PERF_FIXED_DATASET_REGENERATE:-0}"
PERF_FIXED_DATASET_DIR="${PERF_FIXED_DATASET_DIR:-${KV_OFFLOAD_ROOT}/data/custom_gen}"
TARGET_NUMBER="${TARGET_NUMBER:-1}"
TARGET_MAX_TOKENS="${TARGET_MAX_TOKENS:-512}"
REQUEST_TIMEOUT_SECS="${REQUEST_TIMEOUT_SECS:-300}"

# Timeout knobs (consolidated):
# - STARTUP_TIMEOUT_SECS: service readiness wait budget.
# - REQUEST_TIMEOUT_SECS: evalscope TOTAL_TIMEOUT for each request run.
# - STORM_TIMEOUT_SECS: max duration for sleep/wake storm loop.
STORM_TIMEOUT_SECS="${STORM_TIMEOUT_SECS:-120}"
GROUP3_TIMEOUT_MULTIPLIER="${GROUP3_TIMEOUT_MULTIPLIER:-2}"

E2E_OUTPUT_ROOT="${E2E_OUTPUT_ROOT:-${KV_OFFLOAD_ROOT}/outputs/e2e_lmcache_keep_stress}"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${E2E_OUTPUT_ROOT}/${RUN_TS}"
CHECKS_LOG="${RUN_DIR}/checks.log"
REPORT_JSON="${RUN_DIR}/report.json"
RESULTS_CSV="${RUN_DIR}/metrics.csv"

GROUP1_DIR="${RUN_DIR}/group1_lmcache_baseline"
GROUP2_DIR="${RUN_DIR}/group2_lmcache_sleep_wake"
GROUP3_DIR="${RUN_DIR}/group3_naive_sleep_wake"

SERVICE_PID=""

mkdir -p "${RUN_DIR}" "${PERF_FIXED_DATASET_DIR}" "${GROUP1_DIR}" "${GROUP2_DIR}" "${GROUP3_DIR}"

log() {
  local msg="$*"
  echo "[$(date +'%F %T')] ${msg}" | tee -a "${CHECKS_LOG}"
}

cleanup() {
  local ec=$?
  stop_service || true
  force_cleanup_all_services || true
  log "Scenario finished with exit code ${ec}"
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

stop_service() {
  if [[ -n "${SERVICE_PID}" ]] && kill -0 "${SERVICE_PID}" >/dev/null 2>&1; then
    kill "${SERVICE_PID}" >/dev/null 2>&1 || true
    pkill -P "${SERVICE_PID}" >/dev/null 2>&1 || true
    wait "${SERVICE_PID}" >/dev/null 2>&1 || true
  fi
  SERVICE_PID=""
}

force_cleanup_all_services() {
  if [[ "${AUTO_CLEANUP_VLLM_RESIDUAL}" != "1" ]]; then
    return 0
  fi
  if [[ ! -f "${RUN_CLEANUP_VLLM_RESIDUAL}" ]]; then
    log "[WARN] cleanup script not found: ${RUN_CLEANUP_VLLM_RESIDUAL}"
    return 0
  fi
  if ! bash "${RUN_CLEANUP_VLLM_RESIDUAL}" --ports "${PORT}" >/dev/null 2>&1; then
    log "[WARN] cleanup_vllm_residual failed: ${RUN_CLEANUP_VLLM_RESIDUAL} --ports ${PORT}"
  fi
}

finalize_case_cleanup() {
  local case_name="$1"
  stop_service
  force_cleanup_all_services
  log "[${case_name}] service cleanup finished"
}

start_lmcache_service() {
  local server_log="$1"
  stop_service
  (
    HOST="${HOST}" PORT="${PORT}" \
    bash "${RUN_LMCACHE_OFFLOAD}"
  ) >"${server_log}" 2>&1 &
  SERVICE_PID=$!
}

start_naive_service() {
  local server_log="$1"
  stop_service
  (
    PORT="${PORT}" \
    bash "${RUN_NAIVE_SERVICE}"
  ) >"${server_log}" 2>&1 &
  SERVICE_PID=$!
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

run_evalscope_case() {
  local case_outputs="$1"
  local run_log="$2"
  local max_tokens="$3"
  local number="$4"
  local total_timeout="$5"
  mkdir -p "${case_outputs}"

  (
    OUTPUTS_DIR="${case_outputs}" \
    URL="${CHAT_URL}" \
    MODEL="${MODEL_NAME}" \
    PARALLEL="${PERF_PARALLEL}" \
    NUMBER="${number}" \
    REPEAT="1" \
    MULTI_TURN="0" \
    MIN_PROMPT_LENGTH="${PERF_FIXED_PROMPT_LENGTH}" \
    MAX_PROMPT_LENGTH="${PERF_FIXED_PROMPT_LENGTH}" \
    MIN_TOKENS="${max_tokens}" \
    MAX_TOKENS="${max_tokens}" \
    FIXED_DATASET="${PERF_FIXED_DATASET}" \
    FIXED_DATASET_DIR="${PERF_FIXED_DATASET_DIR}" \
    FIXED_DATASET_REGENERATE="${PERF_FIXED_DATASET_REGENERATE}" \
    FIXED_PROMPT_LENGTH="${PERF_FIXED_PROMPT_LENGTH}" \
    TOTAL_TIMEOUT="${total_timeout}" \
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

append_group_metrics() {
  local label="$1"
  local group_dir="$2"
  local summary_file=""

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

extract_latest_req_id() {
  local log_window="$1"
  python3 - "${log_window}" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="ignore")
ids = re.findall(r"Reqid: ([^,]+),", text)
if not ids:
    raise SystemExit("missing reqid in server log window")
print(ids[-1], end="")
PY
}

validate_no_recompute_with_retrieval() {
  local log_window="$1"
  local req_id="$2"
  local validation_json="$3"
  python3 - "${log_window}" "${req_id}" "${validation_json}" <<'PY'
import json
import re
import sys
from pathlib import Path

log_path, req_id, out_json = sys.argv[1:]
lines = Path(log_path).read_text(encoding="utf-8", errors="ignore").splitlines()

req_pat = re.compile(
    rf"Reqid: {re.escape(req_id)},.*Inference Engine computed tokens: (\d+), LMCache hit tokens: (\d+), need to load: (\d+)"
)
retrieved_pat = re.compile(
    rf"\[req_id={re.escape(req_id)}\] Retrieved (\d+) out of (\d+) required tokens"
)
recompute_pat = re.compile(r"PreemptionMode\.RECOMPUTE|recompute failed blocks", re.IGNORECASE)

computed = []
loads = []
retrieved = []
recompute_lines = []

for ln in lines:
    m = req_pat.search(ln)
    if m:
        computed.append(int(m.group(1)))
        loads.append(int(m.group(3)))
    mr = retrieved_pat.search(ln)
    if mr:
        retrieved.append((int(mr.group(1)), int(mr.group(2))))
    if recompute_pat.search(ln):
        recompute_lines.append(ln)

ok = True
reasons = []
if not computed:
    ok = False
    reasons.append("missing lmcache reqid computed-token log")
if computed and any(v != 0 for v in computed):
    ok = False
    reasons.append(f"computed tokens not zero: {computed}")
if not retrieved:
    ok = False
    reasons.append("missing retrieved log for target req")
if retrieved and not any(a == b and b > 0 for a, b in retrieved):
    ok = False
    reasons.append(f"retrieved tokens invalid: {retrieved}")
if recompute_lines:
    ok = False
    reasons.append("found recompute warning in log window")

summary = {
    "ok": ok,
    "req_id": req_id,
    "computed_tokens": computed,
    "need_to_load_tokens": loads,
    "retrieved_pairs": retrieved,
    "recompute_line_count": len(recompute_lines),
    "reasons": reasons,
}
Path(out_json).write_text(json.dumps(summary, indent=2, ensure_ascii=True), encoding="utf-8")

if not ok:
    raise SystemExit(json.dumps(summary, ensure_ascii=True))
PY
}

kill_request_tree() {
  local pid="$1"
  if kill -0 "${pid}" >/dev/null 2>&1; then
    kill "${pid}" >/dev/null 2>&1 || true
    pkill -P "${pid}" >/dev/null 2>&1 || true
    wait "${pid}" >/dev/null 2>&1 || true
  fi
}

run_sleep_wake_storm() {
  local req_pid="$1"
  local checks_log="$2"
  local hard_timeout_secs="$3"
  local start_ts
  start_ts="$(date +%s)"

  local wake_args=()
  local tag
  for tag in ${WAKE_TAGS}; do
    wake_args+=(--tag "${tag}")
  done

  STORM_ITER=0
  STORM_FAIL=0
  STORM_TIMEOUT=0

  while kill -0 "${req_pid}" >/dev/null 2>&1; do
    if (( hard_timeout_secs > 0 && $(date +%s) - start_ts >= hard_timeout_secs )); then
      STORM_TIMEOUT=1
      break
    fi

    echo "[storm] iter=${STORM_ITER} sleep start" >>"${checks_log}"
    if ! python3 "${SLEEP_WAKE_CLI}" --base-url "${BASE_URL}" sleep --level "${SLEEP_LEVEL}" --mode "${SLEEP_MODE}" >>"${checks_log}" 2>&1; then
      STORM_FAIL=$((STORM_FAIL + 1))
    fi
    echo "[storm] iter=${STORM_ITER} sleep done" >>"${checks_log}"

    echo "[storm] iter=${STORM_ITER} wake start" >>"${checks_log}"
    if ! python3 "${SLEEP_WAKE_CLI}" --base-url "${BASE_URL}" wake "${wake_args[@]}" >>"${checks_log}" 2>&1; then
      STORM_FAIL=$((STORM_FAIL + 1))
    fi
    echo "[storm] iter=${STORM_ITER} wake done" >>"${checks_log}"

    STORM_ITER=$((STORM_ITER + 1))
    if (( STORM_MAX_ITER > 0 && STORM_ITER >= STORM_MAX_ITER )); then
      break
    fi
    sleep "${STORM_INTERVAL_SECS}"
  done
}

run_group1_lmcache_baseline() {
  local group_dir="$1"
  local server_log="${group_dir}/server.log"
  local eval_log="${group_dir}/evalscope.log"
  local status_file="${group_dir}/status.txt"

  log "[Group1] LMCache baseline without sleep/wake"
  start_lmcache_service "${server_log}"
  wait_for_service "${STARTUP_TIMEOUT_SECS}"

  local t0
  t0="$(date +%s)"
  run_evalscope_case "${group_dir}/evalscope" "${eval_log}" "${TARGET_MAX_TOKENS}" "${TARGET_NUMBER}" "${REQUEST_TIMEOUT_SECS}"
  local t1
  t1="$(date +%s)"
  local duration=$((t1 - t0))

  {
    echo "status=pass"
    echo "duration_secs=${duration}"
  } >"${status_file}"

  log "[Group1] pass duration=${duration}s"
}

run_group2_lmcache_sleep_wake() {
  local group_dir="$1"
  local server_log="${group_dir}/server.log"
  local eval_log="${group_dir}/evalscope.log"
  local log_window="${group_dir}/server_window.log"
  local validation_json="${group_dir}/validation.json"
  local checks_log="${group_dir}/checks.log"
  local status_file="${group_dir}/status.txt"

  log "[Group2] LMCache + sleep/wake stress"
  start_lmcache_service "${server_log}"
  wait_for_service "${STARTUP_TIMEOUT_SECS}"

  local start_line
  start_line="$(wc -l < "${server_log}" || echo 1)"

  local t0
  t0="$(date +%s)"
  (
    run_evalscope_case "${group_dir}/evalscope" "${eval_log}" "${TARGET_MAX_TOKENS}" "${TARGET_NUMBER}" "${REQUEST_TIMEOUT_SECS}"
  ) &
  local req_pid=$!

  run_sleep_wake_storm "${req_pid}" "${checks_log}" "${STORM_TIMEOUT_SECS}"

  local req_rc=0
  if (( STORM_TIMEOUT == 1 )); then
    log "[Group2] stress timeout reached; stop sleep/wake and wait request to finish"
  fi

  wait "${req_pid}" || req_rc=$?
  local t1
  t1="$(date +%s)"
  local duration=$((t1 - t0))

  if (( req_rc != 0 )); then
    echo "fail:request_exit_${req_rc}" >"${status_file}"
    return 1
  fi
  if (( STORM_FAIL > 0 )); then
    echo "fail:storm_fail_${STORM_FAIL}" >"${status_file}"
    return 1
  fi
  if (( STORM_ITER < MIN_STORM_ITER )); then
    echo "fail:storm_iter_${STORM_ITER}" >"${status_file}"
    return 1
  fi

  sed -n "$((start_line > 1 ? start_line : 1)),\$p" "${server_log}" >"${log_window}" || true
  local req_id
  req_id="$(extract_latest_req_id "${log_window}")"
  validate_no_recompute_with_retrieval "${log_window}" "${req_id}" "${validation_json}"

  {
    echo "status=pass"
    echo "duration_secs=${duration}"
    echo "storm_timeout=${STORM_TIMEOUT}"
    echo "storm_iter=${STORM_ITER}"
    echo "storm_fail=${STORM_FAIL}"
    echo "req_id=${req_id}"
  } >"${status_file}"

  log "[Group2] pass duration=${duration}s storm_iter=${STORM_ITER} req_id=${req_id}"
}

run_group3_naive_sleep_wake_timeout_expected() {
  local group_dir="$1"
  local effective_timeout_secs="$2"
  local server_log="${group_dir}/server.log"
  local eval_log="${group_dir}/evalscope.log"
  local checks_log="${group_dir}/checks.log"
  local status_file="${group_dir}/status.txt"
  local log_window="${group_dir}/server_window.log"

  log "[Group3] Naive(no LMCache) + same sleep/wake stress, expect timeout"
  start_naive_service "${server_log}"
  wait_for_service "${STARTUP_TIMEOUT_SECS}"

  local start_line
  start_line="$(wc -l < "${server_log}" || echo 1)"

  local t0
  t0="$(date +%s)"
  (
    run_evalscope_case "${group_dir}/evalscope" "${eval_log}" "${TARGET_MAX_TOKENS}" "${TARGET_NUMBER}" "${REQUEST_TIMEOUT_SECS}"
  ) &
  local req_pid=$!

  run_sleep_wake_storm "${req_pid}" "${checks_log}" "${effective_timeout_secs}"

  local t1
  t1="$(date +%s)"
  local stress_phase_duration=$((t1 - t0))

  if (( STORM_FAIL > 0 )); then
    kill_request_tree "${req_pid}"
    echo "fail:storm_fail_${STORM_FAIL}" >"${status_file}"
    return 1
  fi
  if (( STORM_ITER < GROUP3_MIN_STORM_ITER )); then
    kill_request_tree "${req_pid}"
    echo "fail:storm_iter_${STORM_ITER}_lt_min_${GROUP3_MIN_STORM_ITER}" >"${status_file}"
    return 1
  fi

  # Timeout means stop storming and let request naturally complete.
  local req_rc=0
  wait "${req_pid}" || req_rc=$?
  local t2
  t2="$(date +%s)"
  local total_duration=$((t2 - t0))

  sed -n "$((start_line > 1 ? start_line : 1)),\$p" "${server_log}" >"${log_window}" || true
  local req_id=""
  req_id="$(extract_latest_req_id "${log_window}" 2>/dev/null || true)"

  local request_timeout=0
  if is_evalscope_timeout "${eval_log}"; then
    request_timeout=1
  fi

  if (( STORM_TIMEOUT != 1 && request_timeout != 1 )); then
    {
      echo "status=fail"
      echo "reason=timeout_not_triggered"
      echo "request_exit_code=${req_rc}"
      echo "stress_phase_duration_secs=${stress_phase_duration}"
      echo "total_duration_secs=${total_duration}"
      echo "storm_iter=${STORM_ITER}"
      echo "storm_fail=${STORM_FAIL}"
      echo "request_timeout=${request_timeout}"
      echo "req_id=${req_id}"
      echo "request_completed=yes"
    } >"${status_file}"
    log "[Group3] fail timeout_not_triggered duration=${total_duration}s storm_iter=${STORM_ITER} req_id=${req_id:-unknown}"
    return 1
  fi

  {
    echo "status=pass"
    echo "expected_timeout_secs=${effective_timeout_secs}"
    echo "expected_min_storm_iter=${GROUP3_MIN_STORM_ITER}"
    echo "stress_phase_duration_secs=${stress_phase_duration}"
    echo "total_duration_secs=${total_duration}"
    echo "storm_timeout=${STORM_TIMEOUT}"
    echo "storm_iter=${STORM_ITER}"
    echo "storm_fail=${STORM_FAIL}"
    echo "request_timeout=${request_timeout}"
    echo "req_id=${req_id}"
    echo "request_exit_code=${req_rc}"
    echo "request_completed=yes"
  } >"${status_file}"

  log "[Group3] expected timeout observed at ${stress_phase_duration}s (storm_timeout=${STORM_TIMEOUT}, request_timeout=${request_timeout}, min_iter=${GROUP3_MIN_STORM_ITER}); request ended in ${total_duration}s req_id=${req_id:-unknown}"
}

read_status_value() {
  local file_path="$1"
  local key="$2"
  if [[ ! -f "${file_path}" ]]; then
    echo ""
    return 0
  fi
  grep -E "^${key}=" "${file_path}" | tail -n 1 | cut -d'=' -f2-
}

is_evalscope_timeout() {
  local eval_log="$1"
  if [[ ! -f "${eval_log}" ]]; then
    return 1
  fi

  if grep -q "TimeoutError" "${eval_log}"; then
    return 0
  fi

  # EvalScope timeout often appears as total=1, success=0, failed=1.
  if grep -Eq "Total / Success / Failed[[:space:]]*│[[:space:]]*1 / 0 / 1" "${eval_log}"; then
    return 0
  fi

  return 1
}
write_report() {
  python3 - "${GROUP1_DIR}/status.txt" "${GROUP2_DIR}/status.txt" "${GROUP3_DIR}/status.txt" "${REPORT_JSON}" <<'PY'
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

g1 = parse_status(sys.argv[1])
g2 = parse_status(sys.argv[2])
g3 = parse_status(sys.argv[3])
report = {
  "group1_lmcache_baseline": g1,
  "group2_lmcache_sleep_wake": g2,
    "group3_naive_sleep_wake_expected_timeout": g3,
}
Path(sys.argv[4]).write_text(json.dumps(report, indent=2, ensure_ascii=True), encoding="utf-8")
print(json.dumps(report, ensure_ascii=True))
PY
}

main() {
  require_file "${RUN_LMCACHE_OFFLOAD}"
  require_file "${RUN_NAIVE_SERVICE}"
  require_file "${RUN_EVALSCOPE_PERF}"
  require_file "${RUN_CLEANUP_VLLM_RESIDUAL}"
  require_file "${SLEEP_WAKE_CLI}"
  require_cmd curl
  require_cmd python3

  log "Run dir: ${RUN_DIR}"
  log "Tuned defaults: STORM_INTERVAL_SECS=${STORM_INTERVAL_SECS}, STORM_MAX_ITER=${STORM_MAX_ITER}(0 means unlimited), TARGET_PROMPT=${PERF_FIXED_PROMPT_LENGTH}, TARGET_MAX_TOKENS=${TARGET_MAX_TOKENS}"
  echo "label,avg_lat_s,p99_lat_s,avg_ttft_ms,p99_ttft_ms,avg_tpot_ms,p99_tpot_ms" >"${RESULTS_CSV}"

  local overall_rc=0

  # 1) baseline first
  if ! run_group1_lmcache_baseline "${GROUP1_DIR}"; then
    overall_rc=1
    log "[Group1] failed"
  fi
  append_group_metrics "group1_lmcache_baseline" "${GROUP1_DIR}"
  finalize_case_cleanup "Group1"

  # 2) normal test second
  if ! run_group2_lmcache_sleep_wake "${GROUP2_DIR}"; then
    overall_rc=1
    log "[Group2] failed"
  fi
  append_group_metrics "group2_lmcache_sleep_wake" "${GROUP2_DIR}"
  finalize_case_cleanup "Group2"

  # 3) expected stress test last; timeout = case2 duration * GROUP3_TIMEOUT_MULTIPLIER
  local normal_duration
  normal_duration="$(read_status_value "${GROUP2_DIR}/status.txt" "duration_secs")"
  local group3_timeout
  if [[ "${normal_duration}" =~ ^[0-9]+$ ]] && (( normal_duration > 0 )) && [[ "${GROUP3_TIMEOUT_MULTIPLIER}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    group3_timeout="$(awk -v d="${normal_duration}" -v m="${GROUP3_TIMEOUT_MULTIPLIER}" 'BEGIN { v = d * m; if (v < 1) v = 1; printf "%d\n", (v == int(v) ? v : int(v) + 1) }')"
  else
    group3_timeout="${STORM_TIMEOUT_SECS}"
    log "[Group3] warn: failed to read normal duration or multiplier invalid (GROUP3_TIMEOUT_MULTIPLIER=${GROUP3_TIMEOUT_MULTIPLIER}), fallback timeout=${group3_timeout}s"
  fi
  log "[Group3] timeout set to ${group3_timeout}s (multiplier=${GROUP3_TIMEOUT_MULTIPLIER}, normal duration=${normal_duration:-unknown})"

  if ! run_group3_naive_sleep_wake_timeout_expected "${GROUP3_DIR}" "${group3_timeout}"; then
    overall_rc=1
    log "[Group3] failed"
  fi
  append_group_metrics "group3_naive_sleep_wake_expected_timeout" "${GROUP3_DIR}"
  finalize_case_cleanup "Group3"

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
