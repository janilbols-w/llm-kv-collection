#!/usr/bin/env bash
set -euo pipefail

# Load local env if present
[[ -f ./.env.local.sh ]] && source ./.env.local.sh

export CUDA_VISIBLE_DEVICES="${PREFILL_CUDA_VISIBLE_DEVICES:-0}"
export VLLM_USE_V1="${VLLM_USE_V1:-1}"
export VLLM_MOONCAKE_BOOTSTRAP_PORT="${VLLM_MOONCAKE_BOOTSTRAP_PORT:-8998}"
export VLLM_MOONCAKE_ABORT_REQUEST_TIMEOUT="${VLLM_MOONCAKE_ABORT_REQUEST_TIMEOUT:-480}"

# Prefill node: Mooncake KV producer
vllm serve "${MODEL_NAME}" \
  --host "${PREFILL_HOST:-0.0.0.0}" \
  --port "${PREFILL_PORT:-8010}" \
  --tensor-parallel-size "${TENSOR_PARALLEL_SIZE:-1}" \
  --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION:-0.85}" \
  --trust-remote-code \
  --kv-transfer-config '{"kv_connector":"MooncakeConnector","kv_role":"kv_producer"}'
