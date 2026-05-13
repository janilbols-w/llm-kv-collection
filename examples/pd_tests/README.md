# PD Test Command Templates

This folder contains startup command templates for each PD-disaggregation component.

Default stack in templates:
- vLLM V1 engine
- MooncakeConnector for KV transfer
- vllm-router as PD entrypoint

Note for non-K8s users:
- Dynamic add/remove via label-based discovery requires K8s.
- Without K8s, use one of the following:
	- Static URL mode (works with Mooncake and NIXL)
	- vLLM discovery mode (documented for NIXL/NCCL workflows)

## Files

- `env.template.sh`: common environment variables
- `start_prefill.template.sh`: start prefill node (KV producer)
- `start_decode.template.sh`: start decode node (KV consumer)
- `start_router_static.template.sh`: start router with static prefill/decode URLs
- `start_router_k8s_discovery.template.sh`: start router with dynamic K8s service discovery
- `start_router_vllm_discovery.template.sh`: start router with non-K8s vLLM discovery address (NIXL/NCCL workflows)
- `start_proxy.template.sh`: optional local PD proxy (for direct P/D tests without router)
- `smoke_test.template.sh`: minimal OpenAI-compatible request example

## Suggested startup order

1. source env variables
2. start prefill
3. start decode
4. start router (or proxy)
5. run smoke test

## Non-K8s runtime choices

1. Mooncake + Router (recommended without K8s)
- Use `start_router_static.template.sh`
- If you need to change node count, update router args and restart router.

2. NIXL/NCCL + Router with discovery
- Use `start_router_vllm_discovery.template.sh`
- Start/stop workers with matching connector-side discovery settings.

## Quick usage

```bash
cd pd_tests
cp env.template.sh .env.local.sh
# edit values in .env.local.sh
source .env.local.sh

bash start_prefill.template.sh
bash start_decode.template.sh
bash start_router_static.template.sh
bash smoke_test.template.sh
```
