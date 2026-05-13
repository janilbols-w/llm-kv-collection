# Special Case: Cross-Instance Multi-Node Manual Deployment

This directory groups launchers for the cross-instance multi-node manual deployment workflow.

Scripts in this folder are stable wrappers that delegate to:
- examples/kv_offload/vllm/tests/run_e2e_lmcache_cross_instance.sh
- examples/kv_offload/vllm/scripts/

Included launchers:
- run_lmcache_offload.sh
- run_lmcache_offload_instance.sh
- run_lmcache_offload_multi.sh
- run_e2e_lmcache_cross_instance.sh

Default output directory:
- e2e outputs are written to examples/kv_offload/vllm/outputs/e2e_lmcache_cross_instance
- this is the same level as config (examples/kv_offload/vllm/config)
- you can override with OUTPUT_ROOT=/your/path

Usage example (run from this directory):

Machine A:
HOST=10.0.0.11 PORT=12358 GPU=0 SERVED_NAME=mymodel-a \
LMCACHE_CONFIG_FILE=../../../config/lmcache.instance_a.template.yaml \
bash run_lmcache_offload_instance.sh

Machine B:
HOST=10.0.0.12 PORT=12358 GPU=0 SERVED_NAME=mymodel-b \
LMCACHE_CONFIG_FILE=../../../config/lmcache.instance_b.template.yaml \
bash run_lmcache_offload_instance.sh

Runner node:
START_INSTANCES=0 AUTO_SELECT_IDLE_GPUS=0 AUTO_CLEANUP_VLLM_RESIDUAL=0 AUTO_MANAGE_REMOTE_REDIS=0 \
HOST_A=10.0.0.11 PORT_A=12358 SERVED_NAME_A=mymodel-a \
HOST_B=10.0.0.12 PORT_B=12358 SERVED_NAME_B=mymodel-b \
LMCACHE_CONFIG_FILE_A=../../../config/lmcache.instance_a.template.yaml \
LMCACHE_CONFIG_FILE_B=../../../config/lmcache.instance_b.template.yaml \
bash run_e2e_lmcache_cross_instance.sh
