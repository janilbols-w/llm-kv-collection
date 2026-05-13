#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KV_OFFLOAD_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_FIXED_DATASET_DIR="${KV_OFFLOAD_ROOT}/data/custom_gen"

# EvalScope perf benchmark case for TTFT/TPOT and throughput metrics.
#
# Features:
# 1) Synthetic dataset only (random / random_multi_turn)
# 2) Configurable prompt/output length
# 3) Configurable multi-turn conversations
# 4) Repeat the same case multiple times
# 5) Supports sweep pairs for parallel/number
# 6) Optional fixed-input replay mode (generate once, reuse many times)
#
# Usage:
#   bash run_evalscope_perf_random_case.sh
#   MULTI_TURN=1 REPEAT=3 PARALLEL="2 4 8" NUMBER="40 80 160" \
#     bash run_evalscope_perf_random_case.sh

MODEL="${MODEL:-mymodel}"
URL="${URL:-http://127.0.0.1:12358/v1/chat/completions}"
API="${API:-openai}"
TOKENIZER_PATH="${TOKENIZER_PATH:-/data_ssd1/hz_home/deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B}"

# Sweep params: values are paired by position.
PARALLEL="${PARALLEL:-1}"        # 1 4 8
NUMBER="${NUMBER:-1}"   # 20 80 160

# Prompt/output length control (random dataset family).
MIN_PROMPT_LENGTH="${MIN_PROMPT_LENGTH:-8192}"
MAX_PROMPT_LENGTH="${MAX_PROMPT_LENGTH:-8192}"
MIN_TOKENS="${MIN_TOKENS:-128}"
MAX_TOKENS="${MAX_TOKENS:-128}"

# Multi-turn control.
MULTI_TURN="${MULTI_TURN:-0}"      # 0: single-turn(random), 1: multi-turn(random_multi_turn)
MIN_TURNS="${MIN_TURNS:-2}"
MAX_TURNS="${MAX_TURNS:-10}"

# Fixed-input replay mode.
# When enabled, the script generates a deterministic JSONL dataset once and
# reuses it across all benchmark runs so the request contents are identical.
FIXED_DATASET="${FIXED_DATASET:-1}"  # 1: replay from generated JSONL, 0: use random datasets
FIXED_DATASET_DIR="${FIXED_DATASET_DIR:-${DEFAULT_FIXED_DATASET_DIR}}"
FIXED_DATASET_SIZE="${FIXED_DATASET_SIZE:-}"
FIXED_PROMPT_LENGTH="${FIXED_PROMPT_LENGTH:-}"
FIXED_TURN_LENGTH="${FIXED_TURN_LENGTH:-}"
FIXED_TURNS="${FIXED_TURNS:-}"
FIXED_DATASET_REGENERATE="${FIXED_DATASET_REGENERATE:-0}"  # 1: rebuild dataset if it already exists
FIXED_DATASET_LENGTH_UNIT="${FIXED_DATASET_LENGTH_UNIT:-token}"
FIXED_DATASET_NAME_TEMPLATE="${FIXED_DATASET_NAME_TEMPLATE:-{prefix}_{mode}_seed{seed}{turns_suffix}_len{length}_{unit}_n{size}.jsonl}"
PREPROCESS_BATCH_SIZE="${PREPROCESS_BATCH_SIZE:-32}"
PREPROCESS_PROGRESS_EVERY="${PREPROCESS_PROGRESS_EVERY:-0}"

# Repeat the same test case N times.
REPEAT="${REPEAT:-1}"
SLEEP_BETWEEN_RUNS="${SLEEP_BETWEEN_RUNS:-2}"

# Streaming must be on for accurate TTFT.
STREAM="${STREAM:-1}"              # 1: --stream, 0: --no-stream

# Optional extra args.
SEED="${SEED:-42}"
TEMPERATURE="${TEMPERATURE:-0}"
TOP_P="${TOP_P:-1.0}"
TOTAL_TIMEOUT="${TOTAL_TIMEOUT:-3600}"
OUTPUTS_DIR="${OUTPUTS_DIR:-./outputs/evalscope_perf}"
NAME_PREFIX="${NAME_PREFIX:-random-perf}"

