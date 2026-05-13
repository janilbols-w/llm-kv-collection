#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
PORTS_DEFAULT="12358,12359"
KILL_TIMEOUT="${KILL_TIMEOUT:-8}"
DRY_RUN=0
PORTS="${PORTS:-${PORTS_DEFAULT}}"

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Clean up residual vLLM-related processes (vllm serve, VLLM::EngineCore,
resource_tracker) and optionally processes occupying target ports.

Options:
  --ports p1,p2,...   Ports to target (default: ${PORTS_DEFAULT})
  --dry-run           Print targets without killing
  --timeout seconds   Wait time before SIGKILL (default: ${KILL_TIMEOUT})
  -h, --help          Show this help

Examples:
  ${SCRIPT_NAME}
  ${SCRIPT_NAME} --ports 12358,12359,12360
  ${SCRIPT_NAME} --dry-run
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ports)
      PORTS="$2"
      shift 2
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

all_pids_tmp="$(mktemp)"
trap 'rm -f "${all_pids_tmp}"' EXIT

collect_pattern_pids "[v]llm serve" >>"${all_pids_tmp}"
collect_pattern_pids "VLLM::EngineCore" >>"${all_pids_tmp}"
collect_pattern_pids "multiprocessing\.resource_tracker" >>"${all_pids_tmp}"

IFS=',' read -r -a port_list <<<"${PORTS}"
for raw_port in "${port_list[@]}"; do
  port="$(trim "${raw_port}")"
  [[ -z "${port}" ]] && continue
  collect_port_pids "${port}" >>"${all_pids_tmp}"
done

mapfile -t target_pids < <(sort -u "${all_pids_tmp}" | awk 'NF > 0')

if [[ ${#target_pids[@]} -eq 0 ]]; then
  log "No residual vLLM-related process found."
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
