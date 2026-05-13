#!/usr/bin/env bash
set -euo pipefail

# Load local env if present
[[ -f ./.env.local.sh ]] && source ./.env.local.sh

# Non-K8s dynamic discovery mode for vLLM PD routing.
# This mode is typically used in NIXL/NCCL workflows.
# Ensure worker-side kv-transfer/discovery settings are configured consistently.

: "${VLLM_DISCOVERY_ADDRESS:=0.0.0.0:30001}"
: "${ROUTER_KV_CONNECTOR:=nixl}"

vllm-router \
  --host "${ROUTER_HOST:-0.0.0.0}" \
  --port "${ROUTER_PORT:-10001}" \
  --vllm-pd-disaggregation \
  --kv-connector "${ROUTER_KV_CONNECTOR}" \
  --vllm-discovery-address "${VLLM_DISCOVERY_ADDRESS}" \
  --policy "${ROUTER_POLICY:-consistent_hash}" \
  --prefill-policy "${PREFILL_POLICY:-consistent_hash}" \
  --decode-policy "${DECODE_POLICY:-power_of_two}"
