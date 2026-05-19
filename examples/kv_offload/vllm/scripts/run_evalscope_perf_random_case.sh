#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KV_OFFLOAD_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SHARED_BENCH_SCRIPT="${SHARED_BENCH_SCRIPT:-${KV_OFFLOAD_ROOT}/../benchmarks/evalscope/run_evalscope_perf_random_case.sh}"

if [[ ! -f "${SHARED_BENCH_SCRIPT}" ]]; then
  echo "[ERROR] Shared benchmark script not found: ${SHARED_BENCH_SCRIPT}" >&2
  exit 1
fi

exec bash "${SHARED_BENCH_SCRIPT}" "$@"