if ! command -v evalscope >/dev/null 2>&1; then
  echo "[ERROR] evalscope not found. Install first: pip install 'evalscope[perf]'" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "[ERROR] python3 not found." >&2
  exit 1
fi

# Convert sweep strings to arrays early so fixed dataset sizing can use them.
read -r -a PARALLEL_ARR <<< "${PARALLEL}"
read -r -a NUMBER_ARR <<< "${NUMBER}"

if [[ "${#PARALLEL_ARR[@]}" -ne "${#NUMBER_ARR[@]}" ]]; then
  echo "[ERROR] PARALLEL and NUMBER must have the same count." >&2
  echo "        PARALLEL='${PARALLEL}'" >&2
  echo "        NUMBER='${NUMBER}'" >&2
  exit 1
fi

render_dataset_name() {
  python3 - "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" <<'PY'
import sys

template = sys.argv[1]
prefix = sys.argv[2]
mode = sys.argv[3]
seed = sys.argv[4]
size = sys.argv[5]
prompt_length = sys.argv[6]
turn_length = sys.argv[7]
turns = sys.argv[8]
unit = sys.argv[9]

length = turn_length if mode == "multi" else prompt_length
turns_suffix = f"_turns{turns}" if mode == "multi" else ""

replacements = {
  "{prefix}": prefix,
  "{mode}": mode,
  "{seed}": seed,
  "{size}": size,
  "{prompt_length}": prompt_length,
  "{turn_length}": turn_length,
  "{turns}": turns,
  "{length}": length,
  "{turns_suffix}": turns_suffix,
  "{unit}": unit,
}

for key, value in replacements.items():
  template = template.replace(key, value)

if "{" in template or "}" in template:
  template = f"{prefix}_{mode}_seed{seed}{turns_suffix}_len{length}_{unit}_n{size}.jsonl"

print(template)
PY
}

count_dataset_lines() {
  if [[ -f "$1" ]]; then
    wc -l < "$1" | tr -d ' '
  else
    echo 0
  fi
}

validate_fixed_dataset_file() {
  local mode="$1"
  local file_path="$2"
  local expected_size="$3"

  python3 "${SCRIPT_DIR}/validate_evalscope_fixed_dataset.py" \
  --mode "${mode}" \
  --file "${file_path}" \
  --expected-size "${expected_size}"
}

STREAM_FLAG="--stream"
if [[ "${STREAM}" == "0" ]]; then
  STREAM_FLAG="--no-stream"
fi

DATASET="random"
MULTI_TURN_FLAGS=()
DATASET_PATH=""
DATASET_PATH_ARG=()

