#!/usr/bin/env bash
set -euo pipefail

# Load local env if present
[[ -f ./.env.local.sh ]] && source ./.env.local.sh

# Send one OpenAI-compatible request to router/proxy endpoint
curl -sS "http://${ROUTER_HOST:-127.0.0.1}:${ROUTER_PORT:-10001}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${HF_TOKEN:-dummy}" \
  -H "X-Session-ID: pd-test-session-001" \
  -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"Please introduce PD disaggregation in one paragraph.\"}],\"max_tokens\":128,\"temperature\":0.2}" | jq .
