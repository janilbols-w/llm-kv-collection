#!/usr/bin/env bash
set -euo pipefail

# Load local env if present
[[ -f ./.env.local.sh ]] && source ./.env.local.sh

# Optional direct proxy mode (without router)
python /data_ssd1/hz_home/llm-pd/vllm/examples/disaggregated/mooncake_connector/mooncake_connector_proxy.py \
  --host "${ROUTER_HOST:-127.0.0.1}" \
  --port "${ROUTER_PORT:-10001}" \
  --prefill "http://${PREFILL_HOST}:${PREFILL_PORT}" "${VLLM_MOONCAKE_BOOTSTRAP_PORT:-8998}" \
  --decode "http://${DECODE_HOST}:${DECODE_PORT}"
