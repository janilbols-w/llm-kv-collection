#!/usr/bin/env bash
set -euo pipefail

# Load local env if present
[[ -f ./.env.local.sh ]] && source ./.env.local.sh

: "${ROUTER_KV_CONNECTOR:=mooncake}"

# Router static mode: explicitly pass prefill/decode URLs
vllm-router \
  --host "${ROUTER_HOST:-0.0.0.0}" \
  --port "${ROUTER_PORT:-10001}" \
  --vllm-pd-disaggregation \
  --kv-connector "${ROUTER_KV_CONNECTOR}" \
  --policy "${ROUTER_POLICY:-consistent_hash}" \
  --prefill-policy "${PREFILL_POLICY:-consistent_hash}" \
  --decode-policy "${DECODE_POLICY:-power_of_two}" \
  --prefill "http://${PREFILL_HOST}:${PREFILL_PORT}" "${VLLM_MOONCAKE_BOOTSTRAP_PORT:-8998}" \
  --decode "http://${DECODE_HOST}:${DECODE_PORT}"
