#!/usr/bin/env bash
set -euo pipefail

# Load local env if present
[[ -f ./.env.local.sh ]] && source ./.env.local.sh

# Required for K8s dynamic discovery mode
: "${K8S_NAMESPACE:=llm-prod}"
: "${SERVICE_DISCOVERY_PORT:=8000}"

# Label selectors for dynamic add/remove
: "${PREFILL_SELECTOR_1:=app=vllm}"
: "${PREFILL_SELECTOR_2:=component=prefill}"
: "${DECODE_SELECTOR_1:=app=vllm}"
: "${DECODE_SELECTOR_2:=component=decode}"

vllm-router \
  --host "${ROUTER_HOST:-0.0.0.0}" \
  --port "${ROUTER_PORT:-10001}" \
  --vllm-pd-disaggregation \
  --kv-connector mooncake \
  --service-discovery \
  --service-discovery-namespace "${K8S_NAMESPACE}" \
  --service-discovery-port "${SERVICE_DISCOVERY_PORT}" \
  --prefill-selector "${PREFILL_SELECTOR_1}" "${PREFILL_SELECTOR_2}" \
  --decode-selector "${DECODE_SELECTOR_1}" "${DECODE_SELECTOR_2}" \
  --policy "${ROUTER_POLICY:-consistent_hash}" \
  --prefill-policy "${PREFILL_POLICY:-consistent_hash}" \
  --decode-policy "${DECODE_POLICY:-power_of_two}"
