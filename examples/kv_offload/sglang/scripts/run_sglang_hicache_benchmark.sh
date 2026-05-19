#!/usr/bin/env bash
set -euo pipefail

# Wrapper for SGLang official HiCache benchmark:
#   benchmark/hicache/bench_multiturn.py
#
# Example:
#   SGLANG_ROOT=/path/to/sglang \
#   MODEL_PATH=/path/to/model \
#   DATASET_PATH=/path/to/sharegpt.json \
#   NUM_CLIENTS=80 NUM_ROUNDS=10 REQUEST_RATE=16 \
#   bash examples/kv_offload/sglang/scripts/run_sglang_hicache_benchmark.sh

SGLANG_ROOT="${SGLANG_ROOT:-}"
BENCH_SCRIPT="${BENCH_SCRIPT:-}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

MODEL_PATH="${MODEL_PATH:-/data_ssd1/hz_home/deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B}"
DATASET_PATH="${DATASET_PATH:-}"

# Keep defaults aligned with Mooncake docs examples.
OUTPUT_LENGTH="${OUTPUT_LENGTH:-1}"
REQUEST_LENGTH="${REQUEST_LENGTH:-2048}"
NUM_CLIENTS="${NUM_CLIENTS:-80}"
NUM_ROUNDS="${NUM_ROUNDS:-10}"
MAX_PARALLEL="${MAX_PARALLEL:-4}"
REQUEST_RATE="${REQUEST_RATE:-16}"
READY_QUEUE_POLICY="${READY_QUEUE_POLICY:-random}"

# Common toggles used by official benchmark examples.
DISABLE_RANDOM_SAMPLE="${DISABLE_RANDOM_SAMPLE:-1}"
DISABLE_AUTO_RUN="${DISABLE_AUTO_RUN:-1}"
ENABLE_ROUND_BARRIER="${ENABLE_ROUND_BARRIER:-1}"

EXTRA_ARGS="${EXTRA_ARGS:-}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
  echo "[ERROR] Python not found: ${PYTHON_BIN}" >&2
  exit 1
fi

if [[ -z "${BENCH_SCRIPT}" ]]; then
  if [[ -z "${SGLANG_ROOT}" ]]; then
    echo "[ERROR] Set SGLANG_ROOT or BENCH_SCRIPT." >&2
    exit 1
  fi
  BENCH_SCRIPT="${SGLANG_ROOT}/benchmark/hicache/bench_multiturn.py"
fi

if [[ ! -f "${BENCH_SCRIPT}" ]]; then
  echo "[ERROR] Benchmark script not found: ${BENCH_SCRIPT}" >&2
  echo "        Expected official SGLang path: <sglang>/benchmark/hicache/bench_multiturn.py" >&2
  exit 1
fi

if [[ -z "${DATASET_PATH}" ]]; then
  echo "[ERROR] DATASET_PATH is required." >&2
  exit 1
fi

if [[ ! -f "${DATASET_PATH}" ]]; then
  echo "[ERROR] DATASET_PATH does not exist: ${DATASET_PATH}" >&2
  exit 1
fi

cmd=(
  "${PYTHON_BIN}" "${BENCH_SCRIPT}"
  --model-path "${MODEL_PATH}"
  --dataset-path "${DATASET_PATH}"
  --output-length "${OUTPUT_LENGTH}"
  --request-length "${REQUEST_LENGTH}"
  --num-clients "${NUM_CLIENTS}"
  --num-rounds "${NUM_ROUNDS}"
  --max-parallel "${MAX_PARALLEL}"
  --request-rate "${REQUEST_RATE}"
  --ready-queue-policy "${READY_QUEUE_POLICY}"
)

if [[ "${DISABLE_RANDOM_SAMPLE}" == "1" ]]; then
  cmd+=(--disable-random-sample)
fi
if [[ "${DISABLE_AUTO_RUN}" == "1" ]]; then
  cmd+=(--disable-auto-run)
fi
if [[ "${ENABLE_ROUND_BARRIER}" == "1" ]]; then
  cmd+=(--enable-round-barrier)
fi

if [[ -n "${EXTRA_ARGS}" ]]; then
  # shellcheck disable=SC2206
  extra_arr=(${EXTRA_ARGS})
  cmd+=("${extra_arr[@]}")
fi

echo "[INFO] Running SGLang HiCache benchmark"
echo "[INFO] BENCH_SCRIPT=${BENCH_SCRIPT}"
echo "[INFO] MODEL_PATH=${MODEL_PATH}"
echo "[INFO] DATASET_PATH=${DATASET_PATH}"
printf '[INFO] Command: %q ' "${cmd[@]}"
printf '\n'

exec "${cmd[@]}"
