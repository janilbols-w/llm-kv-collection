#!/usr/bin/env bash

# Common model/runtime settings
export MODEL_NAME="Qwen/Qwen2.5-7B-Instruct"
export VLLM_USE_V1=1
export HF_TOKEN="hf_xxx"

# Node/port settings
export PREFILL_HOST="127.0.0.1"
export PREFILL_PORT="8010"
export DECODE_HOST="127.0.0.1"
export DECODE_PORT="8020"
export ROUTER_HOST="127.0.0.1"
export ROUTER_PORT="10001"

# Mooncake bootstrap settings
export VLLM_MOONCAKE_BOOTSTRAP_PORT="8998"
export VLLM_MOONCAKE_ABORT_REQUEST_TIMEOUT="480"

# GPU settings (single-node sample)
export PREFILL_CUDA_VISIBLE_DEVICES="0"
export DECODE_CUDA_VISIBLE_DEVICES="1"

# Optional perf tuning
export TENSOR_PARALLEL_SIZE="1"
export GPU_MEMORY_UTILIZATION="0.85"

# Router policy
export ROUTER_POLICY="consistent_hash"
export PREFILL_POLICY="consistent_hash"
export DECODE_POLICY="power_of_two"

# Connector type used by router in static mode: mooncake or nixl
export ROUTER_KV_CONNECTOR="mooncake"

# Non-K8s vLLM discovery mode (primarily used by NIXL/NCCL workflows)
# Example: 0.0.0.0:30001
export VLLM_DISCOVERY_ADDRESS="0.0.0.0:30001"
