#!/bin/bash
MODEL_PATH=${MODEL_PATH:-'/data_ssd1/hz_home/deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B'}
SERVED_NAME=${SERVED_NAME:-'mymodel'}
TP_SIZE=${TP:-'1'}
PP_SIZE=${PP:-'1'}
# MAX_MODEL_LEN=32768
PORT=${PORT:-'12358'}
GMEM_UTIL=${GMEM_UTIL:-'0.8'}

export VLLM_USE_FLASHINFER_SAMPLER=0
export VLLM_SERVER_DEV_MODE=1
vllm serve ${MODEL_PATH} \
        --tensor-parallel-size $TP_SIZE \
        --pipeline-parallel-size $PP_SIZE \
        --trust-remote-code \
        --port=$PORT \
        --served-model-name ${SERVED_NAME} \
        --gpu-memory-utilization=$GMEM_UTIL \
        --enable-sleep-mode \
        --enable-server-load-tracking \
        $@


exit 0
        # --max_model_len=${MAX_MODEL_LEN} \
        --enable-chunked-prefill=False \
        --dtype=half \
