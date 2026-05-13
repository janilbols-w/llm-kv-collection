#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE_SCRIPT="${SCRIPT_DIR}/../../../scripts/run_lmcache_offload_instance.sh"

if [[ ! -f "${BASE_SCRIPT}" ]]; then
  echo "[ERROR] Base script not found: ${BASE_SCRIPT}" >&2
  exit 1
fi

exec bash "${BASE_SCRIPT}" "$@"