if [[ "${FIXED_DATASET}" == "1" ]]; then
  mkdir -p "${FIXED_DATASET_DIR}"

  if [[ -z "${FIXED_DATASET_SIZE}" ]]; then
    FIXED_DATASET_SIZE="${NUMBER_ARR[0]}"
    for n in "${NUMBER_ARR[@]}"; do
      if [[ "${n}" -gt "${FIXED_DATASET_SIZE}" ]]; then
        FIXED_DATASET_SIZE="${n}"
      fi
    done
  fi

  if [[ -z "${FIXED_PROMPT_LENGTH}" ]]; then
    FIXED_PROMPT_LENGTH="${MIN_PROMPT_LENGTH}"
  fi

  if [[ "${MULTI_TURN}" == "1" && -z "${FIXED_TURN_LENGTH}" ]]; then
    FIXED_TURN_LENGTH="${FIXED_PROMPT_LENGTH}"
  fi

  if [[ "${MULTI_TURN}" == "1" && -z "${FIXED_TURNS}" ]]; then
    FIXED_TURNS="${MAX_TURNS}"
  fi

  # EvalScope custom(single-turn) filters prompts with an inclusive range,
  # but the historical custom plugin still rejects exact-boundary lengths in
  # some versions. Use a 1-token/1-char open interval around the target to
  # keep exact-length fixed samples from being filtered out.
  if [[ "${FIXED_DATASET_LENGTH_UNIT}" == "token" || "${FIXED_DATASET_LENGTH_UNIT}" == "char" ]]; then
    EVAL_MIN_PROMPT_LENGTH=$(( FIXED_PROMPT_LENGTH > 0 ? FIXED_PROMPT_LENGTH - 1 : 0 ))
    EVAL_MAX_PROMPT_LENGTH=$(( FIXED_PROMPT_LENGTH + 1 ))
  else
    EVAL_MIN_PROMPT_LENGTH="${MIN_PROMPT_LENGTH}"
    EVAL_MAX_PROMPT_LENGTH="${MAX_PROMPT_LENGTH}"
  fi

  export SEED FIXED_DATASET_SIZE FIXED_PROMPT_LENGTH FIXED_TURN_LENGTH FIXED_TURNS

  if [[ "${MULTI_TURN}" == "1" ]]; then
    DATASET="custom_multi_turn"
    DATASET_PATH="${FIXED_DATASET_DIR}/$(render_dataset_name "${FIXED_DATASET_NAME_TEMPLATE}" "${NAME_PREFIX}" "multi" "${SEED}" "${FIXED_DATASET_SIZE}" "${FIXED_PROMPT_LENGTH}" "${FIXED_TURN_LENGTH}" "${FIXED_TURNS}" "${FIXED_DATASET_LENGTH_UNIT}")"
    if [[ -f "${DATASET_PATH}" && "${FIXED_DATASET_REGENERATE}" != "1" ]]; then
      EXISTING_LINES="$(count_dataset_lines "${DATASET_PATH}")"
      if [[ "${EXISTING_LINES}" == "${FIXED_DATASET_SIZE}" ]]; then
        echo "[INFO] Reusing existing fixed dataset: ${DATASET_PATH}"
      else
        echo "[WARN] Fixed dataset line count (${EXISTING_LINES}) does not match expected size (${FIXED_DATASET_SIZE}); regenerating."
        rm -f "${DATASET_PATH}"
        python3 "${SCRIPT_DIR}/preprocess_evalscope_perf_data.py" \
          --mode multi-turn \
          --output "${DATASET_PATH}" \
          --size "${FIXED_DATASET_SIZE}" \
          --seed "${SEED}" \
          --turns "${FIXED_TURNS}" \
          --turn-length "${FIXED_TURN_LENGTH}" \
          --length-unit "${FIXED_DATASET_LENGTH_UNIT}" \
          --batch-size "${PREPROCESS_BATCH_SIZE}" \
          --progress-every "${PREPROCESS_PROGRESS_EVERY}" \
          --tokenizer-path "${TOKENIZER_PATH}" \
          --apply-chat-template \
          $( [[ "${FIXED_DATASET_REGENERATE}" == "1" ]] && echo --overwrite )
        echo "[INFO] Fixed dataset generated at: ${DATASET_PATH}"
      fi
    else
      python3 "${SCRIPT_DIR}/preprocess_evalscope_perf_data.py" \
        --mode multi-turn \
        --output "${DATASET_PATH}" \
        --size "${FIXED_DATASET_SIZE}" \
        --seed "${SEED}" \
        --turns "${FIXED_TURNS}" \
        --turn-length "${FIXED_TURN_LENGTH}" \
        --length-unit "${FIXED_DATASET_LENGTH_UNIT}" \
        --batch-size "${PREPROCESS_BATCH_SIZE}" \
        --progress-every "${PREPROCESS_PROGRESS_EVERY}" \
        --tokenizer-path "${TOKENIZER_PATH}" \
        --apply-chat-template \
        $( [[ "${FIXED_DATASET_REGENERATE}" == "1" ]] && echo --overwrite )
      echo "[INFO] Fixed dataset generated at: ${DATASET_PATH}"
    fi
    if ! validate_fixed_dataset_file "multi" "${DATASET_PATH}" "${FIXED_DATASET_SIZE}" >/dev/null; then
      echo "[WARN] Fixed dataset validation failed; regenerating ${DATASET_PATH}" >&2
      python3 "${SCRIPT_DIR}/preprocess_evalscope_perf_data.py" \
        --mode multi-turn \
        --output "${DATASET_PATH}" \
        --size "${FIXED_DATASET_SIZE}" \
        --seed "${SEED}" \
        --turns "${FIXED_TURNS}" \
        --turn-length "${FIXED_TURN_LENGTH}" \
        --length-unit "${FIXED_DATASET_LENGTH_UNIT}" \
        --batch-size "${PREPROCESS_BATCH_SIZE}" \
        --progress-every "${PREPROCESS_PROGRESS_EVERY}" \
        --tokenizer-path "${TOKENIZER_PATH}" \
        --apply-chat-template \
        --overwrite
    fi
    MULTI_TURN_FLAGS=(--multi-turn --max-turns "${FIXED_TURNS}")
  else
    DATASET="custom"
    DATASET_PATH="${FIXED_DATASET_DIR}/$(render_dataset_name "${FIXED_DATASET_NAME_TEMPLATE}" "${NAME_PREFIX}" "single" "${SEED}" "${FIXED_DATASET_SIZE}" "${FIXED_PROMPT_LENGTH}" "${FIXED_TURN_LENGTH}" "${FIXED_TURNS}" "${FIXED_DATASET_LENGTH_UNIT}")"
    if [[ -f "${DATASET_PATH}" && "${FIXED_DATASET_REGENERATE}" != "1" ]]; then
      EXISTING_LINES="$(count_dataset_lines "${DATASET_PATH}")"
      if [[ "${EXISTING_LINES}" == "${FIXED_DATASET_SIZE}" ]]; then
        echo "[INFO] Reusing existing fixed dataset: ${DATASET_PATH}"
      else
        echo "[WARN] Fixed dataset line count (${EXISTING_LINES}) does not match expected size (${FIXED_DATASET_SIZE}); regenerating."
        rm -f "${DATASET_PATH}"
        python3 "${SCRIPT_DIR}/preprocess_evalscope_perf_data.py" \
          --mode single \
          --output "${DATASET_PATH}" \
          --size "${FIXED_DATASET_SIZE}" \
          --seed "${SEED}" \
          --prompt-length "${FIXED_PROMPT_LENGTH}" \
          --length-unit "${FIXED_DATASET_LENGTH_UNIT}" \
          --batch-size "${PREPROCESS_BATCH_SIZE}" \
          --progress-every "${PREPROCESS_PROGRESS_EVERY}" \
          --tokenizer-path "${TOKENIZER_PATH}" \
          --apply-chat-template \
          $( [[ "${FIXED_DATASET_REGENERATE}" == "1" ]] && echo --overwrite )
        echo "[INFO] Fixed dataset generated at: ${DATASET_PATH}"
      fi
    else
      python3 "${SCRIPT_DIR}/preprocess_evalscope_perf_data.py" \
        --mode single \
        --output "${DATASET_PATH}" \
        --size "${FIXED_DATASET_SIZE}" \
        --seed "${SEED}" \
        --prompt-length "${FIXED_PROMPT_LENGTH}" \
        --length-unit "${FIXED_DATASET_LENGTH_UNIT}" \
        --batch-size "${PREPROCESS_BATCH_SIZE}" \
        --progress-every "${PREPROCESS_PROGRESS_EVERY}" \
        --tokenizer-path "${TOKENIZER_PATH}" \
        --apply-chat-template \
        $( [[ "${FIXED_DATASET_REGENERATE}" == "1" ]] && echo --overwrite )
      echo "[INFO] Fixed dataset generated at: ${DATASET_PATH}"
    fi
    if ! validate_fixed_dataset_file "single" "${DATASET_PATH}" "${FIXED_DATASET_SIZE}" >/dev/null; then
      echo "[WARN] Fixed dataset validation failed; regenerating ${DATASET_PATH}" >&2
      python3 "${SCRIPT_DIR}/preprocess_evalscope_perf_data.py" \
        --mode single \
        --output "${DATASET_PATH}" \
        --size "${FIXED_DATASET_SIZE}" \
        --seed "${SEED}" \
        --prompt-length "${FIXED_PROMPT_LENGTH}" \
        --length-unit "${FIXED_DATASET_LENGTH_UNIT}" \
        --batch-size "${PREPROCESS_BATCH_SIZE}" \
        --progress-every "${PREPROCESS_PROGRESS_EVERY}" \
        --tokenizer-path "${TOKENIZER_PATH}" \
        --apply-chat-template \
        --overwrite
    fi
  fi

  DATASET_PATH_ARG=(--dataset-path "${DATASET_PATH}")

