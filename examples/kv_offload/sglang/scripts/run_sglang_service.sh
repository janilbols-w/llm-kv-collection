#!/usr/bin/env bash
set -euo pipefail

# Launch SGLang service in one of the following modes:
# - gpu_only: no HiCache
# - hicache_l1_l2: HiCache on GPU+CPU
# - hicache_mooncake: HiCache + Mooncake storage backend

MODEL_PATH="${MODEL_PATH:-/data_ssd1/hz_home/deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-mymodel}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-12358}"
TP="${TP:-1}"
PAGE_SIZE="${PAGE_SIZE:-64}"
MEM_FRACTION_STATIC="${MEM_FRACTION_STATIC:-0.8}"
MODE="${MODE:-gpu_only}"

# Optional launch toggles. Keep them unset by default so the wrapper preserves
# the high-performance path unless the caller needs a fallback.
DISABLE_CUDA_GRAPH="${DISABLE_CUDA_GRAPH:-0}"
CUDA_GRAPH_MAX_BS="${CUDA_GRAPH_MAX_BS:-}"
ENABLE_TORCH_COMPILE="${ENABLE_TORCH_COMPILE:-0}"
TORCH_COMPILE_MAX_BS="${TORCH_COMPILE_MAX_BS:-}"
ENABLE_DETERMINISTIC_INFERENCE="${ENABLE_DETERMINISTIC_INFERENCE:-0}"
ENABLE_MEMORY_SAVER="${ENABLE_MEMORY_SAVER:-0}"
ATTENTION_BACKEND="${ATTENTION_BACKEND:-}" # triton
SAMPLING_BACKEND="${SAMPLING_BACKEND:-}" # pytorch
DISABLE_RADIX_CACHE="${DISABLE_RADIX_CACHE:-0}"

# HiCache options.
HICACHE_WRITE_POLICY="${HICACHE_WRITE_POLICY:-write_through}"
HICACHE_RATIO="${HICACHE_RATIO:-2}"
HICACHE_SIZE="${HICACHE_SIZE:-0}"
HICACHE_STORAGE_PREFETCH_POLICY="${HICACHE_STORAGE_PREFETCH_POLICY:-timeout}"
HICACHE_STORAGE_BACKEND="${HICACHE_STORAGE_BACKEND:-mooncake}"
HICACHE_STORAGE_BACKEND_EXTRA_CONFIG="${HICACHE_STORAGE_BACKEND_EXTRA_CONFIG:-}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "[ERROR] python3 not found" >&2
  exit 1
fi

cmd=(
  python3 -m sglang.launch_server
  --model-path "${MODEL_PATH}"
  --served-model-name "${SERVED_MODEL_NAME}"
  --host "${HOST}"
  --port "${PORT}"
  --tp "${TP}"
  --page-size "${PAGE_SIZE}"
  --mem-fraction-static "${MEM_FRACTION_STATIC}"
)

if [[ "${ENABLE_TORCH_COMPILE}" == "1" ]]; then
  cmd+=(--enable-torch-compile)
  if [[ -n "${TORCH_COMPILE_MAX_BS}" ]]; then
    cmd+=(--torch-compile-max-bs "${TORCH_COMPILE_MAX_BS}")
  fi
fi

if [[ "${ENABLE_MEMORY_SAVER}" == "1" ]]; then
  cmd+=(--enable-memory-saver)
fi

if [[ "${ENABLE_DETERMINISTIC_INFERENCE}" == "1" ]]; then
  cmd+=(--enable-deterministic-inference)
  if [[ -z "${ATTENTION_BACKEND}" ]]; then
    ATTENTION_BACKEND="triton"
  fi
  if [[ -z "${SAMPLING_BACKEND}" ]]; then
    SAMPLING_BACKEND="pytorch"
  fi
fi

if [[ -n "${ATTENTION_BACKEND}" ]]; then
  cmd+=(--attention-backend "${ATTENTION_BACKEND}")
fi

if [[ -n "${SAMPLING_BACKEND}" ]]; then
  cmd+=(--sampling-backend "${SAMPLING_BACKEND}")
fi

if [[ "${DISABLE_RADIX_CACHE}" == "1" ]]; then
  cmd+=(--disable-radix-cache)
fi

if [[ "${DISABLE_CUDA_GRAPH}" == "1" ]]; then
  cmd+=(--disable-cuda-graph)
elif [[ -n "${CUDA_GRAPH_MAX_BS}" ]]; then
  cmd+=(--cuda-graph-max-bs "${CUDA_GRAPH_MAX_BS}")
fi

case "${MODE}" in
  gpu_only)
    ;;
  hicache_l1_l2)
    cmd+=(
      --enable-hierarchical-cache
      --hicache-write-policy "${HICACHE_WRITE_POLICY}"
      --hicache-ratio "${HICACHE_RATIO}"
      --hicache-size "${HICACHE_SIZE}"
    )
    ;;
  hicache_mooncake)
    cmd+=(
      --enable-hierarchical-cache
      --hicache-write-policy "${HICACHE_WRITE_POLICY}"
      --hicache-ratio "${HICACHE_RATIO}"
      --hicache-size "${HICACHE_SIZE}"
      --hicache-storage-prefetch-policy "${HICACHE_STORAGE_PREFETCH_POLICY}"
      --hicache-storage-backend "${HICACHE_STORAGE_BACKEND}"
    )
    if [[ -n "${HICACHE_STORAGE_BACKEND_EXTRA_CONFIG}" ]]; then
      cmd+=(--hicache-storage-backend-extra-config "${HICACHE_STORAGE_BACKEND_EXTRA_CONFIG}")
    fi
    ;;
  *)
    echo "[ERROR] Unsupported MODE=${MODE}" >&2
    exit 1
    ;;
esac

echo "[INFO] Starting SGLang with MODE=${MODE} HOST=${HOST} PORT=${PORT}"
printf '[INFO] Command: %q ' "${cmd[@]}"
printf '\n'

exec "${cmd[@]}"
