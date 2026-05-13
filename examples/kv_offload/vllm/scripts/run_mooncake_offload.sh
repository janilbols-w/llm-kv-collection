#!/usr/bin/env bash
set -euo pipefail

# Single-node vLLM startup script with Mooncake KV cache offload capability.
# This script is separate from disaggregated Mooncake scripts and defaults to kv_both.

MODEL_PATH=${MODEL_PATH:-/data_ssd1/hz_home/deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B}
SERVED_NAME=${SERVED_NAME:-mymodel}
HOST=${HOST:-0.0.0.0}
PORT=${PORT:-12358}
TP_SIZE=${TP:-1}
PP_SIZE=${PP:-1}
GMEM_UTIL=${GMEM_UTIL:-0.4}
MAX_MODEL_LEN=${MAX_MODEL_LEN:-"16384"}

# mooncake transfer config
KV_ROLE=${KV_ROLE:-kv_both}
MOONCAKE_PROTOCOL=${MOONCAKE_PROTOCOL:-rdma}
MOONCAKE_NUM_WORKERS=${MOONCAKE_NUM_WORKERS:-10}

export VLLM_USE_V1=${VLLM_USE_V1:-1}
export VLLM_USE_FLASHINFER_SAMPLER=${VLLM_USE_FLASHINFER_SAMPLER:-0}
export VLLM_SERVER_DEV_MODE=${VLLM_SERVER_DEV_MODE:-1}
export VLLM_MOONCAKE_BOOTSTRAP_PORT=${VLLM_MOONCAKE_BOOTSTRAP_PORT:-8998}
export VLLM_MOONCAKE_ABORT_REQUEST_TIMEOUT=${VLLM_MOONCAKE_ABORT_REQUEST_TIMEOUT:-480}
export VLLM_LOG_STATS_INTERVAL=${VLLM_LOG_STATS_INTERVAL:-5}
# Mooncake transfer-engine internal metrics (0=off, 1=on)
export MC_TE_METRIC=${MC_TE_METRIC:-1}

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

if ! python3 -c "import mooncake.engine" >/dev/null 2>&1; then
  cat >&2 <<'EOF'
[ERROR] Mooncake runtime is not available in current Python environment.
Root cause can also be missing CUDA runtime in dynamic linker path, e.g. libcudart.so.12.
Install it in the SAME environment where vllm is installed:
  pip install -U mooncake-transfer-engine
or:
  uv pip install mooncake-transfer-engine
After install, verify with:
  python3 -c "import mooncake.engine; print('ok')"
If you still see libcudart.so.12 missing, export CUDA runtime lib path, for example:
  export LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH}
EOF
  exit 1
fi

if [[ "${MOONCAKE_PROTOCOL}" == "rdma" ]]; then
  echo "[INFO] MOONCAKE_PROTOCOL=rdma, ensure RDMA/OFED is ready on this host."
  echo "[INFO] If you only need functional validation, try: MOONCAKE_PROTOCOL=tcp"
fi

KV_TRANSFER_CONFIG=$(cat <<EOF
{"kv_connector":"MooncakeConnector","kv_role":"${KV_ROLE}","kv_connector_extra_config":{"mooncake_protocol":"${MOONCAKE_PROTOCOL}","num_workers":${MOONCAKE_NUM_WORKERS}}}
EOF
)

echo "[INFO] vLLM start with KV cache offload"
echo "[INFO] host=${HOST} port=${PORT} role=${KV_ROLE} protocol=${MOONCAKE_PROTOCOL} workers=${MOONCAKE_NUM_WORKERS}"
echo "[INFO] VLLM_LOG_STATS_INTERVAL=${VLLM_LOG_STATS_INTERVAL} MC_TE_METRIC=${MC_TE_METRIC}"

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
  --max_model_len ${MAX_MODEL_LEN} \
  "$@"
