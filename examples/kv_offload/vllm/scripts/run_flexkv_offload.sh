#!/usr/bin/env bash
set -euo pipefail

# Single-node vLLM startup script with FlexKV KV cache offload.
#
# Prerequisites:
# 1) vLLM environment contains FlexKV Python package.
# 2) vLLM version registers FlexKVConnectorV1 connector.
#
# Optional:
# - Set FLEXKV_CONFIG_PATH to a JSON config file for FlexKV user config.
# - Tune FLEXKV_* env vars below for your machine.

MODEL_PATH=${MODEL_PATH:-/data_ssd1/hz_home/deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B}
SERVED_NAME=${SERVED_NAME:-mymodel}
HOST=${HOST:-0.0.0.0}
PORT=${PORT:-12358}
TP_SIZE=${TP:-1}
PP_SIZE=${PP:-1}
GMEM_UTIL=${GMEM_UTIL:-0.4}
MAX_MODEL_LEN=${MAX_MODEL_LEN:-16384}

# Connector role for local validation; kv_both is easiest for single-node usage.
KV_ROLE=${KV_ROLE:-kv_both}

# vLLM runtime flags.
export VLLM_USE_V1=${VLLM_USE_V1:-1}
export VLLM_SERVER_DEV_MODE=${VLLM_SERVER_DEV_MODE:-1}
export VLLM_LOG_STATS_INTERVAL=${VLLM_LOG_STATS_INTERVAL:-5}

# FlexKV runtime controls.
export ENABLE_FLEXKV=${ENABLE_FLEXKV:-1}
export FLEXKV_CONFIG_PATH=${FLEXKV_CONFIG_PATH:-}
export FLEXKV_SERVER_RECV_PORT=${FLEXKV_SERVER_RECV_PORT:-ipc:///tmp/flexkv_server}
export FLEXKV_INSTANCE_NUM=${FLEXKV_INSTANCE_NUM:-1}
export FLEXKV_INSTANCE_ID=${FLEXKV_INSTANCE_ID:-0}
export FLEXKV_SERVER_CLIENT_MODE=${FLEXKV_SERVER_CLIENT_MODE:-0}
export FLEXKV_LOG_LEVEL=${FLEXKV_LOG_LEVEL:-INFO}
export FLEXKV_ENABLE_METRICS=${FLEXKV_ENABLE_METRICS:-0}
export FLEXKV_PY_METRICS_PORT=${FLEXKV_PY_METRICS_PORT:-8080}
export FLEXKV_CPP_METRICS_PORT=${FLEXKV_CPP_METRICS_PORT:-8081}

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

if ! python3 -c "import flexkv" >/dev/null 2>&1; then
  cat >&2 <<'EOF'
[ERROR] FlexKV Python package is not available in current environment.
Install FlexKV into the SAME environment where vllm is installed.
Then verify:
  python3 -c "import flexkv; print('ok')"
EOF
  exit 1
fi

if ! python3 -c "from flexkv.integration.vllm.vllm_v1_adapter import FlexKVConnectorV1Impl" >/dev/null 2>&1; then
  cat >&2 <<'EOF'
[ERROR] FlexKV vLLM adapter import failed.
Expected module: flexkv.integration.vllm.vllm_v1_adapter
Check FlexKV version and Python environment.
EOF
  exit 1
fi

if [[ -n "${FLEXKV_CONFIG_PATH}" && ! -f "${FLEXKV_CONFIG_PATH}" ]]; then
  echo "[ERROR] FLEXKV_CONFIG_PATH does not exist: ${FLEXKV_CONFIG_PATH}" >&2
  exit 1
fi

KV_TRANSFER_CONFIG=$(cat <<EOF
{"kv_connector":"FlexKVConnectorV1","kv_role":"${KV_ROLE}"}
EOF
)

echo "[INFO] vLLM start with FlexKV KV offload"
echo "[INFO] host=${HOST} port=${PORT} role=${KV_ROLE}"
echo "[INFO] MODEL_PATH=${MODEL_PATH}"
echo "[INFO] FLEXKV_SERVER_RECV_PORT=${FLEXKV_SERVER_RECV_PORT}"
echo "[INFO] FLEXKV_INSTANCE_NUM=${FLEXKV_INSTANCE_NUM} FLEXKV_INSTANCE_ID=${FLEXKV_INSTANCE_ID}"
echo "[INFO] FLEXKV_SERVER_CLIENT_MODE=${FLEXKV_SERVER_CLIENT_MODE}"
if [[ -n "${FLEXKV_CONFIG_PATH}" ]]; then
  echo "[INFO] FLEXKV_CONFIG_PATH=${FLEXKV_CONFIG_PATH}"
else
  echo "[INFO] FLEXKV_CONFIG_PATH is empty; FlexKV loads config from env vars"
fi

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
