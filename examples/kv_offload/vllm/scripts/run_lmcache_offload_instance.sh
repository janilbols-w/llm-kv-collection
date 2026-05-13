#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUN_LMCACHE_OFFLOAD="${RUN_LMCACHE_OFFLOAD:-${SCRIPT_DIR}/run_lmcache_offload.sh}"

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-12358}"
SERVED_NAME="${SERVED_NAME:-mymodel}"
LMCACHE_CONFIG_FILE="${LMCACHE_CONFIG_FILE:-${SCRIPT_DIR}/../config/lmcache.template.yaml}"
GPU="${GPU:-}"

# If not explicitly provided, run_lmcache_offload.sh will derive instance name
# from HOST/PORT when LMCACHE_INSTANCE_NAME_FROM_HOST_PORT=1.
LMCACHE_INSTANCE_NAME="${LMCACHE_INSTANCE_NAME:-}"
LMCACHE_INSTANCE_NAME_FROM_HOST_PORT="${LMCACHE_INSTANCE_NAME_FROM_HOST_PORT:-1}"

if [[ ! -f "${RUN_LMCACHE_OFFLOAD}" ]]; then
  echo "[ERROR] Required file not found: ${RUN_LMCACHE_OFFLOAD}" >&2
  exit 1
fi

if [[ -n "${GPU}" ]]; then
  export CUDA_VISIBLE_DEVICES="${GPU}"
fi

export HOST
export PORT
export SERVED_NAME
export LMCACHE_CONFIG_FILE
export LMCACHE_INSTANCE_NAME
export LMCACHE_INSTANCE_NAME_FROM_HOST_PORT

echo "[INFO] Starting single LMCache instance"
echo "[INFO] host=${HOST} port=${PORT} served_name=${SERVED_NAME} gpu=${GPU:-all}"
echo "[INFO] config=${LMCACHE_CONFIG_FILE}"

exec bash "${RUN_LMCACHE_OFFLOAD}" "$@"
