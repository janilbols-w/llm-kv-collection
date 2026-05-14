# llm-kv

A workspace for KV cache offload experiments around vLLM and related components.

This repository organizes upstream projects as git submodules under `3rdparty/`,
and keeps local experiment scripts/configs under `examples/`.

## Repository Layout

- `3rdparty/`
  - `vllm/` (https://github.com/vllm-project/vllm)
  - `router/` (https://github.com/vllm-project/router)
  - `lmcache/` (https://github.com/lmcache/lmcache)
  - `FlexKV/` (https://github.com/taco-project/FlexKV)
  - `Mooncake/` (https://github.com/kvcache-ai/Mooncake)
  - `evalscope/` (https://github.com/modelscope/evalscope)
- `examples/`
  - `kv_offload/vllm/`
    - `scripts/`: startup, sleep/wake, benchmark, and e2e scripts
    - `config/`: local config templates
    - `data/custom_gen/`: generated fixed benchmark datasets
  - `pd_tests/`: PD-related templates and smoke scripts

## Quick Start

### 1) Clone and init submodules

```bash
git clone <your-repo-url> llm-kv
cd llm-kv
git submodule update --init --recursive
```

### 2) Prepare Python env (example)

Use your own environment manager (venv/conda/uv).
Install dependencies according to the component you run.

For example, for vLLM + LMCache experiments you usually need:

```bash
pip install -U "evalscope[perf]"
# install lmcache and vllm in your active environment as needed
```

### 3) Run kv-offload scripts

Main script directory:

```bash
cd examples/kv_offload/vllm/tests
```

Common entries:

- `run_lmcache_offload.sh`
- `run_flexkv_offload.sh`
- `run_mooncake_offload.sh`
- `run_evalscope_perf_random_case.sh`
- `run_e2e_lmcache_sleep_wake.sh`
- `vllm_sleep_wake_cli.py`

## Notes

- Third-party source code lives in `3rdparty/*` and is tracked as submodules.
- Generated benchmark outputs are under `examples/kv_offload/vllm/scripts/outputs/`.
- Generated fixed datasets are under `examples/kv_offload/vllm/data/custom_gen/`.

## Update Submodules

```bash
git submodule update --init --recursive
git submodule foreach --recursive git fetch --tags
```

## License

This workspace aggregates multiple upstream projects.
Please follow each upstream project's own license and notice files.
