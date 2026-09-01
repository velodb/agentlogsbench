#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/runtime_env.sh"

matrixone_require_client
matrixone_validate_identifier MO_DB "${MO_DB}"
matrixone_validate_identifier MO_TABLE "${MO_TABLE}"
matrixone_validate_identifier MO_STAGE_TABLE "${MO_STAGE_TABLE}"

if matrixone_endpoint_ready; then
    echo "[matrixone] existing server is ready at ${MO_HOST}:${MO_PORT}"
    exit 0
fi

matrixone_require_runtime
echo "[matrixone] adapter ready (${MO_BIN_RESOLVED}); no download or build performed"
