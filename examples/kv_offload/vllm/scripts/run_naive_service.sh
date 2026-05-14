#!/bin/bash
MODEL_PATH=${MODEL_PATH:-'/data_ssd1/hz_home/deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B'}
SERVED_NAME=${SERVED_NAME:-'mymodel'}
TP_SIZE=${TP:-'1'}
PP_SIZE=${PP:-'1'}
PORT=${PORT:-'12358'}
GMEM_UTIL=${GMEM_UTIL:-'0.8'}
INPUT_TOKEN_LENGTH=${INPUT_TOKEN_LENGTH:-''}
MAX_MODEL_LEN=${MAX_MODEL_LEN:-''}
MAX_MODEL_LEN_AUTO=${MAX_MODEL_LEN_AUTO:-'1'}

resolve_max_model_len() {
        if [[ -n "${MAX_MODEL_LEN}" ]]; then
                return 0
        fi

        if [[ "${MAX_MODEL_LEN_AUTO}" == "1" && -n "${INPUT_TOKEN_LENGTH}" ]]; then
                if ! [[ "${INPUT_TOKEN_LENGTH}" =~ ^[0-9]+$ ]] || (( INPUT_TOKEN_LENGTH < 1 )); then
                        echo "[ERROR] INPUT_TOKEN_LENGTH must be a positive integer, got '${INPUT_TOKEN_LENGTH}'" >&2
                        exit 1
                fi
                MAX_MODEL_LEN=$(( (INPUT_TOKEN_LENGTH * 120 + 99) / 100 ))
                return 0
        fi

        MAX_MODEL_LEN='16384'
}

resolve_max_model_len

export VLLM_USE_FLASHINFER_SAMPLER=0
export VLLM_SERVER_DEV_MODE=1
echo "[INFO] input_token_length=${INPUT_TOKEN_LENGTH:-<unset>} max_model_len=${MAX_MODEL_LEN} auto=${MAX_MODEL_LEN_AUTO}"
vllm serve ${MODEL_PATH} \
        --tensor-parallel-size $TP_SIZE \
        --pipeline-parallel-size $PP_SIZE \
        --trust-remote-code \
        --port=$PORT \
        --served-model-name ${SERVED_NAME} \
        --gpu-memory-utilization=$GMEM_UTIL \
        --max_model_len=${MAX_MODEL_LEN} \
        --enable-sleep-mode \
        --enable-server-load-tracking \
        $@


exit 0
        --enable-chunked-prefill=False \
        --dtype=half \