elif [[ "${MULTI_TURN}" == "1" ]]; then
  DATASET="random_multi_turn"
  MULTI_TURN_FLAGS=(
    --multi-turn
    --min-turns "${MIN_TURNS}"
    --max-turns "${MAX_TURNS}"
  )
fi

TOKENIZER_FLAGS=()
if [[ -n "${TOKENIZER_PATH}" ]]; then
  TOKENIZER_FLAGS=(--tokenizer-path "${TOKENIZER_PATH}")
fi

mkdir -p "${OUTPUTS_DIR}"

echo "[INFO] Benchmark config:"
echo "  MODEL=${MODEL}"
echo "  URL=${URL}"
echo "  API=${API}"
echo "  DATASET=${DATASET}"
echo "  PARALLEL=${PARALLEL}"
echo "  NUMBER=${NUMBER}"
echo "  MIN_PROMPT_LENGTH=${MIN_PROMPT_LENGTH}, MAX_PROMPT_LENGTH=${MAX_PROMPT_LENGTH}"
if [[ -n "${EVAL_MIN_PROMPT_LENGTH:-}" ]]; then
  echo "  EVAL_MIN_PROMPT_LENGTH=${EVAL_MIN_PROMPT_LENGTH}, EVAL_MAX_PROMPT_LENGTH=${EVAL_MAX_PROMPT_LENGTH}"
