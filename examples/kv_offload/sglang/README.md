# SGLang HiCache Perf (vLLM-style)

This directory provides a minimal performance test flow for SGLang HiCache,
following the style of `examples/kv_offload/vllm`:

- Group1: `gpu_only` baseline
- Group2: `hicache_l1_l2`
- Outputs: `checks.log`, `report.json`, `metrics.csv`

## Files

- `scripts/run_sglang_service.sh`
  - Launch SGLang in one of modes: `gpu_only`, `hicache_l1_l2`, `hicache_mooncake`.
- `tests/run_e2e_sglang_hicache_perf.sh`
  - End-to-end perf comparison and metrics extraction.

## Quick Start

```bash
bash examples/kv_offload/sglang/tests/run_e2e_sglang_hicache_perf.sh
```

## Common Overrides

```bash
MODEL_PATH=/path/to/model \
PORT=30000 \
MODEL_NAME=mymodel \
TP=1 \
PERF_FIXED_PROMPT_LENGTH=4096 \
TARGET_MAX_TOKENS=512 \
REQUEST_TIMEOUT_SECS=900 \
bash examples/kv_offload/sglang/tests/run_e2e_sglang_hicache_perf.sh
```

## Optional: Mooncake Backend Mode

`run_sglang_service.sh` supports `MODE=hicache_mooncake` if you have Mooncake
services configured.

Example:

```bash
MODE=hicache_mooncake \
HICACHE_STORAGE_BACKEND=mooncake \
HICACHE_STORAGE_BACKEND_EXTRA_CONFIG='{"master_server_address":"127.0.0.1:50051","metadata_server":"http://127.0.0.1:8080/metadata","protocol":"rdma","local_hostname":"localhost","global_segment_size":"0"}' \
bash examples/kv_offload/sglang/scripts/run_sglang_service.sh
```
