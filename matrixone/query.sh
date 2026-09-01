#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/runtime_env.sh"

RESULT_DIR="${RESULT_DIR:-${SCRIPT_DIR}/results}"
OUT_FILE="${OUT_FILE:-${RESULT_DIR}/query.out}"
RESULT_FILE="${RESULT_FILE:-${RESULT_DIR}/result.json}"

mkdir -p "${RESULT_DIR}"
python3 "${SCRIPT_DIR}/query_runner.py" \
    --root "${ROOT_DIR}/agentlogsbench" \
    --db "${MO_DB}" \
    --table "${MO_TABLE}" \
    --host "${MO_HOST}" \
    --port "${MO_PORT}" \
    --user "${MO_USER}" \
    --query-file "${SCRIPT_DIR}/queries.sql" \
    --out-file "${OUT_FILE}" \
    --result-file "${RESULT_FILE}" \
    --tries "${TRIES:-1}"
