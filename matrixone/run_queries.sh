#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/runtime_env.sh"

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <DB_NAME> [QUERIES_FILE]" >&2
    exit 1
fi

DB_NAME="$1"
QUERIES_FILE="${2:-${SCRIPT_DIR}/queries.sql}"
RUNTIME_LOG="${RUNTIME_LOG:-${SCRIPT_DIR}/runtime/query.log}"

python3 "${SCRIPT_DIR}/query_runner.py" \
    --root "${ROOT_DIR}/agentlogsbench" \
    --db "${DB_NAME}" \
    --table "${MO_TABLE}" \
    --host "${MO_HOST}" \
    --port "${MO_PORT}" \
    --user "${MO_USER}" \
    --query-file "${QUERIES_FILE}" \
    --context-file "${QUERY_CONTEXT_FILE:-}" \
    --out-file "${RUNTIME_LOG}" \
    --query-results-file "${QUERY_RESULTS_FILE:-}" \
    --tries "${TRIES:-3}" \
    --timeout "${MO_QUERY_TIMEOUT}" \
    --mysql-bin "${MO_MYSQL_BIN_RESOLVED:-$(resolve_matrixone_mysql)}"