fi
echo "  MIN_TOKENS=${MIN_TOKENS}, MAX_TOKENS=${MAX_TOKENS}"
echo "  MULTI_TURN=${MULTI_TURN}, MIN_TURNS=${MIN_TURNS}, MAX_TURNS=${MAX_TURNS}"
echo "  FIXED_DATASET=${FIXED_DATASET}, FIXED_DATASET_SIZE=${FIXED_DATASET_SIZE:-n/a}"
if [[ -n "${DATASET_PATH}" ]]; then
  echo "  DATASET_PATH=${DATASET_PATH}"
fi
echo "  REPEAT=${REPEAT}, STREAM=${STREAM}"

for ((i=1; i<=REPEAT; i++)); do
  RUN_NAME="${NAME_PREFIX}-r${i}"
  echo "[INFO] Starting run ${i}/${REPEAT}: ${RUN_NAME}"

  evalscope perf \
    --model "${MODEL}" \
    --url "${URL}" \
    --api "${API}" \
    --dataset "${DATASET}" \
    "${DATASET_PATH_ARG[@]}" \
    --parallel "${PARALLEL_ARR[@]}" \
    --number "${NUMBER_ARR[@]}" \
    --min-prompt-length "${EVAL_MIN_PROMPT_LENGTH:-${MIN_PROMPT_LENGTH}}" \
    --max-prompt-length "${EVAL_MAX_PROMPT_LENGTH:-${MAX_PROMPT_LENGTH}}" \
    --min-tokens "${MIN_TOKENS}" \
    --max-tokens "${MAX_TOKENS}" \
    --temperature "${TEMPERATURE}" \
    --top-p "${TOP_P}" \
    --seed "${SEED}" \
    --total-timeout "${TOTAL_TIMEOUT}" \
    --outputs-dir "${OUTPUTS_DIR}" \
    --name "${RUN_NAME}" \
    ${STREAM_FLAG} \
    "${TOKENIZER_FLAGS[@]}" \
    "${MULTI_TURN_FLAGS[@]}"

  if [[ "${i}" -lt "${REPEAT}" ]]; then
    sleep "${SLEEP_BETWEEN_RUNS}"
  fi
done

echo "[INFO] Done. Check HTML/DB reports under: ${OUTPUTS_DIR}"
