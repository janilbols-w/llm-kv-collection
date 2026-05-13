#!/usr/bin/env bash
set -euo pipefail

# Single-node vLLM startup script with LMCache KV cache offload.
#
# This script starts vLLM with LMCacheConnectorV1.
# Optionally, it can also launch lmcache_controller in background for
# controller APIs (lookup/clear/pin/move/health).

MODEL_PATH=${MODEL_PATH:-/data_ssd1/hz_home/deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B}
SERVED_NAME=${SERVED_NAME:-mymodel}
HOST=${HOST:-0.0.0.0}
PORT=${PORT:-12358}
TP_SIZE=${TP:-1}
PP_SIZE=${PP:-1}
GMEM_UTIL=${GMEM_UTIL:-0.4}
MAX_MODEL_LEN=${MAX_MODEL_LEN:-16384}

KV_ROLE=${KV_ROLE:-kv_both}

# LMCache runtime config file (yaml/json). LMCache docs commonly use yaml.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DEFAULT_LMCACHE_CONFIG_FILE="${SCRIPT_DIR}/../config/lmcache.template.yaml"
LMCACHE_CONFIG_FILE=${LMCACHE_CONFIG_FILE:-${DEFAULT_LMCACHE_CONFIG_FILE}}
USING_DEFAULT_LMCACHE_CONFIG=0
if [[ "${LMCACHE_CONFIG_FILE}" == "${DEFAULT_LMCACHE_CONFIG_FILE}" ]]; then
  USING_DEFAULT_LMCACHE_CONFIG=1
fi

# Optional controller startup (0=off, 1=on)
START_LMCACHE_CONTROLLER=${START_LMCACHE_CONTROLLER:-0}
LMCACHE_CONTROLLER_HOST=${LMCACHE_CONTROLLER_HOST:-127.0.0.1}
LMCACHE_CONTROLLER_PORT=${LMCACHE_CONTROLLER_PORT:-9000}
# Legacy single monitor port; LMCache may emit deprecation warning.
LMCACHE_CONTROLLER_MONITOR_PORT=${LMCACHE_CONTROLLER_MONITOR_PORT:-9001}

export VLLM_USE_V1=${VLLM_USE_V1:-1}
export VLLM_SERVER_DEV_MODE=${VLLM_SERVER_DEV_MODE:-1}
export VLLM_LOG_STATS_INTERVAL=${VLLM_LOG_STATS_INTERVAL:-5}
export PYTHONHASHSEED=${PYTHONHASHSEED:-123}
export LMCACHE_CONFIG_FILE

# Add common CUDA runtime library locations to avoid libcudart lookup failures.
for d in \
  /usr/local/cuda/lib64 \
  /usr/local/cuda-12/lib64 \
  /usr/local/cuda-12.0/lib64 \
  /usr/local/cuda-12.1/lib64 \
  /usr/local/cuda-12.2/lib64 \
  /usr/local/cuda-12.3/lib64 \
  /usr/local/cuda-12.4/lib64 \
  /usr/local/cuda-12.5/lib64 \
  /usr/local/cuda-12.6/lib64 \
  /usr/local/cuda-12.8/lib64 \
  /usr/local/lib/python3.12/dist-packages/nvidia/cuda_runtime/lib \
  /usr/local/lib/python3.11/dist-packages/nvidia/cuda_runtime/lib \
  /usr/local/lib/python3.10/dist-packages/nvidia/cuda_runtime/lib
do
  if [[ -d "$d" ]]; then
    export LD_LIBRARY_PATH="$d:${LD_LIBRARY_PATH:-}"
  fi
done

if ! command -v vllm >/dev/null 2>&1; then
  echo "[ERROR] vllm command not found in current environment." >&2
  exit 1
fi

if ! python3 -c "import lmcache" >/dev/null 2>&1; then
  cat >&2 <<'EOF'
[ERROR] LMCache Python package is not available in current environment.
Install it in the SAME environment where vllm is installed:
  pip install -U lmcache
or from source:
  cd 3rdparty/lmcache && pip install -e .
Then verify:
  python3 -c "import lmcache; print('ok')"
EOF
  exit 1
fi

if ! python3 -c "from vllm.distributed.kv_transfer.kv_connector.v1.lmcache_connector import LMCacheConnectorV1" >/dev/null 2>&1; then
  cat >&2 <<'EOF'
[ERROR] vLLM cannot import LMCacheConnectorV1.
Please ensure your vLLM version includes LMCache connector support.
EOF
  exit 1
fi

if [[ ! -f "${LMCACHE_CONFIG_FILE}" ]]; then
  if [[ "${USING_DEFAULT_LMCACHE_CONFIG}" == "1" ]]; then
    cat >&2 <<EOF
[ERROR] Default LMCache template config is missing:
  ${DEFAULT_LMCACHE_CONFIG_FILE}
Please ensure this file exists, or set LMCACHE_CONFIG_FILE to your own config.
EOF
  else
    cat >&2 <<EOF
[ERROR] LMCACHE_CONFIG_FILE does not exist:
  ${LMCACHE_CONFIG_FILE}
Please set LMCACHE_CONFIG_FILE to an existing YAML/JSON file.
EOF
  fi
  exit 1
fi

if [[ "${START_LMCACHE_CONTROLLER}" == "1" ]]; then
  if ! command -v lmcache_controller >/dev/null 2>&1; then
    echo "[ERROR] lmcache_controller command not found. Install lmcache extras or check PATH." >&2
    exit 1
  fi

  echo "[INFO] Starting lmcache_controller in background"
  echo "[INFO] controller: ${LMCACHE_CONTROLLER_HOST}:${LMCACHE_CONTROLLER_PORT}, monitor=${LMCACHE_CONTROLLER_MONITOR_PORT}"
  lmcache_controller \
    --host "${LMCACHE_CONTROLLER_HOST}" \
    --port "${LMCACHE_CONTROLLER_PORT}" \
    --monitor-port "${LMCACHE_CONTROLLER_MONITOR_PORT}" \
    >/tmp/lmcache_controller_${LMCACHE_CONTROLLER_PORT}.log 2>&1 &
  CONTROLLER_PID=$!
  echo "[INFO] lmcache_controller pid=${CONTROLLER_PID}, log=/tmp/lmcache_controller_${LMCACHE_CONTROLLER_PORT}.log"
fi

KV_TRANSFER_CONFIG=$(cat <<EOF
{"kv_connector":"LMCacheConnectorV1","kv_role":"${KV_ROLE}"}
EOF
)

echo "[INFO] vLLM start with LMCache KV offload"
echo "[INFO] host=${HOST} port=${PORT} role=${KV_ROLE}"
echo "[INFO] LMCACHE_CONFIG_FILE=${LMCACHE_CONFIG_FILE}"

vllm serve "${MODEL_PATH}" \
  --host "${HOST}" \
  --port "${PORT}" \
  --tensor-parallel-size "${TP_SIZE}" \
  --pipeline-parallel-size "${PP_SIZE}" \
  --trust-remote-code \
  --served-model-name "${SERVED_NAME}" \
  --gpu-memory-utilization "${GMEM_UTIL}" \
  --enable-sleep-mode \
  --enable-server-load-tracking \
  --kv-transfer-config "${KV_TRANSFER_CONFIG}" \
  --max_model_len "${MAX_MODEL_LEN}" \
  "$@"
